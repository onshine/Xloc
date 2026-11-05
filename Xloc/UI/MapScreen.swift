// Xloc — MapScreen.swift
// 地图选点 + 摇杆。

import SwiftUI
import MapKit

struct MapScreen: View {
    @EnvironmentObject var engine: SimulationEngine
    @State private var picked: GeoCoordinate?
    @State private var altitudeText = "0"
    @State private var showError: String?

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                PickerMapView(coordinate: $picked)
                    .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 12) {
                    JoystickPad { bearing, meters in
                        engine.nudge(bearing: bearing, meters: meters)
                    }
                    .frame(width: 132, height: 132)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())

                    VStack(spacing: 10) {
                        HStack {
                            Text(picked.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) }
                                 ?? "长按地图选点")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(picked == nil ? .secondary : .primary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("海拔").font(.caption).foregroundStyle(.secondary)
                                TextField("0", text: $altitudeText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .frame(width: 56)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        Button {
                            start()
                        } label: {
                            Label("模拟此处", systemImage: "location.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(picked == nil)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("Xloc")
            .navigationBarTitleDisplayMode(.inline)
            .alert("无法开始", isPresented: Binding(get: { showError != nil }, set: { if !$0 { showError = nil } })) {
                Button("好", role: .cancel) { showError = nil }
            } message: {
                Text(showError ?? "")
            }
        }
    }

    private func start() {
        guard let c = picked else { return }
        do {
            try engine.startStatic(at: c, altitude: Double(altitudeText) ?? 0)
        } catch {
            showError = error.localizedDescription
        }
    }
}

// MARK: - 地图

struct PickerMapView: UIViewRepresentable {
    @Binding var coordinate: GeoCoordinate?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        map.addGestureRecognizer(press)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        guard let c = coordinate else { return }
        if context.coordinator.annotation == nil {
            let a = MKPointAnnotation()
            a.coordinate = c.clCoordinate
            a.title = "模拟位置"
            map.addAnnotation(a)
            context.coordinator.annotation = a
        } else {
            context.coordinator.annotation?.coordinate = c.clCoordinate
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        let parent: PickerMapView
        weak var map: MKMapView?
        var annotation: MKPointAnnotation?

        init(_ parent: PickerMapView) { self.parent = parent }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map else { return }
            let p = g.location(in: map)
            let c = map.convert(p, toCoordinateFrom: map)
            parent.coordinate = GeoCoordinate(c)
        }
    }
}

// MARK: - 摇杆

struct JoystickPad: View {
    /// (方位角, 距离米)
    var onMove: (Double, Double) -> Void
    @State private var knob: CGSize = .zero
    @State private var stepMeters: Double = 20

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.25), lineWidth: 1)
                Image(systemName: "location.north.fill")
                    .foregroundStyle(.secondary.opacity(0.5))
                Circle()
                    .fill(.tint)
                    .frame(width: r * 0.42, height: r * 0.42)
                    .offset(knob)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let limit = r - r * 0.21
                                var t = v.translation
                                let len = hypot(t.width, t.height)
                                if len > limit { t = CGSize(width: t.width / len * limit,
                                                            height: t.height / len * limit) }
                                knob = t
                            }
                            .onEnded { _ in
                                let len = hypot(knob.width, knob.height)
                                guard len > 6 else { knob = .zero; return }
                                // 屏幕坐标 → 方位角（上 = 北）
                                let bearing = (atan2(knob.width, -knob.height) * 180 / .pi + 360)
                                    .truncatingRemainder(dividingBy: 360)
                                let strength = min(1, len / (r * 0.8))
                                onMove(bearing, stepMeters * strength)
                                knob = .zero
                            }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
