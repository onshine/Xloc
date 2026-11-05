// Xloc — RouteEngine.swift
// 路线引擎：折线参数化 + 带加速度约束的速度剖面。
//
// 与 Andromeda 的差别：
//   它：固定步长 = 速度 × 1s，定时器推进，每拍重建一次模拟。
//   我们：按"弧长"参数化，速度由加速度限制平滑变化（起步/刹车/转弯减速），
//        再叠加真实感的航向与速度输出，且不重建模拟。

import Foundation
import CoreLocation
import MapKit

// MARK: - 出行方式

public enum TravelMode: String, Codable, CaseIterable, Sendable {
    case walking, running, cycling, driving, transit

    public var displayName: String {
        switch self {
        case .walking: return "步行"
        case .running: return "跑步"
        case .cycling: return "骑行"
        case .driving: return "驾车"
        case .transit: return "公共交通"
        }
    }

    /// 巡航速度范围（m/s）
    public var cruiseRange: ClosedRange<Double> {
        switch self {
        case .walking: return 1.1...1.6
        case .running: return 2.4...3.6
        case .cycling: return 4.2...7.0
        case .driving: return 8.0...22.0
        case .transit: return 6.0...16.0
        }
    }

    /// 最大加速度（m/s²）
    public var maxAcceleration: Double {
        switch self {
        case .walking: return 1.0
        case .running: return 2.0
        case .cycling: return 1.6
        case .driving: return 2.2
        case .transit: return 1.8
        }
    }

    /// 转弯时的速度衰减系数（0~1，越小越慢）
    public var turnSlowdown: Double {
        switch self {
        case .walking, .running: return 0.85
        case .cycling: return 0.7
        case .driving: return 0.55
        case .transit: return 0.6
        }
    }

    public var symbolName: String {
        switch self {
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        case .transit: return "tram.fill"
        }
    }

    public var mapKitTransport: MKDirectionsTransportType {
        switch self {
        case .walking, .running, .cycling: return .walking
        case .driving, .transit: return .automobile
        }
    }
}

// MARK: - 折线

public struct RoutePath: Sendable {
    public let points: [GeoCoordinate]
    /// cumulative[i] = 从起点到 points[i] 的弧长（米）
    public let cumulative: [Double]
    public let totalLength: Double

    public init?(points: [GeoCoordinate]) {
        guard points.count >= 2 else { return nil }
        var cum: [Double] = [0]
        var sum = 0.0
        for i in 1..<points.count {
            sum += GeoMath.distance(points[i - 1], points[i])
            cum.append(sum)
        }
        guard sum > 1 else { return nil }
        self.points = points
        self.cumulative = cum
        self.totalLength = sum
    }

    /// 弧长 → 坐标
    public func coordinate(at distance: Double) -> GeoCoordinate {
        let d = max(0, min(totalLength, distance))
        // 二分查找所在段
        var lo = 0, hi = cumulative.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid }
        }
        let segStart = cumulative[lo]
        let segLen = max(1e-9, cumulative[hi] - segStart)
        let t = (d - segStart) / segLen
        return GeoMath.lerp(points[lo], points[hi], t)
    }

    /// 弧长 → 该处的前进方向（度）
    public func bearing(at distance: Double) -> Double {
        let d = max(0, min(totalLength - 0.5, distance))
        let a = coordinate(at: d)
        let b = coordinate(at: min(totalLength, d + 1.0))
        return GeoMath.bearing(a, b)
    }

    /// 未来 lookAhead 米内的最大转角（度），用于转弯减速
    public func upcomingTurnAngle(at distance: Double, lookAhead: Double = 25) -> Double {
        let a = bearing(at: distance)
        let b = bearing(at: min(totalLength, distance + lookAhead))
        var diff = abs(a - b).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        return diff
    }

    /// 反向路线
    public func reversed() -> RoutePath? {
        RoutePath(points: Array(points.reversed()))
    }
}

// MARK: - 路线模拟器

public final class RouteSimulator {
    public private(set) var path: RoutePath
    public private(set) var distance: Double = 0
    public private(set) var speed: Double = 0
    public private(set) var finished = false

    public var mode: TravelMode
    public var speedMultiplier: Double
    public var loop: Bool
    /// 起点静止加速阶段（秒）
    public var warmup: Double = 2.0

    private var elapsed: Double = 0

    public init(path: RoutePath, mode: TravelMode, speedMultiplier: Double = 1.0, loop: Bool = false) {
        self.path = path
        self.mode = mode
        self.speedMultiplier = max(0.1, speedMultiplier)
        self.loop = loop
    }

