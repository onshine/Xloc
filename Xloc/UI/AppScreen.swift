// Xloc — AppScreen.swift
// B 方案界面：选择目标 App → 生成注入版安装包 → 交给 TrollStore 覆盖安装。

import SwiftUI
import UIKit

struct AppScreen: View {
    @EnvironmentObject var engine: SimulationEngine

    @State private var apps: [InstalledApp] = []
    @State private var query = ""
    @State private var busy = false
    @State private var status = ""
    @State private var result: URL?
    @State private var showShare = false
    @State private var errorText: String?

    private var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.bundleID.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if engine.baseCoordinate == nil {
                        Label("先在地图页选一个点", systemImage: "mappin.slash")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    } else if let c = engine.baseCoordinate {
                        HStack {
                            Text("目标坐标")
                            Spacer()
                            Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if engine.wifiEnabled, let w = engine.wifiProfile {
                        HStack {
                            Text("Wi-Fi")
                            Spacer()
                            Text(w.ssid).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("将写入的配置")
                } footer: {
                    Text("生成的是「注入了 XlocPlugin 的安装包」。用 TrollStore 覆盖安装后，该 App 拿到的定位由插件在进程内构造，不带 isSimulatedBySoftware 标记。")
                }

                Section {
                    ForEach(filtered) { app in
                        Button {
                            patch(app)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "app.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).foregroundStyle(.primary)
                                    Text(app.bundleID)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(busy || engine.baseCoordinate == nil)
                    }
                } header: {
                    Text("已安装 App（\(apps.count)）")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索 App")
            .navigationTitle("App")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .overlay {
                if busy {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(status).font(.footnote)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("出错了", isPresented: Binding(get: { errorText != nil },
                                               set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .sheet(isPresented: $showShare) {
                if let url = result { ActivityView(items: [url]) }
            }
            .onAppear {
                if apps.isEmpty { reload() }
            }
        }
    }

    private func reload() {
        apps = AppInventory.installed()
    }

    private func patch(_ app: InstalledApp) {
        guard let coord = engine.baseCoordinate else {
            errorText = "先在地图页选一个点"
            return
        }
        let cfg = PatchConfig(coordinate: coord,
                              altitude: engine.baseAltitude,
                              accuracy: engine.realism.environment.baseAccuracy,
                              wifi: engine.wifiEnabled ? engine.wifiProfile : nil)

        busy = true
        status = "准备中…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try AppPatcher.makeTipa(app: app, config: cfg) { msg in
                    DispatchQueue.main.async { status = msg }
                }
                DispatchQueue.main.async {
                    busy = false
                    result = url
                    showShare = true
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
