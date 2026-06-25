//
//  AdminARManager.swift
//  CampusAdmin
//

import UIKit
import SwiftUI
import RealityKit
import Foundation

// MARK: - Admin Mode

enum AdminMode: String, CaseIterable {
    case place = "Place"
    case connect = "Connect"
}

// MARK: - Admin AR Manager

@Observable
class AdminARManager: NSObject {

    // MARK: - AR Session & Rendering

    let session: ARSessionManager
    let pathRenderer: PathRenderer

    // MARK: - Zone Data

    var zoneManifest = ZoneManifest()
    var currentZone: Zone?

    /// Whether the admin is waiting for the next image anchor to record it for the current zone.
    /// Deduplicated to avoid triggering SwiftUI layout passes that can starve Metal drawables.
    @ObservationIgnored private var _isRecordingImage: Bool = false
    var isRecordingImage: Bool {
        get {
            access(keyPath: \.isRecordingImage)
            return _isRecordingImage
        }
        set {
            if _isRecordingImage != newValue {
                withMutation(keyPath: \.isRecordingImage) {
                    _isRecordingImage = newValue
                }
            }
        }
    }

    // MARK: - Graph Data

    var graph = CampusGraph()

    // MARK: - Mode & Placement State

    var mode: AdminMode = .place
    var selectedType: WaypointType = .location
    var nextLabel: String = ""

    // MARK: - Edge Creation State

    var edgeStartID: UUID?
    private var highlightAnchor: AnchorEntity?

    // MARK: - Computed

    var waypointCount: Int { graph.waypoints.count }
    var edgeCount: Int { graph.edges.count }

    var isGraphConnected: Bool {
        graph.waypoints.count < 2 || GraphValidator.isFullyConnected(graph)
    }

    var orphanCount: Int {
        GraphValidator.orphanedWaypoints(in: graph).count
    }

    var componentCount: Int {
        GraphValidator.connectedComponents(in: graph).count
    }

    // MARK: - Init

    override init() {
        let session = ARSessionManager()
        self.session = session
        self.pathRenderer = PathRenderer(arView: session.arView)
        super.init()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        session.arView.addGestureRecognizer(tap)

        loadManifest()
        // Load zone data but don't call switchZone/runSession — the ARView isn't in the
        // view hierarchy yet. setup() (called from makeUIView) will start the session.
        if let first = zoneManifest.zones.first {
            currentZone = first
            session.activeZoneID = first.id
            session.ensureZoneDirectory(for: first.id)
        }
        loadGraph()

        session.onRelocalized = { [weak self] in
            self?.restoreMarkers()
        }

        session.onImageAnchorDetected = { [weak self] imageName, transform in
            self?.handleImageAnchorDetected(imageName: imageName, transform: transform)
        }
    }

    // MARK: - Tap Handling

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard session.isReady else {
            session.status = "Wait for plane detection"
            return
        }

        let location = recognizer.location(in: session.arView)
        guard let worldPos = session.raycastOnFloor(from: location) else {
            session.status = "No floor hit — tap on a detected surface"
            return
        }

