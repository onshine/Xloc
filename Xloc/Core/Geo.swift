// Xloc — Geo.swift
// 坐标系与地理计算。全部为公开数学公式，无第三方依赖。
//
// 说明：
// - 设备/CoreLocation 给的一律是 WGS-84。
// - 国内地图（高德/腾讯/Google 中国）用 GCJ-02；百度用 BD-09。
// - 模拟时：地图选点得到的是 GCJ-02，必须转成 WGS-84 再下发，
//   否则真机上会偏 300~600 m（这是最常见的"一眼假"）。

import Foundation
import CoreLocation

public struct GeoCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ c: CLLocationCoordinate2D) {
        self.init(c.latitude, c.longitude)
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
    }
}

// MARK: - 距离 / 方位

public enum GeoMath {
    public static let earthRadius = 6_371_008.8 // 平均半径，米

    /// Haversine 距离（米）
    public static func distance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let Δφ = (b.latitude - a.latitude) * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(Δφ / 2) * sin(Δφ / 2)
            + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// 初始方位角（度，0 = 正北，顺时针）
    public static func bearing(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let Δλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 从 a 沿 bearing 前进 meters
    public static func destination(from a: GeoCoordinate, bearingDegrees: Double,
                                   meters: Double) -> GeoCoordinate {
        let δ = meters / earthRadius
        let θ = bearingDegrees * .pi / 180
        let φ1 = a.latitude * .pi / 180
        let λ1 = a.longitude * .pi / 180
        let sinφ2 = sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ)
        let φ2 = asin(max(-1, min(1, sinφ2)))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1),
                            cos(δ) - sin(φ1) * sinφ2)
        var lon = λ2 * 180 / .pi
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return GeoCoordinate(φ2 * 180 / .pi, lon)
    }

    /// 线性插值（短距离足够，长距离请用 destination/bearing）
    public static func lerp(_ a: GeoCoordinate, _ b: GeoCoordinate, _ t: Double) -> GeoCoordinate {
        GeoCoordinate(a.latitude + (b.latitude - a.latitude) * t,
                      a.longitude + (b.longitude - a.longitude) * t)
    }

    /// 米 → 纬度差
    public static func metersToLatitude(_ m: Double) -> Double { m / 111_320.0 }

    /// 米 → 经度差（按当前纬度修正）
    public static func metersToLongitude(_ m: Double, at latitude: Double) -> Double {
        m / (111_320.0 * max(0.01, cos(latitude * .pi / 180)))
    }
}

// MARK: - 中国境内判定（GCJ-02 只在中国境内偏移）

public enum ChinaRegion {
    /// 粗略外接矩形，覆盖大陆 + 港澳 + 台湾。
    /// 精确边界没有必要：偏移算法本身在边界外会退化为恒等。
    public static func contains(_ c: GeoCoordinate) -> Bool {
        let lat = c.latitude, lon = c.longitude
        if lat < 3.0 || lat > 54.5 || lon < 73.0 || lon > 135.5 { return false }
        // 排除蒙古/俄罗斯/朝鲜半岛/日本方向的大块区域
        if lat > 49.5 && lon < 87.0 { return false }
        if lat > 42.0 && lon > 128.0 { return false }
        if lat < 20.0 && lon > 122.0 { return false }
        return true
    }
}

// MARK: - WGS-84 / GCJ-02 / BD-09

public enum CoordinateTransform {
    private static let a = 6_378_245.0          // Krasovsky 1940 长半轴
    private static let ee = 0.006_693_421_622_965_943

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }

    /// WGS-84 → GCJ-02
    public static func wgs84ToGcj02(_ c: GeoCoordinate) -> GeoCoordinate {
        guard ChinaRegion.contains(c) else { return c }
        var dLat = transformLat(c.longitude - 105.0, c.latitude - 35.0)
        var dLon = transformLon(c.longitude - 105.0, c.latitude - 35.0)
        let radLat = c.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return GeoCoordinate(c.latitude + dLat, c.longitude + dLon)
    }

    /// GCJ-02 → WGS-84（迭代反解，精度 < 1 cm）
    public static func gcj02ToWgs84(_ c: GeoCoordinate) -> GeoCoordinate {
        guard ChinaRegion.contains(c) else { return c }
        var wgs = c
        for _ in 0..<6 {
            let gcj = wgs84ToGcj02(wgs)
            let dLat = gcj.latitude - c.latitude
            let dLon = gcj.longitude - c.longitude
            if abs(dLat) < 1e-9 && abs(dLon) < 1e-9 { break }
            wgs.latitude -= dLat
            wgs.longitude -= dLon
        }
        return wgs
    }

    // BD-09（百度）
    private static let xPi = Double.pi * 3000.0 / 180.0

    public static func gcj02ToBd09(_ c: GeoCoordinate) -> GeoCoordinate {
        let z = sqrt(c.longitude * c.longitude + c.latitude * c.latitude) + 0.00002 * sin(c.latitude * xPi)
        let θ = atan2(c.latitude, c.longitude) + 0.000003 * cos(c.longitude * xPi)
        return GeoCoordinate(z * sin(θ) + 0.006, z * cos(θ) + 0.0065)
    }

    public static func bd09ToGcj02(_ c: GeoCoordinate) -> GeoCoordinate {
        let x = c.longitude - 0.0065, y = c.latitude - 0.006
        let z = sqrt(x * x + y * y) - 0.00002 * sin(y * xPi)
        let θ = atan2(y, x) - 0.000003 * cos(x * xPi)
        return GeoCoordinate(z * sin(θ), z * cos(θ))
    }

    public static func wgs84ToBd09(_ c: GeoCoordinate) -> GeoCoordinate {
        gcj02ToBd09(wgs84ToGcj02(c))
    }

    public static func bd09ToWgs84(_ c: GeoCoordinate) -> GeoCoordinate {
        gcj02ToWgs84(bd09ToGcj02(c))
    }
}
