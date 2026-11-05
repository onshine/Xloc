// Xloc — LocSimBridge.swift
// 与 CLSimulationManager 的唯一接触面。
//
// 设计原则：
//   1. 引擎（SimulationEngine）不直接碰私有 API，全部经过这里，方便替换实现。
//   2. 不在每次 tick 都 stop/clear/start —— 那是 Andromeda 的做法，
//      会造成模拟反复重建（目标 App 会看到定位"跳一下再回来"）。
//   3. 提供两种更新策略，默认 append（原地更新），可回退到 restart。

import Foundation
import CoreLocation

public enum LocSimUpdateStrategy: String, CaseIterable, Codable, Sendable {
    /// 运行中直接 append + flush（平滑，推荐）
    case append
    /// 每次更新完整重启模拟（兼容性最好，但会有跳变）
    case restart
}

public enum LocSimError: Error, LocalizedError {
    case unavailable
    case notPermitted

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "当前系统没有 CLSimulationManager（需要 iOS 14+ 与 TrollStore）"
        case .notPermitted:
            return "缺少 com.apple.locationd.simulation 权限，请用 TrollStore 安装"
        }
    }
}

public final class LocSimBridge {
    public static let shared = LocSimBridge()

    private var manager: CLSimulationManager?
    private var running = false
    private var lastFix: SimulatedFix?
    private var lastApplyTime: Date = .distantPast

    /// 更新策略
    public var strategy: LocSimUpdateStrategy = .append

    /// 最小更新间隔，避免过于频繁地 flush（locationd 不需要 10 Hz）
    public var minimumInterval: TimeInterval = 0.45

    private init() {
        if let cls = NSClassFromString("CLSimulationManager") as? NSObject.Type {
            manager = cls.init() as? CLSimulationManager
        }
    }

    public var isAvailable: Bool { manager != nil }
    public var isRunning: Bool { running }

    // MARK: - 生命周期

    /// 开始模拟并下发第一个点
    public func start(with fix: SimulatedFix) throws {
        guard let manager else { throw LocSimError.unavailable }

        manager.stopLocationSimulation()
        manager.clearSimulatedLocations()
        // 0 = 固定点，1 = 按 append 顺序播放（见 PrivateHeaders.h）
        manager.locationDeliveryBehavior = 0
        manager.appendSimulatedLocation(makeCLLocation(fix))
        manager.flush()
        manager.startLocationSimulation()

        running = true
        lastFix = fix
        lastApplyTime = Date()
        notifyTimezoneUpdate()
    }

    /// 运行中更新位置
    public func update(with fix: SimulatedFix) {
        guard let manager, running else { return }
        let now = Date()
        guard now.timeIntervalSince(lastApplyTime) >= minimumInterval else { return }

        switch strategy {
        case .append:
            manager.appendSimulatedLocation(makeCLLocation(fix))
            manager.flush()

        case .restart:
            manager.stopLocationSimulation()
            manager.clearSimulatedLocations()
            manager.appendSimulatedLocation(makeCLLocation(fix))
            manager.flush()
            manager.startLocationSimulation()
        }

        lastFix = fix
        lastApplyTime = now
    }

    public func stop() {
        guard let manager else { return }
        manager.stopLocationSimulation()
        manager.clearSimulatedLocations()
        manager.flush()
        running = false
        lastFix = nil
        notifyTimezoneUpdate()
    }

    /// 临时暂停（保持系统侧状态，只是不再推新点）
    public func pause() {
        guard let manager, running else { return }
        manager.stopLocationSimulation()
        running = false
    }

    public func resume() throws {
        guard let manager else { throw LocSimError.unavailable }
        guard let fix = lastFix else { return }
        manager.appendSimulatedLocation(makeCLLocation(fix))
        manager.flush()
        manager.startLocationSimulation()
        running = true
    }

    // MARK: - 路线批量模式

    /// 一次性把整条路线交给 locationd，让它按 speed/interval 自己播放。
    /// 优点：后台/锁屏也能走；缺点：无法中途改速度。
    public func playRoute(_ fixes: [SimulatedFix], speed: Double, interval: Double = 1.0) throws {
        guard let manager, !fixes.isEmpty else { throw LocSimError.unavailable }
        manager.stopLocationSimulation()
        manager.clearSimulatedLocations()
        // 1 = 按 append 顺序播放
        manager.locationDeliveryBehavior = 1
        manager.locationSpeed = max(0.1, speed)
        manager.locationInterval = max(0.1, interval)
        manager.locationRepeatBehavior = 0
        for f in fixes { manager.appendSimulatedLocation(makeCLLocation(f)) }
        manager.flush()
        manager.startLocationSimulation()
        running = true
        notifyTimezoneUpdate()
    }

    // MARK: - 内部

    private func makeCLLocation(_ fix: SimulatedFix) -> CLLocation {
        let c = fix.coordinate.clCoordinate
        let loc: CLLocation
        if fix.course >= 0, fix.speed > 0.3 {
            loc = CLLocation(coordinate: c,
                             altitude: fix.altitude,
                             horizontalAccuracy: max(1, fix.horizontalAccuracy),
                             verticalAccuracy: max(1, fix.verticalAccuracy),
                             course: fix.course,
                             speed: max(0, fix.speed),
                             timestamp: fix.timestamp)
        } else {
            loc = CLLocation(coordinate: c,
                             altitude: fix.altitude,
                             horizontalAccuracy: max(1, fix.horizontalAccuracy),
                             verticalAccuracy: max(1, fix.verticalAccuracy),
                             timestamp: fix.timestamp)
        }
        return loc
    }

    /// 位置变了，时区/日出日落也要跟着变，否则目标 App 可能拿时区做交叉校验
    private func notifyTimezoneUpdate() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("AutomaticTimeZoneUpdateNeeded" as CFString),
            nil, nil, true)
    }
}
