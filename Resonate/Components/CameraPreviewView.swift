import ARKit
import AVFoundation
import SceneKit
import SwiftUI

/// Live camera behind the obstacle overlay, filling the screen (aspect-fill).
/// Purely visual for sighted helpers; VoiceOver skips it.
struct CameraPreviewView: UIViewRepresentable {
    let source: CameraPreviewSource

    func makeUIView(context: Context) -> UIView {
        switch source {
        case .ar(let session):
            let view = ARSCNView()
            view.session = session
            view.scene = SCNScene()
            view.automaticallyUpdatesLighting = false
            view.isAccessibilityElement = false
            return view
        case .capture(let session):
            let view = CapturePreviewUIView()
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            return view
        case .none:
            return UIView()
        }
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class CapturePreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Portrait: rotate the landscape sensor image upright.
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}
