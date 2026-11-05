// Xloc — MapScreen.swift
// 地图选点 + 地点搜索 + 摇杆。
//
// 关键修正：
//   1. UIViewRepresentable 没有固有尺寸，必须显式 frame，否则在 ZStack 里会被压成 0 高
//   2. 国内地图坐标是 GCJ-02，存进 engine 之前必须转 WGS-84，否则会偏 300~600 m

import SwiftUI
import MapKit

struct MapScreen: View {
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var locationAuth: LocationAuthorizer
    @StateObject private var search = PlaceSearch()

    @State private var picked: GeoCoordinate?          // 始终是 WGS-84
    @State private var altitudeText = "0"
    @State private var showError: String?
    @State private var showResults = false
    @State private var camera: MKCoordinateRegion?
    @State private var hint = "长按地图选点，或搜索地点"

    var body: some View {
        ZStack(alignment: .top) {
            MapCanvas(coordinate: $picked, camera: $camera)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                searchBar

                if showResults && !search.results.isEmpty {
                    resultsList
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    Spacer()
                    JoystickPad { bearing, meters in
                        engine.nudge(bearing: bearing, meters: meters)
                    }
                    .frame(width: 116, height: 116)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                }

                bottomCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
        .alert("无法开始", isPresented: Binding(get: { showError != nil },
                                              set: { if !$0 { showError = nil } })) {
            Button("好", role: .cancel) { showError = nil }
        } message: {
            Text(showError ?? "")
        }
        .onChange(of: locationAuth.lastLocation) { _ in
            // 让搜索建议更贴近当前视角
            if let loc = locationAuth.lastLocation {
                search.updateRegion(MKCoordinateRegion(center: loc.coordinate,
                                                       span: MKCoordinateSpan(latitudeDelta: 0.5,
                                                                              longitudeDelta: 0.5)))
            }
        }
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索地点、地址、店铺", text: $search.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onTapGesture { showResults = true }
                .onChange(of: search.query) { value in
                    showResults = !value.isEmpty
                }

            if !search.query.isEmpty {
                Button {
                    search.query = ""
                    showResults = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(search.results, id: \.self) { item in
                    Button {
                        select(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    Divider().padding(.leading, 12)
                }
            }
        }
        .frame(maxHeight: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        search.resolve(completion) { coordinate, name in
            guard let c = coordinate else {
                showError = name
                return
            }
            picked = c
            hint = name
            camera = MKCoordinateRegion(center: CoordinateTransform.wgs84ToGcj02(c).clCoordinate,
                                        span: MKCoordinateSpan(latitudeDelta: 0.01,
                                                               longitudeDelta: 0.01))
            showResults = false
            search.query = name
        }
    }

    // MARK: - 底部卡片

    private var bottomCard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(picked.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) }
                         ?? "未选点")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(picked == nil ? .secondary : .primary)
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("海拔").font(.caption).foregroundStyle(.secondary)
                    TextField("0", text: $altitudeText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 54)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 10) {
                Button {
                    useMyLocation()
                } label: {
                    Label("我的位置", systemImage: "location")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    start()
                } label: {
                    Label("模拟此处", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked == nil)
            }
            .font(.subheadline)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 3)
    }

    private func useMyLocation() {
        guard let loc = locationAuth.lastLocation else {
            showError = locationAuth.lastError ?? "还没有拿到定位，请检查定位权限"
            return
        }
        let c = GeoCoordinate(loc.coordinate)
        picked = c
        hint = "我的位置"
        camera = MKCoordinateRegion(center: loc.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    }

    private func start() {
        guard let c = picked else { return }
        do {
            try engine.startStatic(at: c, altitude: Double(altitudeText) ?? 0)
            hint = "模拟中 · \(String(format: "%.4f, %.4f", c.latitude, c.longitude))"
        } catch {
            showError = error.localizedDescription
        }
    }
}

// MARK: - 地图

struct MapCanvas: UIViewRepresentable {
    @Binding var coordinate: GeoCoordinate?      // WGS-84
    @Binding var camera: MKCoordinateRegion?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        // 默认落在国内中部，避免首次进入是一片空白海洋
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 31.2304,
                                                                       longitude: 121.4737),
                                         span: MKCoordinateSpan(latitudeDelta: 12,
                                                                longitudeDelta: 12)),
                      animated: false)

        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.onLongPress(_:)))
        press.minimumPressDuration = 0.35
        map.addGestureRecognizer(press)

        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.applyCamera(camera, on: map)
        context.coordinator.applyAnnotation(coordinate, on: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let parent: MapCanvas
        weak var map: MKMapView?
        private var pin: MKPointAnnotation?
        private var lastCameraKey = ""

        init(_ parent: MapCanvas) { self.parent = parent }

        @objc func onLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map else { return }
            let gcj = GeoCoordinate(map.convert(g.location(in: map), toCoordinateFrom: map))
            parent.coordinate = CoordinateTransform.gcj02ToWgs84(gcj)
        }

        func applyCamera(_ region: MKCoordinateRegion?, on map: MKMapView) {
            guard let r = region else { return }
            let key = String(format: "%.6f,%.6f,%.6f", r.center.latitude, r.center.longitude, r.span.latitudeDelta)
            guard key != lastCameraKey else { return }
            lastCameraKey = key
            map.setRegion(r, animated: true)
        }

        func applyAnnotation(_ c: GeoCoordinate?, on map: MKMapView) {
            guard let c else {
                if let p = pin { map.removeAnnotation(p); pin = nil }
                return
            }
            // 显示时转回 GCJ-02，与地图底图对齐
            let gcj = CoordinateTransform.wgs84ToGcj02(c).clCoordinate
            if pin == nil {
                let a = MKPointAnnotation()
                a.title = "模拟位置"
                map.addAnnotation(a)
                pin = a
            }
            pin?.coordinate = gcj
        }
    }
}

// MARK: - 地点搜索

final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            if query.isEmpty {
                results = []
            } else {
                completer.queryFragment = query
            }
        }
    }
    @Published var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func updateRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = Array(completer.results.prefix(12))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }

    /// 把搜索建议解析成坐标（结果转成 WGS-84）
    func resolve(_ completion: MKLocalSearchCompletion,
                 done: @escaping (GeoCoordinate?, String) -> Void) {
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                guard let item = response?.mapItems.first else {
                    done(nil, error?.localizedDescription ?? "没有找到该地点")
                    return
                }
                let gcj = GeoCoordinate(item.placemark.coordinate)
                done(CoordinateTransform.gcj02ToWgs84(gcj),
                     item.name ?? completion.title)
            }
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
                                if len > limit {
                                    t = CGSize(width: t.width / len * limit,
                                               height: t.height / len * limit)
                                }
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
