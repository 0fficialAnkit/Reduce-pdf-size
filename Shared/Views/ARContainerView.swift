//
//  ARContainerView.swift
//  Shared
//

import SwiftUI
import RealityKit
import ARKit
import UIKit

// MARK: - Stable AR Container

/// A UIView subclass that shields the ARView from redundant layout passes.
///
/// During SwiftUI state changes (zone creation, deletion, rec image, etc.),
/// the system triggers `layoutSubviews` even when the container's bounds
/// haven't changed. Each unnecessary layout pass can cause the ARView's
/// CAMetalLayer to reconfigure its drawable pool, which starves Metal
/// rendering and permanently freezes the camera feed.
///
/// This container only propagates frame changes to the ARView when its
/// bounds actually change, preventing SwiftUI layout noise from reaching
/// the Metal rendering pipeline.
private class StableARContainer: UIView {
    private var lastLayoutBounds: CGRect = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != lastLayoutBounds else { return }
        lastLayoutBounds = bounds
        // Only update the ARView frame when bounds genuinely changed
        subviews.first?.frame = bounds
    }
}

// MARK: - AR Container View

/// UIViewRepresentable that wraps ARView and adds native coaching overlay.
struct ARContainerView: UIViewRepresentable {
    let sessionManager: ARSessionManager

    func makeUIView(context: Context) -> UIView {
        let container = StableARContainer(frame: UIScreen.main.bounds)
        container.clipsToBounds = true

        let arView = sessionManager.arView
        arView.frame = container.bounds
        // Do NOT use Auto Layout for the ARView. Auto Layout triggers
        // constraint resolution during every SwiftUI layout pass, which
        // can cause the CAMetalLayer to reconfigure its drawable pool
        // and permanently freeze the camera. Using a fixed frame with
        // the StableARContainer's guarded layoutSubviews is sufficient.
        arView.autoresizingMask = []
        container.addSubview(arView)

        // Add native coaching overlay (only if not already present)
        let hasCoaching = arView.subviews.contains { $0 is ARCoachingOverlayView }
        if !hasCoaching {
            let coaching = ARCoachingOverlayView()
            coaching.session = arView.session
            coaching.goal = .horizontalPlane
            coaching.activatesAutomatically = true
            coaching.frame = arView.bounds
            coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            arView.addSubview(coaching)
        }

        // Start AR session after view is ready for display
        sessionManager.setup()

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
