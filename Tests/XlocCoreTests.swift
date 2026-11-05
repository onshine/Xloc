import XCTest
@testable import Xloc

final class GeoMathTests: XCTestCase {

    func testDistanceKnownValue() {
        // 天安门 → 故宫（约 1.2 km）
        let a = GeoCoordinate(39.9087, 116.3975)
        let b = GeoCoordinate(39.9163, 116.3972)
        let d = GeoMath.distance(a, b)
        XCTAssertEqual(d, 845, accuracy: 60)
    }

    func testDestinationRoundTrip() {
        let start = GeoCoordinate(31.2304, 121.4737)   // 上海
        let moved = GeoMath.destination(from: start, bearingDegrees: 45, meters: 500)
        let d = GeoMath.distance(start, moved)
        XCTAssertEqual(d, 500, accuracy: 1.0)
        let back = GeoMath.bearing(moved, start)
        XCTAssertEqual(back, 225, accuracy: 1.0)
    }

    func testGCJRoundTrip() {
        let wgs = GeoCoordinate(39.9087, 116.3975)
        let gcj = CoordinateTransform.wgs84ToGcj02(wgs)
        XCTAssertGreaterThan(GeoMath.distance(wgs, gcj), 100, "国内应有明显偏移")
        let back = CoordinateTransform.gcj02ToWgs84(gcj)
        XCTAssertEqual(GeoMath.distance(wgs, back), 0, accuracy: 0.05)
    }

    func testNoOffsetOutsideChina() {
        let ny = GeoCoordinate(40.7128, -74.0060)
        let gcj = CoordinateTransform.wgs84ToGcj02(ny)
        XCTAssertEqual(gcj.latitude, ny.latitude, accuracy: 1e-9)
        XCTAssertEqual(gcj.longitude, ny.longitude, accuracy: 1e-9)
    }

    func testBd09RoundTrip() {
        let wgs = GeoCoordinate(30.2741, 120.1551)     // 杭州
        let bd = CoordinateTransform.wgs84ToBd09(wgs)
        let back = CoordinateTransform.bd09ToWgs84(bd)
        XCTAssertEqual(GeoMath.distance(wgs, back), 0, accuracy: 0.2)
    }
}

final class RoutePathTests: XCTestCase {

    private func straightPath() -> RoutePath {
        // 沿纬线向东 1 km
        let a = GeoCoordinate(39.9, 116.4)
        var pts = [a]
        for i in 1...10 {
            pts.append(GeoMath.destination(from: a, bearingDegrees: 90, meters: Double(i) * 100))
        }
        return RoutePath(points: pts)!
    }

    func testLength() {
        let p = straightPath()
        XCTAssertEqual(p.totalLength, 1000, accuracy: 2)
    }

    func testCoordinateAtMidpoint() {
        let p = straightPath()
        let mid = p.coordinate(at: 500)
        let expected = GeoMath.destination(from: GeoCoordinate(39.9, 116.4),
                                           bearingDegrees: 90, meters: 500)
        XCTAssertEqual(GeoMath.distance(mid, expected), 0, accuracy: 5)
    }

    func testClamp() {
        let p = straightPath()
        XCTAssertEqual(GeoMath.distance(p.coordinate(at: -100), p.points.first!), 0, accuracy: 1)
        XCTAssertEqual(GeoMath.distance(p.coordinate(at: 99999), p.points.last!), 0, accuracy: 1)
    }

    func testBearing() {
        let p = straightPath()
        XCTAssertEqual(p.bearing(at: 300), 90, accuracy: 2)
    }
}

final class RouteSimulatorTests: XCTestCase {

