import SwiftUI
import UIKit
import XCTest
@testable import PocketFilm

final class CameraLayoutTests: XCTestCase {
    @MainActor
    func testRotationPreservesPreviewAndControlViews() async throws {
        let state = RotationState()
        let previewLife = ViewLife()
        let panelLife = ViewLife()
        let controller = UIHostingController(rootView: RotationHarness(state: state,
            previewLife: previewLife, panelLife: panelLife))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await settle(window)
        let firstPreview = try XCTUnwrap(previewLife.view)
        let firstPanel = try XCTUnwrap(panelLife.view)

        // Exercise the production arrangement, not a test-only AnyLayout.
        // The two previews in the former conditional layout were destroyed
        // and recreated here, reattaching a live capture session on each turn.
        for landscape in [true, false, true, false, true, false] {
            state.landscape = landscape
            window.frame.size = landscape ? CGSize(width: 844, height: 390) : CGSize(width: 390, height: 844)
            try await settle(window)
            XCTAssertTrue(previewLife.view === firstPreview)
            XCTAssertTrue(panelLife.view === firstPanel)
            XCTAssertEqual(previewLife.created, 1)
            XCTAssertEqual(previewLife.dismantled, 0)
            XCTAssertEqual(panelLife.created, 1)
            XCTAssertEqual(panelLife.dismantled, 0)
            XCTAssertGreaterThan(firstPreview.bounds.width, 0)
            XCTAssertGreaterThan(firstPreview.bounds.height, 0)
        }
    }

    @MainActor private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        // Allow SwiftUI's scheduled render transaction to finish on main.
        try await Task.sleep(nanoseconds: 30_000_000)
        window.layoutIfNeeded()
    }
}

private final class RotationState: ObservableObject {
    @Published var landscape = false
}

private final class ViewLife {
    weak var view: UIView?
    var created = 0
    var dismantled = 0
}

private struct LifecycleProbe: UIViewRepresentable {
    let life: ViewLife
    func makeCoordinator() -> ViewLife { life }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        life.created += 1
        life.view = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: ViewLife) { coordinator.dismantled += 1 }
}

private struct RotationHarness: View {
    @ObservedObject var state: RotationState
    let previewLife: ViewLife
    let panelLife: ViewLife
    var body: some View {
        CameraArrangement(landscape: state.landscape, panelWidth: 300,
            preview: LifecycleProbe(life: previewLife).frame(maxWidth: .infinity, maxHeight: .infinity),
            panel: LifecycleProbe(life: panelLife).frame(minHeight: 100, maxHeight: 200))
    }
}
