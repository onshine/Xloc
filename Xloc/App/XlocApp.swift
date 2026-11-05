// Xloc — XlocApp.swift

import SwiftUI
import CoreLocation

@main
struct XlocApp: App {
    @StateObject private var engine = SimulationEngine.shared
    @StateObject private var locationAuth = LocationAuthorizer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(locationAuth)
                .onAppear { locationAuth.request() }
        }
    }
}

/// 只是为了让"定位权限"这件事有地方请求（模拟本身不依赖它，
/// 但读当前定位/做自检时需要）。
final class LocationAuthorizer: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func request() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
    }
}
