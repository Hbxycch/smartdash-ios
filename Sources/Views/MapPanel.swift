import Foundation
import SwiftUI
import MapKit

/// 仪表页/定位页共用的地图面板：车头朝上或北朝上、缩放、回中。
struct MapPanel: View {
    var coordinate: CLLocationCoordinate2D
    var heading: Double
    var speedKmh: Double
    var hasFix: Bool
    @Binding var distance: Double

    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TrackMap(coordinate: coordinate,
                     heading: heading,
                     headingUp: settings.headingUp,
                     distance: distance,
                     night: settings.mapNight,
                     hasFix: hasFix)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 8) {
                zoomButton("plus")
                zoomButton("minus")
                zoomButton("location.fill") { distance = 260 }
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
                    // 车速胶囊
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
                    .background(
                        Capsule().fill(settings.palette.bgDeep.opacity(0.72))
                    )
                    .overlay(Capsule().stroke(settings.palette.stroke, lineWidth: 1))

                    Spacer()

                    // 朝向
                    Text(settings.headingUp ? "车头朝上" : "北朝上")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(settings.palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(settings.palette.bgDeep.opacity(0.72)))
                }
                .padding(10)
            }
        }
    }

    private func zoomButton(_ icon: String, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() } else {
                switch icon {
                case "plus": distance = max(80, distance * 0.6)
                default: distance = min(4000, distance * 1.7)
                }
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(settings.palette.textPrimary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(settings.palette.bgDeep.opacity(0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(settings.palette.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// MapKit 包装：SwiftUI 的 Map 不支持相机朝向，用 MKMapCamera 才能做车头朝上。
struct TrackMap: UIViewRepresentable {
    var coordinate: CLLocationCoordinate2D
    var heading: Double
    var headingUp: Bool
    var distance: Double
    var night: Bool
    var hasFix: Bool

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView(frame: .zero)
        m.isRotateEnabled = false
        m.isPitchEnabled = false
        m.showsCompass = false
        m.showsScale = false
        m.showsUserLocation = false
        m.isZoomEnabled = false
        m.isScrollEnabled = false
        m.mapType = .mutedStandard
        m.pointOfInterestFilter = .excludingAll
        return m
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.overrideUserInterfaceStyle = night ? .dark : .light
        guard hasFix else { return }
        let cam = MKMapCamera(lookingAtCenter: coordinate,
                              fromDistance: distance,
                              pitch: headingUp ? CGFloat(30) : CGFloat(0),
                              heading: headingUp ? heading : 0)
        map.setCamera(cam, animated: false)
    }
}