    func testAccelerationIsLimited() {
        let a = GeoCoordinate(39.9, 116.4)
        var pts = [a]
        for i in 1...50 {
            pts.append(GeoMath.destination(from: a, bearingDegrees: 0, meters: Double(i) * 100))
        }
        let sim = RouteSimulator(path: RoutePath(points: pts)!, mode: .walking)
        var last = 0.0
        for _ in 0..<200 {
            _ = sim.advance(dt: 0.1)
            let dv = abs(sim.speed - last)
            XCTAssertLessThanOrEqual(dv, TravelMode.walking.maxAcceleration * 0.1 + 1e-6)
            last = sim.speed
        }
    }

    func testFinishesAtEnd() {
        let a = GeoCoordinate(39.9, 116.4)
        let b = GeoMath.destination(from: a, bearingDegrees: 0, meters: 200)
        let sim = RouteSimulator(path: RoutePath(points: [a, b])!, mode: .running)
        for _ in 0..<10_000 where !sim.finished { _ = sim.advance(dt: 0.1) }
        XCTAssertTrue(sim.finished)
        XCTAssertEqual(sim.distance, 200, accuracy: 1)
    }
}

final class RealismEngineTests: XCTestCase {

    func testDeterministicWithSeed() {
        var cfg = RealismConfig()
        cfg.environment = .urban
        let e1 = RealismEngine(config: cfg, seed: 42)
        let e2 = RealismEngine(config: cfg, seed: 42)
        let base = GeoCoordinate(31.2, 121.4)
        for _ in 0..<20 {
            let f1 = e1.step(base: base, baseAltitude: 10, dt: 1)
            let f2 = e2.step(base: base, baseAltitude: 10, dt: 1)
            XCTAssertEqual(f1.coordinate.latitude, f2.coordinate.latitude, accuracy: 1e-12)
            XCTAssertEqual(f1.horizontalAccuracy, f2.horizontalAccuracy, accuracy: 1e-12)
        }
    }

    func testDriftIsBounded() {
        var cfg = RealismConfig()
        cfg.environment = .urban
        let e = RealismEngine(config: cfg, seed: 7)
        let base = GeoCoordinate(31.2, 121.4)
        for _ in 0..<600 {
            let f = e.step(base: base, baseAltitude: 0, dt: 1)
            XCTAssertLessThan(GeoMath.distance(base, f.coordinate), 12,
                              "OU 漂移应被回归力约束")
        }
    }

    func testDriftIsCorrelated() {
        var cfg = RealismConfig()
        cfg.environment = .urban
        let e = RealismEngine(config: cfg, seed: 99)
        let base = GeoCoordinate(31.2, 121.4)
        var xs: [Double] = []
        for _ in 0..<300 {
            let f = e.step(base: base, baseAltitude: 0, dt: 1)
            xs.append(f.coordinate.latitude - base.latitude)
        }
        // 一阶自相关应显著大于 0（白噪声约为 0）
        let mean = xs.reduce(0, +) / Double(xs.count)
        var num = 0.0, den = 0.0
        for i in 1..<xs.count {
            num += (xs[i] - mean) * (xs[i - 1] - mean)
        }
        for x in xs { den += (x - mean) * (x - mean) }
        let rho = num / den
        XCTAssertGreaterThan(rho, 0.5, "漂移必须时间相关")
    }
}

final class BSSIDTests: XCTestCase {

    func testValid() {
        XCTAssertTrue(BSSIDValidator.validate("A4:2B:B0:11:22:33").isValid)
    }

    func testBroadcastRejected() {
        XCTAssertFalse(BSSIDValidator.validate("FF:FF:FF:FF:FF:FF").isValid)
    }

    func testMulticastRejected() {
        XCTAssertFalse(BSSIDValidator.validate("01:00:5E:00:00:01").isValid)
    }

    func testLocallyAdministeredRejected() {
        XCTAssertFalse(BSSIDValidator.validate("02:11:22:33:44:55").isValid)
    }

    func testVendorHint() {
        XCTAssertEqual(BSSIDValidator.validate("F8:FF:C2:00:11:22").vendorHint, "Apple")
    }
}
