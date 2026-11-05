// Xloc — CrashReporter.swift
// 崩溃与异常退出记录。
//
// 三类记录：
//   1. 信号崩溃（SIGSEGV/SIGABRT/…）—— 由 CrashHandler.c 写 pending-signal.log，
//      下次启动改名为带时间戳的记录
//   2. 未捕获的 ObjC 异常 —— NSSetUncaughtExceptionHandler，带完整调用栈
//   3. 异常退出（闪退/被系统杀掉/手动上滑）—— 用 session 标记推断：
//      启动时写标记，正常退到后台或终止时删除；下次启动还在，说明上次没走完

import Foundation
import UIKit

struct CrashLog: Identifiable, Hashable {
    let url: URL
    var id: URL { url }

    var name: String { url.lastPathComponent }

    var date: Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    var size: Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    var text: String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "(无法读取)"
    }

    var kind: String {
        if name.contains("-signal") { return "信号崩溃" }
        if name.contains("-exception") { return "异常" }
        if name.contains("-abnormal") { return "异常退出" }
        return "其他"
    }
}

final class CrashReporter: ObservableObject {
    static let shared = CrashReporter()

    @Published private(set) var logs: [CrashLog] = []

    private let fm = FileManager.default
    let directory: URL

    private var markerURL: URL { directory.appendingPathComponent("session.active") }
    private var pendingURL: URL { directory.appendingPathComponent("pending-signal.log") }

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("CrashLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 安装

    func install() {
        xloc_install_crash_handler(pendingURL.path)

        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.shared.record(exception: exception)
        }

        let harvestedSignal = harvestPendingSignal()
        detectAbnormalExit(skip: harvestedSignal)
        writeSessionMarker()
        refresh()

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { _ in
            CrashReporter.shared.markCleanExit()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main) { _ in
            CrashReporter.shared.markCleanExit()
        }
    }

    // MARK: - 记录

    /// 1) 信号崩溃：把 pending 文件改名并补上头部
    @discardableResult
    private func harvestPendingSignal() -> Bool {
        guard fm.fileExists(atPath: pendingURL.path) else { return false }
        let body = (try? String(contentsOf: pendingURL, encoding: .utf8)) ?? "(空)"
        try? fm.removeItem(at: pendingURL)
        write(kind: "signal", content: "类型: 信号崩溃\n" + body)
        return true
    }

    /// 2) 未捕获异常
    private func record(exception: NSException) {
        var text = "类型: 未捕获异常\n"
        text += "名称: \(exception.name.rawValue)\n"
        text += "原因: \(exception.reason ?? "-")\n"
        if let info = exception.userInfo, !info.isEmpty {
            text += "信息: \(info)\n"
        }
        text += "\n--- callStackSymbols ---\n"
        text += exception.callStackSymbols.joined(separator: "\n")
        text += "\n"
        write(kind: "exception", content: text)
    }

    /// 3) 异常退出（上次没走到后台/终止）
    private func detectAbnormalExit(skip: Bool) {
        guard !skip, fm.fileExists(atPath: markerURL.path) else { return }
        let started = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? "-"
        write(kind: "abnormal",
              content: "类型: 异常退出\n上次会话开始于: \(started)\n"
                     + "说明: 未经过正常退到后台，可能是闪退、被系统终止或手动上滑关闭。\n")
    }

    // MARK: - 会话标记

    private func writeSessionMarker() {
        try? header(kind: "session").data(using: .utf8)?.write(to: markerURL)
    }

    func markCleanExit() {
        try? fm.removeItem(at: markerURL)
    }

    // MARK: - 文件

    private func write(kind: String, content: String) {
        let name = "crash-\(stamp())-\(kind).log"
        let url = directory.appendingPathComponent(name)
        let text = header(kind: kind) + "\n" + content
        try? text.data(using: .utf8)?.write(to: url)
        refresh()
    }

    private func header(kind: String) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return """
        Xloc Crash Report
        时间: \(Self.dateFormatter.string(from: Date()))
        类型: \(kind)
        UID: \(DeviceIdentity.uid)
        版本: \(version) (\(build))
        设备: \(Self.machineModel()) · iOS \(UIDevice.current.systemVersion)
        """
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - 读取 / 删除

    func refresh() {
        let files = (try? fm.contentsOfDirectory(at: directory,
                                                 includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        logs = files
            .filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "log" }
            .map { CrashLog(url: $0) }
            .sorted { $0.date > $1.date }
    }

    func delete(_ log: CrashLog) {
        try? fm.removeItem(at: log.url)
        refresh()
    }

    func deleteAll() {
        for log in logs { try? fm.removeItem(at: log.url) }
        refresh()
    }

    // MARK: - 工具

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func machineModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        var identifier = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { continue }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
