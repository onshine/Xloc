// Xloc — MapScreen.swift
// 地图选点 / 搜索 / 手动坐标 / 摇杆。
//
// 这一版针对两个实机问题做了调整：
//   1. 搜索不再把 TextField 直接塞在满屏地图上（键盘弹出会触发复杂布局），
//      改为独立 sheet，输入框和结果列表都在普通列表里。
//   2. 地图瓦片加载失败时不再"一片空白什么都不说"，而是把错误显示出来，
//      并提供手动输入坐标的入口。

import SwiftUI
import MapKit

struct MapScreen: View {
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var locationAuth: LocationAuthorizer

    @State private var picked: GeoCoordinate?          // 始终是 WGS-84
    @State private var altitudeText = "0"
    @State private var showError: String?
    @State private var showSearch = false
    @State private var showManual = false
    @State private var camera: MKCoordinateRegion?
    @State private var hint = "长按地图选点，或搜索地点"
    @State private var mapError: String?

    var body: some View {
        ZStack(alignment: .top) {
            MapCanvas(coordinate: $picked, camera: $camera, loadError: $mapError)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                searchBarButton

                if let err = mapError {
                    mapErrorBanner(err)
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    Spacer()
                    JoystickPad { bearing, meters in
                        engine.nudge(bearing: bearing, meters: meters)
                    }
                    .frame(width: 112, height: 112)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                }

                bottomCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet { coordinate, name in
                apply(coordinate, name: name)
            }
        }
        .sheet(isPresented: $showManual) {
            ManualCoordinateSheet { coordinate in
                apply(coordinate, name: "手动坐标")
            }
        }
        .alert("提示", isPresented: Binding(get: { showError != nil },
                                          set: { if !$0 { showError = nil } })) {
            Button("好", role: .cancel) { showError = nil }
        } message: {
            Text(showError ?? "")
        }
    }

    // MARK: - 顶部

    private var searchBarButton: some View {
        Button {
            showSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("搜索地点、地址、店铺")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func mapErrorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("地图瓦片加载失败")
                    .font(.caption.weight(.semibold))
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("手动输入") { showManual = true }
                .font(.caption.weight(.medium))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 底部

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
                        .frame(width: 52)
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
                    showManual = true
                } label: {
                    Label("输入坐标", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    start()
                } label: {
                    Label("模拟", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(picked == nil)
            }
            .font(.footnote)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 3)
    }

    // MARK: - 动作

    private func apply(_ coordinate: GeoCoordinate, name: String) {
        picked = coordinate
        hint = name.isEmpty ? "已选点" : name
        camera = MKCoordinateRegion(center: CoordinateTransform.wgs84ToGcj02(coordinate).clCoordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    }

    private func useMyLocation() {
        guard let loc = locationAuth.lastLocation else {
            showError = locationAuth.lastError ?? "还没有拿到定位，请检查定位权限"
            return
        }
        apply(GeoCoordinate(loc.coordinate), name: "我的位置")
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
    @Binding var loadError: String?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .standard
        map.showsUserLocation = true
        map.showsBuildings = false
        map.showsTraffic = false
        map.pointOfInterestFilter = .excludingAll
        map.isRotateEnabled = false
        map.isPitchEnabled = false
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
            let gcj = CoordinateTransform.wgs84ToGcj02(c).clCoordinate
            if pin == nil {
                let a = MKPointAnnotation()
                a.title = "模拟位置"
                map.addAnnotation(a)
                pin = a
            }
            pin?.coordinate = gcj
        }

        // 瓦片加载状态：让"空白"变成一条能看懂的提示
        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            DispatchQueue.main.async { self.parent.loadError = nil }
        }

        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.loadError = error.localizedDescription
            }
        }
    }
}

// MARK: - 搜索（独立 sheet）

struct SearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearch()
    @State private var query = ""
    @FocusState private var focused: Bool

    var onPick: (GeoCoordinate, String) -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索地点、地址、店铺", text: $query)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10))
                .padding(12)

                List(search.results, id: \.self) { item in
                    Button {
                        pick(item)
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
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if search.results.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "mappin.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(query.isEmpty ? "输入关键词开始搜索" : "没有找到结果")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("搜索地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onChange(of: query) { value in
                search.query = value
            }
            .onAppear { focused = true }
        }
        .navigationViewStyle(.stack)
    }

    private func pick(_ item: MKLocalSearchCompletion) {
        search.resolve(item) { coordinate, name in
            guard let c = coordinate else { return }
            dismiss()
            onPick(c, name)
        }
    }
}

// MARK: - 手动坐标

struct ManualCoordinateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lat = ""
    @State private var lon = ""

    var onPick: (GeoCoordinate) -> Void

    private var parsed: GeoCoordinate? {
        guard let la = Double(lat.trimmingCharacters(in: .whitespaces)),
              let lo = Double(lon.trimmingCharacters(in: .whitespaces)) else { return nil }
        let c = GeoCoordinate(la, lo)
        return c.isValid ? c : nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("纬度，例如 39.9087", text: $lat)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("经度，例如 116.3975", text: $lon)
                        .keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("WGS-84 坐标")
                } footer: {
                    Text("这里是 GPS 原始坐标（WGS-84）。国内地图显示的是 GCJ-02，两者相差几百米，输入地图上读到的数字会偏。")
                }

                Section {
                    Button("使用这个坐标") {
                        if let c = parsed {
                            dismiss()
                            onPick(c)
                        }
                    }
                    .disabled(parsed == nil)
                }
            }
            .navigationTitle("手动输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 地点搜索（数据层）

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

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let new = Array(completer.results.prefix(20))
        if Thread.isMainThread {
            results = new
        } else {
            DispatchQueue.main.async { self.results = new }
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        if Thread.isMainThread {
            results = []
        } else {
            DispatchQueue.main.async { self.results = [] }
        }
    }

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
                done(CoordinateTransform.gcj02ToWgs84(gcj), item.name ?? completion.title)
            }
        }
    }
}

// MARK: - 摇杆

struct JoystickPad: View {
    var onMove: (Double, Double) -> Void
    @State private var knob: CGSize = .zero
    private let stepMeters: Double = 20

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