        switch mode {
        case .place:
            handlePlaceTap(at: worldPos)
        case .connect:
            handleEdgeTap(at: worldPos)
        }
    }

    private func handlePlaceTap(at worldPos: SIMD3<Float>) {
        let label: String
        switch selectedType {
        case .location:
            label = nextLabel.isEmpty
                ? "Location \(graph.locationWaypoints.count + 1)"
                : nextLabel
        case .gateway:
            label = nextLabel.isEmpty
                ? "Gateway \(graph.gatewayWaypoints.count + 1)"
                : nextLabel
        case .anchor:
            label = "A\(graph.anchorWaypoints.count + 1)"
        }

        // Tap position is in the live AR frame; stored waypoints live in the
        // authored frame. Apply the inverse correction so rendering (which
        // re-applies it) puts the orb exactly where tapped, including under
        // any active rotation correction.
        let authoredPos = session.inverseTransform(worldPos)
        let waypoint = Waypoint(
            type: selectedType,
            label: label,
            position: authoredPos,
            zoneID: currentZone?.id
        )

        graph.addWaypoint(waypoint)
        session.placeWaypointMarker(for: waypoint)
        saveGraph()

        nextLabel = ""
        session.status = "Placed \(waypoint.type.rawValue): \(label)"
    }

    private func handleEdgeTap(at worldPos: SIMD3<Float>) {
        guard let nearest = findNearestWaypoint(to: worldPos) else {
            session.status = "No waypoint nearby — tap closer to a marker"
            return
        }

        if let startID = edgeStartID {
            // Second tap — create edge
            if startID == nearest.id {
                session.status = "Tap a different waypoint"
                return
            }
            if graph.hasEdge(between: startID, and: nearest.id) {
                session.status = "Edge already exists"
                cancelEdgeSelection()
                return
            }

            graph.addEdge(from: startID, to: nearest.id)
            saveGraph()
            pathRenderer.renderEdges(graph: graph, correctionTransform: session.correctionTransform)
            clearHighlight()

            let fromLabel = graph.getWaypoint(byID: startID)?.label ?? "?"
            session.status = "Edge: \(fromLabel) → \(nearest.label)"
            edgeStartID = nil
        } else {
            // First tap — select start waypoint
            edgeStartID = nearest.id
            highlightWaypoint(nearest)
            session.status = "Selected: \(nearest.label) → tap next waypoint"
        }
    }

    // MARK: - Nearest Waypoint

    func findNearestWaypoint(to position: SIMD3<Float>, maxDistance: Float = 0.5) -> Waypoint? {
        // `position` is in the live AR frame; waypoints are in the authored frame.
        let authored = session.inverseTransform(position)
        return graph.waypoints
            .filter { simd_distance($0.simdPosition, authored) <= maxDistance }
            .min(by: { simd_distance($0.simdPosition, authored) < simd_distance($1.simdPosition, authored) })
    }

    // MARK: - Highlight

    private func highlightWaypoint(_ waypoint: Waypoint) {
        clearHighlight()
        let anchor = AnchorEntity(world: session.transform(waypoint.simdPosition))
        let ring = ModelEntity(
            mesh: .generateSphere(radius: 0.08),
            materials: [SimpleMaterial(color: .systemGreen.withAlphaComponent(0.3), isMetallic: false)]
        )
        anchor.addChild(ring)
        session.arView.scene.addAnchor(anchor)
        highlightAnchor = anchor
    }

    private func clearHighlight() {
        if let anchor = highlightAnchor {
            session.arView.scene.removeAnchor(anchor)
            highlightAnchor = nil
        }
    }

    func cancelEdgeSelection() {
        edgeStartID = nil
        clearHighlight()
        session.status = "Edge selection cancelled"
    }

    // MARK: - Edge Management

    func removeEdge(_ edgeID: UUID) {
        graph.removeEdge(edgeID)
        saveGraph()
        pathRenderer.renderEdges(graph: graph, correctionTransform: session.correctionTransform)
    }

    // MARK: - Marker Management

    func restoreMarkers() {
        session.removeAllMarkers()
        for wp in graph.waypoints {
            session.placeWaypointMarker(for: wp)
        }
        pathRenderer.renderEdges(graph: graph, correctionTransform: session.correctionTransform)
        session.status = "Restored \(graph.waypoints.count) waypoints"
    }

    func removeWaypoint(_ id: UUID) {
        graph.removeWaypoint(id)
        saveGraph()
        restoreMarkers()
    }

    /// Restarts the AR session to recover from a frozen camera feed.
    /// All persisted data (zones, waypoints, edges, world maps) is retained.
    /// Markers and edges are re-rendered after relocalization.
    func refreshSession() {
        cancelEdgeSelection()
        pathRenderer.clearAll()
        session.refreshSession()
        // Markers will be restored via onRelocalized callback if a world map exists,
        // or we restore immediately for a fresh session.
        if !session.isRelocalizing {
            restoreMarkers()
        }
    }

    func undoLastWaypoint() {
        guard let last = graph.waypoints.last else { return }
        removeWaypoint(last.id)
        session.status = "Removed last waypoint"
    }

    // MARK: - Zone Management

    func createZone(name: String) {
        let zone = Zone(name: name)
        zoneManifest.addZone(zone)
        
        let zoneID = zone.id
        let dir = session.zonesDir.appendingPathComponent(zoneID.uuidString)
        
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await MainActor.run { [weak self] in
                self?.saveManifest()
                self?.switchZone(zone)
            }
        }
    }

    func switchZone(_ zone: Zone) {
        // Save current zone's data before switching (only if a zone is active)
        if currentZone != nil, session.activeZoneID != nil {
            saveGraph()
        }

        // Clear scene
        cancelEdgeSelection()
        pathRenderer.clearAll()
        session.removeAllMarkers()

        // Switch
        currentZone = zone
        session.activeZoneID = zone.id
        
        let zoneID = zone.id
        let graphURL = session.graphURL
        let worldMapURL = session.worldMapURL
        let dir = session.zonesDir.appendingPathComponent(zoneID.uuidString)

        Task.detached(priority: .userInitiated) { [weak self] in
            // Ensure directory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            
            // Load graph data
            let graphData = try? Data(contentsOf: graphURL)
            let loadedGraph = graphData.flatMap { CampusGraph.from(jsonData: $0) } ?? CampusGraph()
            
            // Check world map exists
            let hasWorldMap = FileManager.default.fileExists(atPath: worldMapURL.path)
            
            await MainActor.run {
                guard let self = self, self.currentZone?.id == zoneID else { return }
                self.graph = loadedGraph
                self.session.status = "Zone: \(zone.name)"
                
                // Only restart the session if the zone has a saved world map to relocalize from.
                // Unnecessary restarts tear down and rebuild the camera pipeline, which can
                // exhaust GPU/camera resources on some devices.
                if hasWorldMap {
                    self.session.runSession()
                }
            }
        }
    }

    func deleteZone(_ zoneID: UUID) {
        let wasActive = currentZone?.id == zoneID

        // Clear current zone reference BEFORE switchZone so it doesn't save to the deleted zone
        if wasActive {
            currentZone = nil
            session.activeZoneID = nil
        }

        // Remove zone directory in the background to prevent main thread blocking
        let zoneDir = session.zonesDir.appendingPathComponent(zoneID.uuidString)
        Task.detached(priority: .background) {
            try? FileManager.default.removeItem(at: zoneDir)
        }

        zoneManifest.removeZone(zoneID)
        saveManifest()

        // If deleting the active zone, switch to first remaining or fully reset.
        // Defer to next run loop so SwiftUI processes the manifest/zone state
        // changes before we do heavy work (session restart, scene cleanup).
        if wasActive {
            cancelEdgeSelection()
            pathRenderer.clearAll()
            session.removeAllMarkers()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let first = self.zoneManifest.zones.first {
                    self.switchZone(first)
                } else {
                    self.graph = CampusGraph()
                    self.session.resetSession()
                    self.session.status = "No zones — create one to start"
                }
            }
        }
    }

    func renameZone(_ zoneID: UUID, to newName: String) {
        guard var zone = zoneManifest.zone(byID: zoneID) else { return }
        zone.name = newName
        zoneManifest.updateZone(zone)
        saveManifest()
        if currentZone?.id == zoneID {
            currentZone = zone
        }
    }

    // MARK: - Image Recording

    private func handleImageAnchorDetected(imageName: String, transform liveTransform: simd_float4x4) {
        if isRecordingImage, let zone = currentZone {
            isRecordingImage = false

            // Link image name to zone in manifest
            zoneManifest.addImageName(imageName, toZone: zone.id)
            saveManifest()
            currentZone = zoneManifest.zone(byID: zone.id)

            // Record the image's full pose in the authored frame so future
            // detections can recover both translation and yaw drift. Pulling
            // the live transform back through the inverse correction keeps the
            // recorded pose in the canonical authored coordinate system even
            // when a correction is already active at record time.
            let invCorrection = session.correctionTransform.inverse
            let authoredTransform = invCorrection * liveTransform
            let record = ImageAnchorRecord(imageName: imageName, transform: authoredTransform)
            graph.addImageAnchorRecord(record)
            saveGraph()

            let p = record.simdPosition
            session.status = "Recorded image '\(imageName)' at (\(String(format: "%.2f, %.2f, %.2f", p.x, p.y, p.z)))"
            return
        }

        // Not recording — recompute the blended SE(3) correction from every
        // recently-observed anchor that we have a record for.
        applyCorrectionFromImageAnchor(imageName: imageName, transform: liveTransform)
    }

    /// Recomputes `session.correctionTransform` by blending the SE(3) candidate
    /// from every recently-observed anchor with a recorded authored pose, then
    /// re-renders markers and edges if the result is meaningfully different.
    private func applyCorrectionFromImageAnchor(imageName: String, transform liveTransform: simd_float4x4) {
        guard let newCorrection = session.blendedCorrection(
            records: { [graph] name in graph.imageAnchorRecord(named: name) }
        ) else { return }

        let previous = session.correctionTransform
        guard session.correctionDeltaIsSignificant(newCorrection, vs: previous) else { return }

        session.correctionTransform = newCorrection

        // Re-render markers (they bake the offset at placement time) and edges.
        session.removeAllMarkers()
        for wp in graph.waypoints {
            session.placeWaypointMarker(for: wp)
        }
        pathRenderer.renderEdges(graph: graph, correctionTransform: session.correctionTransform)

        let pPrev = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
        let pNew = SIMD3<Float>(newCorrection.columns.3.x, newCorrection.columns.3.y, newCorrection.columns.3.z)
        let driftCm = simd_length(pNew - pPrev) * 100
        session.status = "Accuracy improved (drift: \(String(format: "%.0fcm", driftCm)))"
    }

    func startRecordingImage() {
        guard currentZone != nil else {
            session.status = "Create a zone first"
            return
        }
        isRecordingImage = true
        session.status = "Point camera at a reference image..."

        // Don't call fireCallbackForExistingImageAnchors() — it fires for ALL
        // tracked anchors and may record the wrong one. Instead, rely on
        // session(_:didUpdate anchors:) which will fire the callback for the
        // actively tracked anchor within ~2 seconds.
        // Reset throttle timers so the next tracked anchor fires immediately.
        session.resetImageCallbackThrottles()
    }

    func cancelRecordingImage() {
        isRecordingImage = false
        session.status = "Image recording cancelled"
    }

    // MARK: - Cross-Zone Edge Management

    /// Loads a zone's graph from disk (without switching to it).
    func loadGraphForZone(_ zoneID: UUID) -> CampusGraph? {
        let url = session.zonesDir
            .appendingPathComponent(zoneID.uuidString)
            .appendingPathComponent("graph.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return CampusGraph.from(jsonData: data)
    }

    /// Returns all boundary-eligible waypoints (locations) across all zones for cross-zone linking.
    func allLocationWaypoints() -> [(zone: Zone, waypoint: Waypoint)] {
        // Save current graph first
        saveGraph()

        var result: [(zone: Zone, waypoint: Waypoint)] = []
        for zone in zoneManifest.zones {
            let graph: CampusGraph
            if zone.id == currentZone?.id {
                graph = self.graph
            } else if let loaded = loadGraphForZone(zone.id) {
                graph = loaded
            } else {
                continue
            }
            for wp in graph.locationWaypoints {
                result.append((zone, wp))
            }
        }
        return result
    }

    /// Calculates cross-zone edge weight using a shared image anchor as a coordinate bridge.
    ///
    /// Both zones record the boundary image anchor's position in their own coordinate system.
    /// We transform both waypoints into anchor-relative coordinates and compute the distance
    /// between them. This is accurate regardless of where the anchor sits relative to the edge.
    ///
    /// Returns nil if no shared image anchor with recorded positions exists between the zones.
    func calculateCrossZoneWeight(
        fromWaypointID: UUID, fromZoneID: UUID,
        toWaypointID: UUID, toZoneID: UUID
    ) -> Double? {
        let fromGraph: CampusGraph
        if fromZoneID == currentZone?.id {
            fromGraph = graph
        } else {
            guard let loaded = loadGraphForZone(fromZoneID) else { return nil }
            fromGraph = loaded
        }

        let toGraph: CampusGraph
        if toZoneID == currentZone?.id {
            toGraph = graph
        } else {
            guard let loaded = loadGraphForZone(toZoneID) else { return nil }
            toGraph = loaded
        }

        guard let fromWP = fromGraph.getWaypoint(byID: fromWaypointID),
              let toWP = toGraph.getWaypoint(byID: toWaypointID) else { return nil }

        // Find shared image between the two zones with recorded positions in both graphs
        let fromZone = zoneManifest.zone(byID: fromZoneID)
        let toZone = zoneManifest.zone(byID: toZoneID)
        let sharedImages = Set(fromZone?.referenceImageNames ?? [])
            .intersection(toZone?.referenceImageNames ?? [])

        for imageName in sharedImages {
            if let fromRecord = fromGraph.imageAnchorRecord(named: imageName),
               let toRecord = toGraph.imageAnchorRecord(named: imageName) {
                // Transform both waypoints into anchor-relative coordinates,
                // then compute the distance between them.
                let relativeFrom = fromWP.simdPosition - fromRecord.simdPosition
                let relativeTo = toWP.simdPosition - toRecord.simdPosition
                return Double(simd_distance(relativeFrom, relativeTo))
            }
        }

        return nil
    }

    func createCrossZoneEdge(
        fromWaypointID: UUID,
        fromZoneID: UUID,
        toWaypointID: UUID,
        toZoneID: UUID,
        weight: Double,
        displayName: String? = nil
    ) {
        let edge = CrossZoneEdge(
            fromWaypointID: fromWaypointID,
            fromZoneID: fromZoneID,
            toWaypointID: toWaypointID,
            toZoneID: toZoneID,
            weight: weight,
            displayName: displayName
        )
        zoneManifest.addCrossZoneEdge(edge)
        saveManifest()
        session.status = "Cross-zone edge created"
    }

    func removeCrossZoneEdge(_ id: UUID) {
        zoneManifest.removeCrossZoneEdge(id)
        saveManifest()
    }

    // MARK: - Persistence

    func saveManifest() {
        let dir = session.zonesDir
        let url = session.manifestURL
        guard let data = zoneManifest.jsonData else { return }

        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: session.manifestURL),
              let loaded = ZoneManifest.from(jsonData: data) else { return }
        zoneManifest = loaded
    }

    func saveGraph() {
        let activeZoneID = session.activeZoneID
        let url = session.graphURL
        let dir = session.zonesDir
        guard let data = graph.jsonData else { return }

        Task.detached(priority: .background) {
            if let zoneID = activeZoneID {
                let zoneDir = dir.appendingPathComponent(zoneID.uuidString)
                try? FileManager.default.createDirectory(at: zoneDir, withIntermediateDirectories: true)
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadGraph() {
        guard let data = try? Data(contentsOf: session.graphURL),
              let loaded = CampusGraph.from(jsonData: data) else {
            graph = CampusGraph()
            return
        }
        graph = loaded
    }

    func saveWorldMap() {
        session.saveWorldMap { [weak self] success in
            guard let self, success else { return }
            self.saveGraph()
            let zoneName = self.currentZone?.name ?? "default"
            self.session.status = "Saved world map for \(zoneName) + \(self.graph.waypoints.count) waypoints"
        }
    }

    // MARK: - Tour Path

    var tourStopCount: Int {
        graph.tourPath?.orderedWaypointIDs.count ?? 0
    }

    func addTourStop(_ waypointID: UUID) {
        if graph.tourPath == nil {
            graph.tourPath = TourPath(name: "Campus Tour", orderedWaypointIDs: [])
        }
        graph.tourPath?.orderedWaypointIDs.append(waypointID)
        saveGraph()
    }

    func removeTourStops(at offsets: IndexSet) {
        graph.tourPath?.orderedWaypointIDs.remove(atOffsets: offsets)
        saveGraph()
    }

    func moveTourStop(from source: IndexSet, to destination: Int) {
        graph.tourPath?.orderedWaypointIDs.move(fromOffsets: source, toOffset: destination)
        saveGraph()
    }

    func updateTourName(_ name: String) {
        if graph.tourPath == nil {
            graph.tourPath = TourPath(name: name, orderedWaypointIDs: [])
        } else {
            graph.tourPath?.name = name
        }
        saveGraph()
    }

    func previewTourPath() {
        pathRenderer.clearPath()
        guard let tourPath = graph.tourPath,
              tourPath.orderedWaypointIDs.count >= 2 else {
            session.status = "Tour needs at least 2 stops"
            return
        }

        var allPositions: [SIMD3<Float>] = []
        var unreachableSegments = 0

        for i in 0..<(tourPath.orderedWaypointIDs.count - 1) {
            let fromID = tourPath.orderedWaypointIDs[i]
            let toID = tourPath.orderedWaypointIDs[i + 1]

            if let path = Dijkstra.shortestPath(in: graph, from: fromID, to: toID) {
                for (j, wpID) in path.enumerated() {
                    if !allPositions.isEmpty && j == 0 { continue }
                    if let wp = graph.getWaypoint(byID: wpID) {
                        allPositions.append(wp.simdPosition)
                    }
                }
            } else {
                unreachableSegments += 1
            }
        }

        pathRenderer.renderPath(positions: allPositions, correctionTransform: session.correctionTransform)

        if unreachableSegments > 0 {
            session.status = "Tour preview: \(unreachableSegments) unreachable segment(s)"
        } else {
            session.status = "Tour preview: \(tourPath.orderedWaypointIDs.count) stops"
        }
    }

    func clearTourPreview() {
        pathRenderer.clearPath()
    }

    // MARK: - Export

    /// Creates a temporary copy of the entire zones directory for sharing.
    func exportZoneBundle() -> URL? {
        // Ensure current zone data is saved
        saveGraph()
        saveManifest()

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("CampusZones")

        // Clean up any previous export
        try? fm.removeItem(at: tempDir)

        guard fm.fileExists(atPath: session.zonesDir.path) else { return nil }
        do {
            try fm.copyItem(at: session.zonesDir, to: tempDir)
            return tempDir
        } catch {
            session.status = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Returns a temporary file URL for the current zone's graph JSON, suitable for sharing.
    func exportGraphFile() -> URL? {
        guard let data = graph.jsonData else { return nil }
        let name = currentZone?.name ?? "campusGraph"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_graph.json")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// Returns the world map file URL if it exists.
    func exportWorldMapFile() -> URL? {
        let url = session.worldMapURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Clear

    /// Clears the current zone's graph and world map.
    func clearCurrentZone() {
        cancelEdgeSelection()
        pathRenderer.clearAll()
        session.resetSession()
        graph = CampusGraph()

        try? FileManager.default.removeItem(at: session.graphURL)
        try? FileManager.default.removeItem(at: session.worldMapURL)

        session.status = "Cleared zone data"
    }

    /// Clears all zones and data.
    func clearAll() {
        cancelEdgeSelection()
        pathRenderer.clearAll()
        session.resetSession()
        graph = CampusGraph()

        try? FileManager.default.removeItem(at: session.zonesDir)
        zoneManifest = ZoneManifest()
        currentZone = nil
        session.activeZoneID = nil

        session.status = "Cleared all data"
    }
}
