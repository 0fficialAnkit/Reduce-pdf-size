//
//  PathRenderer.swift
//  Shared
//

import RealityKit
import UIKit

/// Renders 3D path segments and graph edge lines in an AR scene.
class PathRenderer {

    private weak var arView: ARView?
    private var pathAnchors: [AnchorEntity] = []
    private var edgeAnchors: [AnchorEntity] = []

    init(arView: ARView) {
        self.arView = arView
    }

    // MARK: - Navigation Path (yellow)

    /// Draws a continuous path through the given authored-frame positions,
    /// optionally remapped into the live AR-frame via `correctionTransform`.
    func renderPath(
        positions: [SIMD3<Float>],
        color: UIColor = .systemYellow,
        correctionTransform: simd_float4x4 = matrix_identity_float4x4
    ) {
        clearPath()
        guard positions.count >= 2, let arView else { return }

        let corrected = positions.map { p -> SIMD3<Float> in
            let v = correctionTransform * SIMD4<Float>(p.x, p.y, p.z, 1)
            return SIMD3<Float>(v.x, v.y, v.z)
        }
        for i in 0..<(corrected.count - 1) {
            let anchor = createSegment(from: corrected[i], to: corrected[i + 1], color: color)
            anchor.children.first?.components.set(PathSegmentTag())
            pathAnchors.append(anchor)
            arView.scene.addAnchor(anchor)
        }
    }

    func clearPath() {
        guard let arView else { return }
        for anchor in pathAnchors {
            arView.scene.removeAnchor(anchor)
        }
        pathAnchors.removeAll()
    }

    // MARK: - Graph Edges (green)

    /// Draws all edges in the graph as green lines, with each authored endpoint
    /// remapped through `correctionTransform`.
    func renderEdges(
        graph: CampusGraph,
        color: UIColor = .systemGreen,
        correctionTransform: simd_float4x4 = matrix_identity_float4x4
    ) {
        clearEdges()
        guard let arView else { return }

        func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let v = correctionTransform * SIMD4<Float>(p.x, p.y, p.z, 1)
            return SIMD3<Float>(v.x, v.y, v.z)
        }

        for edge in graph.edges {
            guard let from = graph.getWaypoint(byID: edge.fromID),
                  let to = graph.getWaypoint(byID: edge.toID) else { continue }

            let anchor = createSegment(
                from: apply(from.simdPosition),
                to: apply(to.simdPosition),
                color: color
            )
            anchor.children.first?.components.set(EdgeLineTag())
            edgeAnchors.append(anchor)
            arView.scene.addAnchor(anchor)
        }
    }

    func clearEdges() {
        guard let arView else { return }
        for anchor in edgeAnchors {
            arView.scene.removeAnchor(anchor)
        }
        edgeAnchors.removeAll()
    }

    // MARK: - Clear All

    func clearAll() {
        clearPath()
        clearEdges()
    }

    // MARK: - Segment Creation

    private func createSegment(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        color: UIColor
    ) -> AnchorEntity {
        let midpoint = (start + end) / 2
        let direction = end - start
        let length = simd_length(direction)

        let anchor = AnchorEntity(world: midpoint)

        let box = ModelEntity(
            mesh: .generateBox(width: 0.015, height: 0.005, depth: length),
            materials: [UnlitMaterial(color: color.withAlphaComponent(0.8))]
        )

        // Orient the box to point from start to end
        if length > 0.001 {
            let forward = normalize(direction)
            let up = SIMD3<Float>(0, 1, 0)
            let right = normalize(cross(up, forward))
            let correctedUp = cross(forward, right)
            let rotationMatrix = float3x3(columns: (right, correctedUp, forward))
            box.orientation = simd_quatf(rotationMatrix)
        }

        anchor.addChild(box)
        return anchor
    }
}
