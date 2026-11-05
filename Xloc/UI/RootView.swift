// Xloc — RootView.swift

import SwiftUI

struct RootView: View {
    @EnvironmentObject var engine: SimulationEngine

    var body: some View {
        TabView {
            MapScreen()
                .tabItem { Label("地图", systemImage: "map") }

            RouteScreen()
                .tabItem { Label("路线", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }

            WiFiScreen()
                .tabItem { Label("Wi-Fi", systemImage: "wifi") }

            SettingsScreen()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .overlay(alignment: .top) {
            StatusBanner()
        }
    }
}

// MARK: - 顶部状态条

struct StatusBanner: View {
    @EnvironmentObject var engine: SimulationEngine

    private var color: Color {
        switch engine.state {
        case .running: return .green
        case .paused: return .orange
        case .finished: return .blue
        case .idle: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(statusText).font(.caption.weight(.medium))
            if engine.state == .running {
                Text(String(format: "%.1f m", engine.currentFix?.horizontalAccuracy ?? 0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if engine.state == .running || engine.state == .paused {
                Button(engine.state == .paused ? "继续" : "暂停") {
                    if engine.state == .paused { engine.resume() } else { engine.pause() }
                }
                .font(.caption.weight(.semibold))
                Button("停止") { engine.stop() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 6)
    }

    private var statusText: String {
        switch engine.state {
        case .idle: return "未运行"
        case .running: return "\(engine.mode.displayName)模拟中"
        case .paused: return "已暂停"
        case .finished: return "路线已完成"
        }
    }
}

// MARK: - 设置 / 自检

struct SettingsScreen: View {
    @EnvironmentObject var engine: SimulationEngine
    @State private var diagnostics: [DiagnosticItem] = []

    var body: some View {
        NavigationView {
            Form {
                Section("真实感") {
                    Toggle("启用真实感引擎", isOn: $engine.realism.enabled)

                    Picker("环境", selection: $engine.realism.environment) {
                        ForEach(LocationEnvironment.allCases, id: \.self) { env in
                            Text(label(for: env)).tag(env)
                        }
                    }
                    .disabled(!engine.realism.enabled)

                    VStack(alignment: .leading) {
                        Text("额外波动半径：\(Int(engine.realism.extraDriftRadius)) m")
                            .font(.subheadline)
                        Slider(value: $engine.realism.extraDriftRadius, in: 0...30, step: 1)
                    }
                    .disabled(!engine.realism.enabled)

                    Toggle("精度随时间变化", isOn: $engine.realism.varyAccuracy)
                        .disabled(!engine.realism.enabled)
                    Toggle("不规则交付节奏", isOn: $engine.realism.irregularCadence)
                        .disabled(!engine.realism.enabled)
                }

                Section("调度") {
                    VStack(alignment: .leading) {
                        Text("更新间隔：\(String(format: "%.1f", engine.updateInterval)) s")
                            .font(.subheadline)
                        Slider(value: $engine.updateInterval, in: 0.5...5, step: 0.5)
                    }
                    Picker("自动停止", selection: $engine.autoStopAfter) {
                        Text("不自动停止").tag(TimeInterval(0))
                        Text("15 分钟").tag(TimeInterval(900))
                        Text("30 分钟").tag(TimeInterval(1800))
                        Text("1 小时").tag(TimeInterval(3600))
                        Text("2 小时").tag(TimeInterval(7200))
                    }
                }

                Section("Wi-Fi 指纹") {
                    Toggle("同时伪造 Wi-Fi", isOn: $engine.wifiEnabled)
                    Toggle("真正写入系统（危险）", isOn: Binding(
                        get: { WiFiBridge.shared.applyRealChanges },
                        set: { WiFiBridge.shared.applyRealChanges = $0 }))
                    Text("关闭时只做 dry-run，不会改动系统配置。开启后停止模拟会自动还原。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button("运行自检") { runDiagnostics() }
                    ForEach(diagnostics) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: item.level))
                                .foregroundStyle(color(for: item.level))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.subheadline.weight(.medium))
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("自检")
                } footer: {
                    Text("自检只读，不会修改任何系统状态。")
                }

                Section("关于") {
                    HStack { Text("版本"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-").foregroundStyle(.secondary) }
                    Link("项目主页", destination: URL(string: "https://github.com/onshine/Xloc")!)
                    Text("GPL-3.0 · 仅供学习与测试使用")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }

    private func runDiagnostics() {
        diagnostics = Diagnostics.fullReport(location: nil,
                                             wifi: engine.wifiProfile,
                                             target: engine.baseCoordinate)
    }

    private func label(for env: LocationEnvironment) -> String {
        switch env {
        case .openSky: return "空旷户外"
        case .suburban: return "郊区"
        case .urban: return "城市"
        case .indoor: return "室内"
        }
    }
    private func icon(for level: DiagnosticItem.Level) -> String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }
    private func color(for level: DiagnosticItem.Level) -> Color {
        switch level {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .info: return .secondary
        }
    }
}
