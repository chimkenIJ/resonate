import MapKit
import SwiftUI

/// Dark map with the step-free route in slate and avoided hazards marked.
/// MapKit is only used for display; the route itself comes from Valhalla.
/// Hidden from VoiceOver: the route sheet speaks the same information.
struct RouteMapView: View {
    let route: Route

    private var start: CLLocationCoordinate2D {
        (route.polyline.first ?? route.destination.coordinate).coordinate
    }

    var body: some View {
        Map(initialPosition: .region(region)) {
            MapPolyline(coordinates: route.polyline.map(\.coordinate))
                .stroke(Accent.slate.color, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))

            Annotation("Start", coordinate: start, anchor: .center) {
                Circle()
                    .fill(Palette.textPrimary)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Palette.mapBackground, lineWidth: 6))
            }
            .annotationTitles(.hidden)

            Annotation(route.destination.name, coordinate: route.destination.coordinate.coordinate, anchor: .bottomLeading) {
                Image(systemName: "mappin")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 4, bottomTrailingRadius: 22, topTrailingRadius: 22)
                            .fill(Accent.sand.color)
                    )
            }
            .annotationTitles(.hidden)

            ForEach(route.avoided) { hazard in
                Annotation(hazard.label, coordinate: hazard.coordinate.coordinate, anchor: .top) {
                    VStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Accent.clay.color))
                            .overlay(Circle().stroke(Palette.mapBackground, lineWidth: 3))
                        TagLabel(text: hazard.label)
                            .fixedSize()
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {}
        .accessibilityHidden(true)
    }

    /// Fits the whole route with some padding.
    private var region: MKCoordinateRegion {
        let points = route.polyline + [route.destination.coordinate]
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.8, 0.004),
                longitudeDelta: max((maxLon - minLon) * 1.8, 0.004)
            )
        )
    }
}

#Preview {
    RouteMapView(route: SampleData.route(to: SampleData.places[2]))
        .preferredColorScheme(.dark)
}
