// Xloc — CrashLogsView.swift

import SwiftUI
import UIKit

struct CrashLogsView: View {
    @ObservedObject var reporter = CrashReporter.shared
    @State private var showClearConfirm = false

    var body: some View {
        List {
            if reporter.logs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("没有记录").font(.subheadline)
                    Text("崩溃、未捕获异常、以及上次会话没走完正常退出，都会记在这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(reporter.logs) { log in
                    NavigationLink(destination: CrashLogDetailView(log: log)) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(log.kind)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(badgeColor(log).opacity(0.15), in: Capsule())
                                    .foregroundStyle(badgeColor(log))
                                Spacer()
                                Text(byteText(log.size))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(CrashReporter.dateFormatter.string(from: log.date))
                                .font(.footnote)
                            Text(log.name)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet { reporter.delete(reporter.logs[i]) }
                }
            }
        }
        .navigationTitle("崩溃日志")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Text("清空")
                }
                .disabled(reporter.logs.isEmpty)
            }
        }
        .confirmationDialog("清空全部崩溃日志？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { reporter.deleteAll() }
            Button("取消", role: .cancel) {}
        }
        .onAppear { reporter.refresh() }
    }

    private func badgeColor(_ log: CrashLog) -> Color {
        if log.name.contains("-signal") { return .red }
        if log.name.contains("-exception") { return .orange }
        return .blue
    }

    private func byteText(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : String(format: "%.1f KB", Double(n) / 1024)
    }
}

struct CrashLogDetailView: View {
    let log: CrashLog
    @State private var copied = false
    @State private var showShare = false

    var body: some View {
        ScrollView {
            Text(log.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .navigationTitle(log.kind)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            ActivityView(items: [log.url])
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        UIPasteboard.general.string = log.text
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button {
                        showShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}


/// UIActivityViewController 的 SwiftUI 包装（iOS 15 没有 ShareLink）
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
