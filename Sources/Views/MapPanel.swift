import Foundation
import SwiftUI
import MapKit

/// 仪表页/定位页共用的地图面板：车头朝上或北朝上、缩放、回中、路线、目的地。
/// 控件布局与 Android 版一致：缩放/回中在右下角竖排胶囊组，搜索入口左上角。
struct MapPanel: View {
    var coordinate: CLLocationCoordinate2D
    var heading: Double
    var speedKmh: Double
    var hasFix: Bool
    @Binding var distance: Double

    var route: [CLLocationCoordinate2D] = []
    var destination: Place?
    var onSearch: (() -> Void)?

    @EnvironmentObject var settings: AppSettings
    @State private var follow = true   // true=相机跟随车辆；用户拖动后暂停跟随

    var body: some View {
        ZStack(alignment: .topLeading) {
            TrackMap(coordinate: coordinate,
                     heading: heading,
                     headingUp: settings.headingUp,
                     distance: distance,
                     night: settings.mapNight,
                     hasFix: hasFix,
                     follow: $follow,
                     route: route,
                     destination: destination)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // 左上：搜索入口，车机上这是地图页最重要的一个按钮
            if let onSearch {
                VStack {
                    HStack {
                        Button(action: onSearch) {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(destination?.name ?? "搜目的地")
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundColor(settings.palette.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .frame(maxWidth: 190)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(settings.palette.bgDeep.opacity(0.80))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(settings.palette.stroke, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(10)
            }

            // 右下：缩放 + 回中（与 Android 版同款：一体胶囊，回中键在下方）
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        VStack(spacing: 0) {
                            ctlButton("plus") {
                                distance = max(80, distance * 0.6)
                            }
                            Rectangle()
                                .fill(settings.palette.stroke)
                                .frame(width: 18, height: 1)
                            ctlButton("minus") {
                                distance = min(4000, distance * 1.7)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(settings.palette.bgDeep.opacity(0.78))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(settings.palette.stroke, lineWidth: 1)
                        )

                        if !follow {
                            ctlButton("location.fill") {
                                follow = true
                                distance = 260
                            }
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(settings.palette.bgDeep.opacity(0.78)))
                            .overlay(Circle().stroke(settings.palette.stroke, lineWidth: 1))
                        }
                    }
                }
            }
            .padding(10)

            if !hasFix {
                VStack(spacing: 6) {
                    Image(systemName: "location.slash")
                        .font(.system(size: 22))
                    Text("等待定位…")
                        .font(.system(size: 13))
                }
                .foregroundColor(settings.palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    HStack(spacing: 4) {
                        Text("\(Int(speedKmh.rounded()))")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("km/h")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(settings.palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(settings.palette.bgDeep.opacity(0.72)))
                    .overlay(Capsule().stroke(settings.palette.stroke, lineWidth: 1))

                    Spacer()

                    Text(settings.headingUp ? "车头朝上" : "北朝上")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(settings.palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(settings.palette.bgDeep.opacity(0.72)))
                }
                .padding(.leading, 10)
                .padding(.trailing, 70)   // 给右下角控件让位
                .padding(.bottom, 10)
            }
        }
    }

    private func ctlButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(settings.palette.textPrimary)
                .frame(width: 44, height: 42)
        }
        .buttonStyle(.plain)
    }
}

/// MapKit 包装：SwiftUI 的 Map 不支持相机朝向，用 MKMapCamera 才能做车头朝上。
/// 支持拖动浏览（拖动后暂停跟随，点回中键恢复），并显示我的位置箭头。
struct TrackMap: UIViewRepresentable {
    var coordinate: CLLocationCoordinate2D
    var heading: Double
    var headingUp: Bool
    var distance: Double
    var night: Bool
    var hasFix: Bool
    @Binding var follow: Bool
    var route: [CLLocationCoordinate2D] = []
    var destination: Place?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView(frame: .zero)
        m.isRotateEnabled = false
        m.isPitchEnabled = false
        m.showsCompass = false
        m.showsScale = false
        m.showsUserLocation = true          // 显示我的位置蓝点箭头
        m.isZoomEnabled = false             // 缩放走右下角按钮，避免捏合与相机绑定打架
        m.isScrollEnabled = true            // 允许拖动浏览
        m.userTrackingMode = .none
        m.mapType = .mutedStandard
        m.pointOfInterestFilter = .excludingAll
        m.delegate = context.coordinator

        // 拖动手势：用户拖动时暂停相机跟随（不吞掉地图自身的手势）
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.onPan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        m.addGestureRecognizer(pan)
        return m
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.overrideUserInterfaceStyle = night ? .dark : .light
        context.coordinator.parent = self

        // 路线 / 终点只在变化时重建，避免每帧抖动
        let c = context.coordinator
        if c.routePointCount != route.count || c.destinationId != destination?.id {
            c.routePointCount = route.count
            c.destinationId = destination?.id
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            if route.count > 1 {
                map.addOverlay(MKPolyline(coordinates: route, count: route.count))
            }
            if let d = destination {
                let pin = MKPointAnnotation()
                pin.coordinate = d.coordinate
                pin.title = d.name
                map.addAnnotation(pin)
            }
        }

        // 只在跟随状态下驱动相机；用户拖动浏览时不抢镜头
        guard hasFix, follow else { return }
        // 有路线时拉远一点，能同时看到车和前方路线
        let camDistance = route.count > 1 ? max(distance, 900) : distance
        let cam = MKMapCamera(lookingAtCenter: coordinate,
                              fromDistance: camDistance,
                              pitch: headingUp ? CGFloat(30) : CGFloat(0),
                              heading: headingUp ? heading : 0)
        map.setCamera(cam, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var routePointCount = -1
        var destinationId: String?
        var parent: TrackMap?

        @objc func onPan(_ g: UIPanGestureRecognizer) {
            guard g.state == .began || g.state == .changed else { return }
            parent?.follow = false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = UIColor(red: 0.21, green: 0.84, blue: 0.91, alpha: 1.0)
            r.lineWidth = 6
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let id = "dest"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = UIColor(red: 0.95, green: 0.33, blue: 0.31, alpha: 1.0)
            view.glyphImage = UIImage(systemName: "flag.fill")
            view.canShowCallout = false
            return view
        }
    }
}
