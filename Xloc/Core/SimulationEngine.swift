// Xloc — SimulationEngine.swift
// 状态机 + 调度。所有模式的唯一入口。
//
//        ┌──────────┐  start   ┌──────────┐  pause  ┌─────────┐
//        │  idle    │ ───────► │ running  │ ◄─────► │ paused  │
//        └──────────┘          └────┬─────┘ resume  └─────────┘
//             ▲                     │ finish/stop
//             └─────────────────────┘

import Foundation
import CoreLocation
import SwiftUI

public enum SimulationMode: String, Codable, CaseIterable, Sendable {
    case staticPoint   // 单点
    case route         // 路线
    case joystick      // 摇杆（手动推进）

    public var displayName: String {
        switch self {
        case .staticPoint: return "单点"
        case .route: return "路线"
        case .joystick: return "摇杆"
        }
    }
}

public enum SimulationState: String, Sendable {
    case idle, running, paused, finished
}

/// 说明：所有状态变更都发生在主线程（Timer 挂在 RunLoop.main），
/// 因此这里不标 @MainActor，避免在 App 的初始化上下文里产生隔离冲突。
public final class SimulationEngine: ObservableObject {

    // MARK: 对外状态

    @Published public private(set) var state: SimulationState = .idle
    @Published public private(set) var mode: SimulationMode = .staticPoint
    @Published public private(set) var currentFix: SimulatedFix?
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var tickCount: Int = 0

    /// 目标基准坐标（WGS-84）
    @Published public var baseCoordinate: GeoCoordinate?
    /// 基准海拔
    @Published public var baseAltitude: Double = 0

    // MARK: 配置

    @Published public var realism = RealismConfig()
    @Published public var wifiProfile: WiFiProfile?
    @Published public var wifiEnabled = false
    @Published public var travelMode: TravelMode = .walking
    @Published public var speedMultiplier: Double = 1.0
    @Published public var updateInterval: TimeInterval = 1.0
    /// 自动停止（秒），0 = 不自动停
    @Published public var autoStopAfter: TimeInterval = 0

    // MARK: 内部

    private let bridge = LocSimBridge.shared
    private let wifi = WiFiBridge.shared
    private var realismEngine = RealismEngine()
    private var routeSimulator: RouteSimulator?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private var pausedAt: Date?

    public static let shared = SimulationEngine()

    public init() {}

    // MARK: - 启动

    public func startStatic(at coordinate: GeoCoordinate, altitude: Double = 0) throws {
        guard bridge.isAvailable else { throw LocSimError.unavailable }
        stopInternal(restoreWiFi: false)

        mode = .staticPoint
        baseCoordinate = coordinate
        baseAltitude = altitude
        realismEngine.reset()
        realismEngine.update(config: realism)

        let fix = realismEngine.step(base: coordinate, baseAltitude: altitude,
                                     dt: 1, now: Date())
        try bridge.start(with: fix)
        currentFix = fix

        if wifiEnabled, let profile = wifiProfile {
            _ = wifi.apply(profile)
        }
        beginTicking()
        state = .running
        startedAt = Date()
        lastError = nil
    }

    public func startRoute(_ path: RoutePath, mode travel: TravelMode,
                           speedMultiplier: Double = 1.0, loop: Bool = false) throws {
        guard bridge.isAvailable else { throw LocSimError.unavailable }
        stopInternal(restoreWiFi: false)

        self.mode = .route
        self.travelMode = travel
        self.speedMultiplier = speedMultiplier

        let sim = RouteSimulator(path: path, mode: travel,
                                 speedMultiplier: speedMultiplier, loop: loop)
        routeSimulator = sim
        baseCoordinate = path.coordinate(at: 0)
        baseAltitude = 0
        realismEngine.reset()
        realismEngine.update(config: realism)

        let first = realismEngine.step(base: path.coordinate(at: 0), baseAltitude: 0, dt: 1)
        try bridge.start(with: first)
        currentFix = first

        if wifiEnabled, let profile = wifiProfile { _ = wifi.apply(profile) }
        beginTicking()
        state = .running
        startedAt = Date()
        lastError = nil
    }

    // MARK: - 控制

    public func pause() {
        guard state == .running else { return }
        timer?.invalidate(); timer = nil
        bridge.pause()
        state = .paused
        pausedAt = Date()
    }

    public func resume() {
        guard state == .paused else { return }
        if let p = pausedAt { pausedDuration += Date().timeIntervalSince(p); pausedAt = nil }
        try? bridge.resume()
        beginTicking()
        state = .running
    }

    public func stop() {
        stopInternal(restoreWiFi: true)
        state = .idle
    }

    /// 摇杆：按方位与距离手动推进
    public func nudge(bearing: Double, meters: Double) {
        guard let base = baseCoordinate else { return }
        let next = GeoMath.destination(from: base, bearingDegrees: bearing, meters: meters)
        baseCoordinate = next
        if mode == .joystick || mode == .staticPoint {
            let fix = realismEngine.step(base: next, baseAltitude: baseAltitude, dt: updateInterval)
            currentFix = fix
            bridge.update(with: fix)
        }
    }

    // MARK: - 定时器

    private func beginTicking() {
        timer?.invalidate()
        let t = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard state == .running else { return }
        if let started = startedAt, autoStopAfter > 0,
           Date().timeIntervalSince(started) - pausedDuration >= autoStopAfter {
            stop()
            return
        }
        if realismEngine.shouldSkipTick() { return }

        var base = baseCoordinate
        if mode == .route, let sim = routeSimulator {
            if let c = sim.advance(dt: updateInterval) {
                base = c
                progress = sim.progress
                baseCoordinate = c
            }
            if sim.finished {
                let fix = realismEngine.step(base: sim.path.coordinate(at: sim.path.totalLength),
                                             baseAltitude: baseAltitude, dt: updateInterval)
                currentFix = fix
                bridge.update(with: fix)
                timer?.invalidate(); timer = nil
                state = .finished
                return
            }
        }

        guard let b = base else { return }
        let fix = realismEngine.step(base: b, baseAltitude: baseAltitude,
                                     dt: updateInterval)
        currentFix = fix
        tickCount += 1
        bridge.update(with: fix)
    }

    private func stopInternal(restoreWiFi: Bool) {
        timer?.invalidate(); timer = nil
        bridge.stop()
        if restoreWiFi, wifiEnabled { wifi.restore() }
        routeSimulator = nil
        progress = 0
        startedAt = nil
        pausedAt = nil
        pausedDuration = 0
        tickCount = 0
    }
}
