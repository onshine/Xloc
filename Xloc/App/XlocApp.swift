// Xloc — XlocApp.swift

import SwiftUI
import CoreLocation

@main
struct XlocApp: App {
    @StateObject private var engine = SimulationEngine.shared
    @StateObject private var locationAuth = LocationAuthorizer()

    init() {
        // 越早越好：在 SwiftUI 构建视图之前就装上
        CrashReporter.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(locationAuth)
                .onAppear { locationAuth.request() }
        }
    }
}

/// 读取"系统当前交付给本 App 的定位"。
///
/// 两个用途：
///   1. 自检面板里判断 `isSimulatedBySoftware`（模拟是否被系统打标记）
///   2. "我的位置"按钮，快速跳回真实位置
///
/// 注意：模拟开启后，这里收到的就是模拟后的坐标——这正是我们想观察的对象。
final class LocationAuthorizer: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation?
    @Published var lastError: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func request() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// 手动刷新一次（自检按钮用）
    func refresh() {
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        lastLocation = loc
        lastError = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // locationUnknown 是常态（还没拿到有效解），不当作错误
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        lastError = error.localizedDescription
    }
}
