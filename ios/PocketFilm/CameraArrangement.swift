import SwiftUI

// Swap the layout algorithm, not the child view tree. In particular the
// AVCaptureVideoPreviewLayer must survive a portrait/landscape transition.
struct CameraArrangement<Preview: View, Panel: View>: View {
    let landscape: Bool
    let panelWidth: CGFloat
    let preview: Preview
    let panel: Panel

    var body: some View {
        let layout = landscape
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 8))
        layout {
            preview
            panel.frame(width: landscape ? panelWidth : nil)
        }
    }
}
