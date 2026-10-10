import SwiftUI

/// Stand-in for the live camera feed while services are mocked, drawn like the mockups.
/// Step 5 replaces it with the real camera preview.
struct CameraBackdrop: View {
    enum Scene { case street, room }

    let scene: Scene

    var body: some View {
        Canvas { context, size in
            func fill(_ points: [(CGFloat, CGFloat)], _ hex: UInt32) {
                var path = Path()
                path.addLines(points.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) })
                path.closeSubpath()
                context.fill(path, with: .color(Color(hex: hex)))
            }

            switch scene {
            case .street:
                fill([(0, 0), (1, 0), (1, 1), (0, 1)], 0x121314)
                fill([(0, 0), (1, 0), (1, 0.427), (0, 0.427)], 0x23262B)
                fill([(0, 0.27), (0.18, 0.27), (0.18, 0.63), (0, 0.63)], 0x2E3137)
                fill([(0.77, 0.225), (1, 0.225), (1, 0.63), (0.77, 0.63)], 0x2E3137)
                fill([(0.38, 0.427), (0.62, 0.427), (1, 1), (0, 1)], 0x393C42)
                fill([(0.46, 0.427), (0.54, 0.427), (0.64, 1), (0.36, 1)], 0x44474D)
            case .room:
                fill([(0, 0), (1, 0), (1, 1), (0, 1)], 0x121314)
                fill([(0, 0), (1, 0), (1, 0.616), (0, 0.616)], 0x2B2E33)
                fill([(0, 0), (0.36, 0.185), (0.36, 0.382), (0, 0.616)], 0x353840)
                fill([(1, 0), (0.64, 0.185), (0.64, 0.382), (1, 0.616)], 0x30333A)
                fill([(0.36, 0.382), (0.64, 0.382), (1, 0.616), (0, 0.616)], 0x3F4249)
                fill([(0.44, 0.232), (0.558, 0.232), (0.558, 0.382), (0.44, 0.382)], 0x23262B)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 0) {
        CameraBackdrop(scene: .street)
        CameraBackdrop(scene: .room)
    }
}
