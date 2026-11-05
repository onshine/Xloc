// Xloc — RealismEngine.swift
// 真实感引擎：让"假定位"具备真实 GPS 的统计特征。
//
// 为什么需要它：
// 真实的 GPS 从来不是一个精确的点。它是一个带噪声的估计：
//   - 静止时也会以 1~5 m 的幅度缓慢游走（不是白噪声，是相关噪声）
//   - 精度（horizontalAccuracy）随环境变化，且变化是连续的
//   - 海拔有缓慢漂移
//   - 静止时 speed 不会精确等于 0，course 基本是随机值
//   - 系统交付定位的节奏也不是严格 1 Hz
//
// 用"每帧独立随机数"（白噪声）去模仿，会被简单的自相关检验识破；
// 这里用 Ornstein–Uhlenbeck 过程：有回归力 + 有相关时间，和真实漂移同分布。

import Foundation
import CoreLocation

// MARK: - 可复现随机数（SplitMix64）

public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64 = 0x584C4F43_5F303031 /* "XLOC_001" */) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
    /// 标准正态（Box–Muller）
    public mutating func nextGaussian() -> Double {
        var u1 = nextDouble(), u2 = nextDouble()
        if u1 < 1e-12 { u1 = 1e-12 }
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

// MARK: - 环境模型

public enum LocationEnvironment: String, Codable, CaseIterable, Sendable {
    case openSky    // 空旷户外
    case suburban   // 郊区/小区
    case urban      // 城市街道（多径严重）
    case indoor     // 室内（靠 WiFi/基站，精度差）

    /// 基础水平精度（米）与抖动幅度
    public var baseAccuracy: Double {
        switch self {
        case .openSky:  return 4
        case .suburban: return 6
        case .urban:    return 9
        case .indoor:   return 22
        }
    }

    /// 精度波动幅度（米）
    public var accuracySpread: Double {
        switch self {
        case .openSky:  return 2
        case .suburban: return 3
        case .urban:    return 5
        case .indoor:   return 12
        }
    }

    /// 静止漂移幅度（米，1σ）
    public var driftSigma: Double {
        switch self {
        case .openSky:  return 0.8
        case .suburban: return 1.2
        case .urban:    return 2.0
        case .indoor:   return 4.5
        }
    }
}

// MARK: - 配置

public struct RealismConfig: Codable, Sendable {
    public var enabled: Bool = true
    public var environment: LocationEnvironment = .suburban

    /// 漂移相关时间（秒）。越大越"黏"，真实 GPS 漂移约 10~30 s。
    public var driftCorrelationTime: Double = 18

    /// 用户手动设定的额外波动半径（米）。0 = 只用环境模型。
    public var extraDriftRadius: Double = 0

    /// 精度是否随时间变化
    public var varyAccuracy: Bool = true

    /// 海拔噪声（米，1σ）
    public var altitudeNoise: Double = 0.6

    /// 是否模拟"交付节奏抖动"（偶尔跳一拍）
    public var irregularCadence: Bool = true

    public init() {}
}

// MARK: - 一个定位样本

public struct SimulatedFix: Sendable {
    public var coordinate: GeoCoordinate
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    public var speed: Double          // m/s
    public var course: Double         // 度，-1 表示无效
    public var timestamp: Date

    public init(coordinate: GeoCoordinate,
                altitude: Double = 0,
                horizontalAccuracy: Double = 5,
                verticalAccuracy: Double = 5,
                speed: Double = 0,
                course: Double = -1,
                timestamp: Date = Date()) {
        self.coordinate = coordinate
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }
}

// MARK: - 引擎

/// 维护一个随时间演化的"漂移状态"，输出叠加到基准坐标上的偏移量。
public final class RealismEngine {
    private var config: RealismConfig
    private var rng: SeededRandom

    // OU 状态（东向 / 北向偏移，米）
    private var offsetEast: Double = 0
    private var offsetNorth: Double = 0

    // 精度慢变状态
    private var accuracyState: Double = 0

    // 海拔慢变状态
    private var altitudeState: Double = 0

    // 上一次输出，用于算速度/航向
    private var lastCoordinate: GeoCoordinate?
    private var lastTimestamp: Date?
    private var smoothedSpeed: Double = 0
    private var lastCourse: Double = -1

    public init(config: RealismConfig = RealismConfig(), seed: UInt64 = 0x584C4F43_5F303031) {
        self.config = config
        self.rng = SeededRandom(seed: seed)
        self.accuracyState = config.environment.baseAccuracy
    }

    public func update(config: RealismConfig) {
        self.config = config
    }

    public func reset() {
        offsetEast = 0
        offsetNorth = 0
        accuracyState = config.environment.baseAccuracy
        altitudeState = 0
        lastCoordinate = nil
        lastTimestamp = nil
        smoothedSpeed = 0
        lastCourse = -1
    }

    /// 推进 dt 秒，返回叠加在 base 上的最终定位。
    public func step(base: GeoCoordinate,
                     baseAltitude: Double,
                     dt: TimeInterval,
                     now: Date = Date()) -> SimulatedFix {
        guard dt > 0, dt < 60 else {
            return SimulatedFix(coordinate: base, altitude: baseAltitude)
        }

        if config.enabled {
            let env = config.environment

            // ---- 1. OU 漂移 ----
            // 用户指定了波动半径时，把 sigma 按半径放大（半径 ≈ 2σ）
            let sigma = config.extraDriftRadius > 0
                ? max(env.driftSigma, config.extraDriftRadius / 2.0)
                : env.driftSigma
            let tau = max(1.0, config.driftCorrelationTime)
            let decay = exp(-dt / tau)
            let diffusion = sigma * sqrt(max(0, 1 - decay * decay))

            offsetEast = offsetEast * decay + diffusion * rng.nextGaussian()
            offsetNorth = offsetNorth * decay + diffusion * rng.nextGaussian()

            // ---- 2. 精度慢变 ----
            if config.varyAccuracy {
                let target = env.baseAccuracy + env.accuracySpread * 0.5
                accuracyState += (target - accuracyState) * min(1, dt / 30)
                accuracyState += env.accuracySpread * 0.12 * rng.nextGaussian()
                accuracyState = max(env.baseAccuracy * 0.5,
                                    min(env.baseAccuracy + env.accuracySpread * 1.5, accuracyState))
            } else {
                accuracyState = env.baseAccuracy
            }

            // ---- 3. 海拔漂移 ----
            altitudeState = altitudeState * decay + config.altitudeNoise * sqrt(max(0, 1 - decay * decay)) * rng.nextGaussian()
        }

        let coordinate = GeoMath.destination(from: base,
                                             bearingDegrees: atan2(offsetEast, offsetNorth) * 180 / .pi,
                                             meters: hypot(offsetEast, offsetNorth))

        // ---- 4. 速度 / 航向 ----
        var speed = 0.0
        var course = -1.0
        if let last = lastCoordinate, let lastT = lastTimestamp {
            let d = GeoMath.distance(last, coordinate)
            let elapsed = max(0.001, now.timeIntervalSince(lastT))
            let raw = d / elapsed
            // 一阶低通，避免速度锯齿
            smoothedSpeed += (raw - smoothedSpeed) * min(1, dt / 2.0)
            speed = smoothedSpeed
            if d > 0.5 {
                course = GeoMath.bearing(last, coordinate)
                lastCourse = course
            } else if lastCourse >= 0 {
                // 静止时航向保持但缓慢随机化（真实设备如此）
                course = (lastCourse + rng.nextGaussian() * 8 + 360)
                    .truncatingRemainder(dividingBy: 360)
                lastCourse = course
            }
        }

        lastCoordinate = coordinate
        lastTimestamp = now

        return SimulatedFix(
            coordinate: coordinate,
            altitude: baseAltitude + altitudeState,
            horizontalAccuracy: config.enabled ? accuracyState : 5,
            verticalAccuracy: config.enabled ? max(3, accuracyState * 0.6) : 5,
            speed: max(0, speed),
            course: course,
            timestamp: now
        )
    }

    /// 是否跳过这一拍（模拟真实交付节奏的不规则）
    public func shouldSkipTick() -> Bool {
        guard config.irregularCadence, config.enabled else { return false }
        return rng.nextDouble() < 0.04
    }
}