    public var progress: Double {
        path.totalLength > 0 ? min(1, distance / path.totalLength) : 0
    }

    public var remainingDistance: Double { max(0, path.totalLength - distance) }

    public var estimatedRemainingTime: TimeInterval {
        let cruise = (mode.cruiseRange.lowerBound + mode.cruiseRange.upperBound) / 2 * speedMultiplier
        return cruise > 0 ? remainingDistance / cruise : 0
    }

    /// 推进 dt 秒，返回当前坐标；已结束时返回 nil。
    public func advance(dt: TimeInterval) -> GeoCoordinate? {
        guard !finished, dt > 0 else { return nil }
        elapsed += dt

        // ---- 目标速度 ----
        var target = (mode.cruiseRange.lowerBound + mode.cruiseRange.upperBound) / 2 * speedMultiplier

        // 起步/收尾
        if elapsed < warmup { target *= elapsed / warmup }
        if remainingDistance < 30 { target *= max(0.15, remainingDistance / 30) }

        // 转弯减速
        let turn = path.upcomingTurnAngle(at: distance)
        if turn > 20 { target *= max(mode.turnSlowdown, 1 - (turn - 20) / 160) }

        // ---- 加速度限制 ----
        let aMax = mode.maxAcceleration
        let dv = target - speed
        let maxDelta = aMax * dt
        speed += max(-maxDelta, min(maxDelta, dv))
        speed = max(0, speed)

        distance += speed * dt

        if distance >= path.totalLength {
            if loop {
                distance = distance.truncatingRemainder(dividingBy: path.totalLength)
                elapsed = 0
            } else {
                distance = path.totalLength
                finished = true
                speed = 0
                return path.coordinate(at: distance)
            }
        }
        return path.coordinate(at: distance)
    }

    public var currentBearing: Double { path.bearing(at: distance) }
}

// MARK: - GPX

public enum GPXError: Error, LocalizedError {
    case noTrackPoints
    case malformed
    public var errorDescription: String? {
        switch self {
        case .noTrackPoints: return "GPX 里没有找到轨迹点"
        case .malformed: return "GPX 文件格式错误"
        }
    }
}

public final class GPXLoader: NSObject, XMLParserDelegate {
    private var points: [GeoCoordinate] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var inTrkpt = false
    private var parseError: Error?

    /// 解析 GPX，返回折线（已做 5 m 抽稀，避免上万个点拖慢渲染）
    public static func load(url: URL, simplifyTolerance: Double = 5) throws -> RoutePath {
        let loader = GPXLoader()
        guard let parser = XMLParser(contentsOf: url) else { throw GPXError.malformed }
        parser.delegate = loader
        guard parser.parse(), loader.parseError == nil else {
            throw loader.parseError ?? GPXError.malformed
        }
        let simplified = loader.simplify(loader.points, tolerance: simplifyTolerance)
        guard let path = RoutePath(points: simplified) else { throw GPXError.noTrackPoints }
        return path
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String,
                       namespaceURI: String?, qualifiedName qName: String?,
                       attributes attributeDict: [String: String] = [:]) {
        if elementName == "trkpt" || elementName == "wpt" || elementName == "rtept" {
            inTrkpt = true
            currentLat = attributeDict["lat"].flatMap(Double.init)
            currentLon = attributeDict["lon"].flatMap(Double.init)
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String,
                       namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "trkpt" || elementName == "wpt" || elementName == "rtept" {
            if let lat = currentLat, let lon = currentLon {
                let c = GeoCoordinate(lat, lon)
                if c.isValid { points.append(c) }
            }
            inTrkpt = false
            currentLat = nil
            currentLon = nil
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    /// Douglas–Peucker 抽稀
    private func simplify(_ pts: [GeoCoordinate], tolerance: Double) -> [GeoCoordinate] {
        guard pts.count > 2, tolerance > 0 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var maxD = 0.0, idx = s
            for i in (s + 1)..<e {
                let d = perpendicularDistance(pts[i], pts[s], pts[e])
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return zip(pts, keep).compactMap { $1 ? $0 : nil }
    }

    private func perpendicularDistance(_ p: GeoCoordinate, _ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        // 小范围内用平面近似足够
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(a.latitude * .pi / 180)
        let px = (p.longitude - a.longitude) * lonScale
        let py = (p.latitude - a.latitude) * latScale
        let bx = (b.longitude - a.longitude) * lonScale
        let by = (b.latitude - a.latitude) * latScale
        let len2 = bx * bx + by * by
        if len2 < 1e-9 { return hypot(px, py) }
        let t = max(0, min(1, (px * bx + py * by) / len2))
        return hypot(px - bx * t, py - by * t)
    }
}
