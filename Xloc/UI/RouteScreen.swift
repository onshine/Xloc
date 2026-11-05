// Xloc — RouteScreen.swift
// 路线模拟：地图算路 / GPX 导入 / 速度剖面。

import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct RouteScreen: View {
    @EnvironmentObject var engine: SimulationEngine

    @State private var start: GeoCoordinate?
    @State private var end: GeoCoordinate?
    @State private var mode: TravelMode = .walking
    @State private var multiplier: Double = 1.0
    @State private var loop = false
    @State private var path: RoutePath?
    @State private var status = "长按地图设置起点和终点"
    @State private var busy = false
    @State private var showImporter = false
    @State private var picking: PickTarget = .start

    enum PickTarget { case start, end }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                RouteMapView(start: $start, end: $end, path: $path, picking: $picking)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) {
                        Picker("选点目标", selection: $picking) {
                            Text("起点").tag(PickTarget.start)
                            Text("终点").tag(PickTarget.end)
                        }
                        .pickerStyle(.segmented)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    }

                VStack(spacing: 10) {
                    HStack {
                        Picker("方式", selection: $mode) {
                            ForEach(TravelMode.allCases, id: \.self) { m in
                                Label(m.displayName, systemImage: m.symbolName).tag(m)
                            }
                        }
                        .pickerStyle(.menu)

                        Spacer()

                        Text(String(format: "×%.1f", multiplier))
                            .font(.caption.monospacedDigit())
                        Slider(value: $multiplier, in: 0.5...3, step: 0.1)
                            .frame(width: 110)
                    }

                    if let p = path {
                        HStack {
                            Text(String(format: "%.2f km", p.totalLength / 1000))
                            Spacer()
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.footnote.monospacedDigit())
                    } else {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            showImporter = true
                        } label: {
                            Label("GPX", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            calculate()
                        } label: {
                            Label("算路", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(start == nil || end == nil || busy)

                        Button {
                            begin()
                        } label: {
                            Label("开始", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(path == nil)
                    }
                    .font(.footnote)

                    Toggle("循环播放", isOn: $loop).font(.footnote)
                }
                .padding(14)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("路线")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]) { result in
                handleImport(result)
            }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let p = try GPXLoader.load(url: url)
            path = p
            start = p.points.first
            end = p.points.last
            status = "已导入 \(p.points.count) 个点"
        } catch {
            status = "导入失败：\(error.localizedDescription)"
        }
    }

    private func calculate() {
        guard let s = start, let e = end else { return }
        busy = true
        status = "正在算路…"
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: CoordinateTransform.wgs84ToGcj02(s).clCoordinate))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: CoordinateTransform.wgs84ToGcj02(e).clCoordinate))
        req.transportType = mode.mapKitTransport
        req.requestsAlternateRoutes = false

        MKDirections(request: req).calculate { resp, err in
            DispatchQueue.main.async {
                busy = false
                guard let route = resp?.routes.first else {
                    status = "算路失败：\(err?.localizedDescription ?? "无结果")"
                    return
                }
                let n = route.polyline.pointCount
                var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
                route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
                // MapKit 在国内返回 GCJ-02，统一转成 WGS-84 再存
                let pts = coords.map { CoordinateTransform.gcj02ToWgs84(GeoCoordinate($0)) }
                if let p = RoutePath(points: pts) {
                    path = p
                    status = String(format: "%.2f km · 约 %.0f 分钟",
                                    p.totalLength / 1000,
                                    p.totalLength / ((mode.cruiseRange.lowerBound + mode.cruiseRange.upperBound) / 2 * multiplier) / 60)
                } else {
                    status = "路线过短"
                }
            }
        }
    }

    private func begin() {
        guard let p = path else { return }
        do {
            try engine.startRoute(p, mode: mode, speedMultiplier: multiplier, loop: loop)
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - 路线地图

struct RouteMapView: UIViewRepresentable {
    @Binding var start: GeoCoordinate?
    @Binding var end: GeoCoordinate?
    @Binding var path: RoutePath?
    @Binding var picking: RouteScreen.PickTarget

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.35
        map.addGestureRecognizer(press)
        map.delegate = context.coordinator
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.sync(start: start, end: end, path: path, on: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let parent: RouteMapView
        weak var map: MKMapView?
        var startPin: MKPointAnnotation?
        var endPin: MKPointAnnotation?
        var line: MKPolyline?
        private var lastKey = ""

        init(_ parent: RouteMapView) { self.parent = parent }

        @objc func press(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map else { return }
            let gcj = GeoCoordinate(map.convert(g.location(in: map), toCoordinateFrom: map))
            let wgs = CoordinateTransform.gcj02ToWgs84(gcj)
            if parent.picking == .start { parent.start = wgs } else { parent.end = wgs }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .systemBlue
                r.lineWidth = 5
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func sync(start: GeoCoordinate?, end: GeoCoordinate?, path: RoutePath?, on map: MKMapView) {
            let key = "\(start?.latitude ?? 0),\(start?.longitude ?? 0)|\(end?.latitude ?? 0),\(end?.longitude ?? 0)|\(path?.totalLength ?? 0)"
            guard key != lastKey else { return }
            lastKey = key

            if let s = start {
                if startPin == nil {
                    startPin = MKPointAnnotation(); startPin?.title = "起点"; map.addAnnotation(startPin!)
                }
                startPin?.coordinate = CoordinateTransform.wgs84ToGcj02(s).clCoordinate
            }
            if let e = end {
                if endPin == nil {
                    endPin = MKPointAnnotation(); endPin?.title = "终点"; map.addAnnotation(endPin!)
                }
                endPin?.coordinate = CoordinateTransform.wgs84ToGcj02(e).clCoordinate
            }
            if let old = line { map.removeOverlay(old); line = nil }
            if let p = path, p.points.count > 1 {
                var coords = p.points.map { CoordinateTransform.wgs84ToGcj02($0).clCoordinate }
                let poly = MKPolyline(coordinates: &coords, count: coords.count)
                map.addOverlay(poly, level: .aboveRoads)
                line = poly
                map.setVisibleMapRect(poly.boundingMapRect,
                                      edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 260, right: 40),
                                      animated: true)
            }
        }
    }
}
