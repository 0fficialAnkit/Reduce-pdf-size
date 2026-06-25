//
//  UserARManager.swift
//  CampusUser
//

import Foundation
import QuartzCore
import RealityKit

// MARK: - Navigation State

enum NavigationState: Equatable {
    case idle
    case navigating(destinationID: UUID)
    case touring(stopIndex: Int)
}

// MARK: - Zone Transition State

enum ZoneTransitionState: Equatable {
    case none                            // No transition in progress
    case transitioning(to: String)       // Switching to a new zone (zone name for UI)
}

// MARK: - User AR Manager

@Observable
class UserARManager {

    // MARK: - AR Session & Rendering

    let session: ARSessionManager
    let pathRenderer: PathRenderer

    // MARK: - Zone Data

    var zoneManifest = ZoneManifest()
    var activeZone: Zone?
    var hasZoneData: Bool { !zoneManifest.zones.isEmpty }

    // MARK: - Graph Data

    /// The active zone's graph (used for rendering in the current zone).
    var graph = CampusGraph()
    /// Merged graph from all zones + cross-zone edges (used for Dijkstra).
    var mergedGraph = CampusGraph()
    var hasGraphData: Bool { !graph.waypoints.isEmpty }
    var hasWorldMap: Bool { session.hasSavedWorldMap }
    var isFullyLoaded: Bool { hasZoneData }

    // MARK: - Cross-Zone Navigation

    /// When navigating cross-zone, the full path split by zone segments.
    var crossZoneSegments: [(zoneID: UUID, waypointIDs: [UUID])] = []
    /// The zone the user needs to transition to next (shown in banner).
    var nextZoneName: String?

    // MARK: - Zone Transition

    var zoneTransitionState: ZoneTransitionState = .none
    var isTransitioning: Bool { zoneTransitionState != .none }

    /// Cooldown after a gateway-triggered zone switch to prevent bouncing back.
    @ObservationIgnored private var lastGatewayTransitionTime: TimeInterval = 0
    private let gatewayCooldown: TimeInterval = 10.0
    /// Distance threshold for gateway proximity detection (meters).
    private let gatewayProximityThreshold: Float = 2.5

    // MARK: - Location State

    var isRelocalized: Bool = false
    var nearestLocation: Waypoint?
    var nearestDistance: Float = .infinity

    // MARK: - Navigation State

    var navigationState: NavigationState = .idle
    var destinationWaypoint: Waypoint?
    var navigationPath: [UUID] = []
    var navigationDistance: Double = 0
    var distanceToDestination: Float = .infinity
    var arrivedMessage: String?

    var isNavigating: Bool {
        if case .navigating = navigationState { return true }
        return false
    }

    var isTouring: Bool {
        if case .touring = navigationState { return true }
        return false
    }

    var isActive: Bool { isNavigating || isTouring }

    // MARK: - Tour State

    var tourStops: [Waypoint] = []
    var currentTourStopIndex: Int = 0

    var hasTour: Bool {
        (graph.tourPath?.orderedWaypointIDs.count ?? 0) >= 2
    }

    var tourName: String {
        graph.tourPath?.name ?? "Campus Tour"
    }

    // MARK: - Init

    init() {
        let session = ARSessionManager()
        self.session = session
        self.pathRenderer = PathRenderer(arView: session.arView)

        loadManifest()

        session.onRelocalized = { [weak self] in
            self?.handleRelocalized()
        }

        session.onImageAnchorDetected = { [weak self] imageName, transform in
            self?.handleImageAnchorDetected(imageName: imageName, transform: transform)
        }

        session.onPlaneDetected = nil
    }

    // MARK: - Zone Manifest Loading

    private func loadManifest() {
        let manifestURL = session.manifestURL
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let loaded = ZoneManifest.from(jsonData: data) else { return }
            await MainActor.run {
                self.zoneManifest = loaded
            }
        }
    }

    // MARK: - Image-Triggered Zone Loading & Correction

    /// Prevents re-entrant zone loading when called from delegate callbacks.
    private var isLoadingZone = false

    private func handleImageAnchorDetected(imageName: String, transform: simd_float4x4) {
        guard let zone = zoneManifest.zone(forImageNamed: imageName) else { return }

        if activeZone?.id == zone.id {
            // Same zone — apply accuracy correction if we have a recorded position
            applyCorrectionFromImageAnchor(imageName: imageName, transform: transform)
            return
        }

        // During active navigation, only auto-switch if the detected zone is the
        // next zone in the cross-zone path. This prevents spurious transitions when
        // images from unrelated zones are detected.
        if isActive && !isNextZoneInPath(zone.id) {
            return
        }

        // Guard against repeated loads (e.g., callback fires multiple times before session resets)
        guard !isLoadingZone else { return }
        isLoadingZone = true

        // Defer zone loading — this callback runs inside an ARSessionDelegate method,
        // and calling session.run() synchronously from a delegate callback is unsafe.
        Task { @MainActor [weak self] in
            guard let self, self.activeZone?.id != zone.id else {
                self?.isLoadingZone = false
                return
            }
            self.zoneTransitionState = .transitioning(to: zone.name)
            self.loadZone(zone)
            self.isLoadingZone = false
        }
    }

    /// Checks if the given zone is the next zone in the cross-zone navigation path.
    private func isNextZoneInPath(_ zoneID: UUID) -> Bool {
        guard let activeID = activeZone?.id else { return true }
        var foundActive = false
        for segment in crossZoneSegments {
            if segment.zoneID == activeID {
                foundActive = true
                continue
            }
            if foundActive {
                return segment.zoneID == zoneID
            }
        }
        // If no segments found after active zone, allow the transition
        // (might be a simple two-zone case or the segments are already pruned)
        return true
    }

    // MARK: - Accuracy Correction

    private func applyCorrectionFromImageAnchor(imageName: String, transform: simd_float4x4) {
        guard isRelocalized else { return }

        // Recompute the full SE(3) correction from every anchor seen recently.
        // The single `imageName` argument is just the trigger — the blender
        // pulls fresh transforms for all visible anchors out of the session's
        // recentImageAnchors cache.
        guard let newCorrection = session.blendedCorrection(
            records: { [graph] name in graph.imageAnchorRecord(named: name) }
        ) else { return }

        let previous = session.correctionTransform
        guard session.correctionDeltaIsSignificant(newCorrection, vs: previous) else { return }

        session.correctionTransform = newCorrection

        // Re-render everything with the new correction
        placeLocationMarkers()
        if isActive {
            rerenderActivePath()
        }

        let pPrev = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
        let pNew = SIMD3<Float>(newCorrection.columns.3.x, newCorrection.columns.3.y, newCorrection.columns.3.z)
        let driftCm = simd_length(pNew - pPrev) * 100
        session.status = "Accuracy improved (drift: \(String(format: "%.0fcm", driftCm)))"
    }

    private func rerenderActivePath() {
        guard !navigationPath.isEmpty else { return }
        renderActiveZoneSegment()
    }

    func loadZone(_ zone: Zone) {
        // Do NOT cancel active navigation — preserve it for seamless cross-zone transitions.
        // The navigation state (navigationPath, crossZoneSegments, destinationWaypoint)
        // survives zone transitions. After relocalization in the new zone, handleRelocalized()
        // re-renders the new zone's path segment.

        // Clear scene (markers + paths will be restored after relocalization)
        pathRenderer.clearAll()
        session.removeAllMarkers()

        // Switch zone
        activeZone = zone
        session.activeZoneID = zone.id
        isRelocalized = false

        // Load zone's graph
        loadGraph()

        // Restart session (loads zone's world map for relocalization)
        session.runSession()

        if isActive {
            session.status = "Entering \(zone.name) — relocalize to continue navigation..."
        } else {
            session.status = "Loading zone: \(zone.name)..."
        }
    }

    /// Restarts the AR session to recover from a frozen camera feed.
    /// All data is retained; markers are restored after relocalization.
    func refreshSession() {
        pathRenderer.clearAll()
        isRelocalized = false
        session.refreshSession()
    }

    /// Allows manually selecting a zone from the zone list.
    /// Unlike image-anchor-triggered zone loads, this cancels active navigation
    /// since it's an intentional user action.
    func selectZone(_ zone: Zone) {
        if isActive {
            cancelNavigation()
        }
        lastGatewayTransitionTime = 0  // Reset cooldown for manual selection
        loadZone(zone)
    }

    // MARK: - Graph Loading

    func loadGraph() {
        let graphURL = session.graphURL
        Task.detached(priority: .userInitiated) {
            let loadedGraph: CampusGraph
            if let data = try? Data(contentsOf: graphURL),
               let parsed = CampusGraph.from(jsonData: data) {
                loadedGraph = parsed
            } else {
                loadedGraph = CampusGraph()
            }
            
            await MainActor.run {
                self.graph = loadedGraph
                self.rebuildMergedGraph()
            }
        }
    }

    /// Loads all zone graphs and combines them with cross-zone edges for Dijkstra.
    func rebuildMergedGraph() {
        let zones = zoneManifest.zones
        let activeZoneID = activeZone?.id
        let currentGraph = graph
        let crossZoneEdges = zoneManifest.crossZoneEdges
        let zonesDir = session.zonesDir
        
        Task.detached(priority: .userInitiated) {
            var zoneGraphs: [(zoneID: UUID, graph: CampusGraph)] = []

            for zone in zones {
                let zoneGraph: CampusGraph
                if zone.id == activeZoneID {
                    zoneGraph = currentGraph
                } else {
                    let url = zonesDir
                        .appendingPathComponent(zone.id.uuidString)
                        .appendingPathComponent("graph.json")
                    if let data = try? Data(contentsOf: url),
                       let loaded = CampusGraph.from(jsonData: data) {
                        zoneGraph = loaded
                    } else {
                        continue
                    }
                }
                zoneGraphs.append((zone.id, zoneGraph))
            }

            let newMergedGraph = CampusGraph.merged(
                zoneGraphs: zoneGraphs,
                crossZoneEdges: crossZoneEdges
            )
            
            await MainActor.run {
                self.mergedGraph = newMergedGraph
            }
        }
    }

    // MARK: - Zone Bundle Import

    func importZoneBundle(from sourceURL: URL) {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        
        let zonesDir = self.session.zonesDir
        let fm = FileManager.default
        
        Task.detached(priority: .userInitiated) {
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                // Remove existing zones directory
                if fm.fileExists(atPath: zonesDir.path) {
                    try fm.removeItem(at: zonesDir)
                }

                // Copy imported bundle to Documents/zones/
                try fm.copyItem(at: sourceURL, to: zonesDir)

                let manifestURL = zonesDir.appendingPathComponent("manifest.json")
                let newManifest = (try? Data(contentsOf: manifestURL)).flatMap { ZoneManifest.from(jsonData: $0) }

                await MainActor.run {
                    if let newManifest {
                        self.zoneManifest = newManifest
                    }

                    if self.hasZoneData {
                        self.rebuildMergedGraph()
                        self.session.status = "Imported \(self.zoneManifest.zones.count) zone(s) — scan a marker to begin"
                    } else {
                        self.session.status = "Import failed — no valid zone data found"
                    }
                }
            } catch {
                await MainActor.run {
                    self.session.status = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Legacy Single-File Import (backward compat)

    func importGraph(from sourceURL: URL) {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        
        Task.detached(priority: .userInitiated) {
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: sourceURL)
                
                await MainActor.run {
                    if let zoneID = self.session.activeZoneID {
                        self.session.ensureZoneDirectory(for: zoneID)
                    }
                }
                
                let destURL = await MainActor.run { self.session.graphURL }
                try data.write(to: destURL, options: .atomic)
                
                let parsedGraph = CampusGraph.from(jsonData: data) ?? CampusGraph()
                
                await MainActor.run {
                    self.graph = parsedGraph
                    self.rebuildMergedGraph()
                    
                    if self.hasGraphData {
                        self.session.status = "Graph imported — \(self.graph.locationWaypoints.count) locations"
                        if self.isRelocalized {
                            self.placeLocationMarkers()
                        }
                    } else {
                        self.session.status = "Import failed — invalid graph data"
                    }
                }
            } catch {
                await MainActor.run {
                    self.session.status = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func importWorldMap(from sourceURL: URL) {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        
        Task.detached(priority: .userInitiated) {
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: sourceURL)
                
                await MainActor.run {
                    if let zoneID = self.session.activeZoneID {
                        self.session.ensureZoneDirectory(for: zoneID)
                    }
                }
                
                // We need to capture worldMapURL safely
                let destURL = await MainActor.run { self.session.worldMapURL }
                try data.write(to: destURL, options: .atomic)
                
                await MainActor.run {
                    self.session.status = "World map imported — restarting session..."
                    self.isRelocalized = false
                    self.session.runSession()
                }
            } catch {
                await MainActor.run {
                    self.session.status = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Relocalization

    private func handleRelocalized() {
        isRelocalized = true
        zoneTransitionState = .none
        placeLocationMarkers()
        let zoneName = activeZone?.name ?? "default"

        // Resume cross-zone navigation if active
        if isActive {
            pruneCompletedSegments()
            updateNextZoneBanner()
            renderActiveZoneSegment()
            session.status = "Relocalized in \(zoneName) — continuing navigation"
        } else {
            session.status = "Relocalized in \(zoneName) — \(graph.locationWaypoints.count) locations"
        }
    }

    /// Removes cross-zone segments for zones the user has already passed through.
    private func pruneCompletedSegments() {
        guard let activeID = activeZone?.id else { return }
        if let activeIndex = crossZoneSegments.firstIndex(where: { $0.zoneID == activeID }) {
            if activeIndex > 0 {
                crossZoneSegments.removeSubrange(0..<activeIndex)
            }
        }
    }

    private func placeLocationMarkers() {
        session.removeAllMarkers()
        for wp in graph.locationWaypoints {
            session.placeWaypointMarker(for: wp)
        }
        for wp in graph.gatewayWaypoints {
            session.placeWaypointMarker(for: wp)
        }
    }

    // MARK: - Nearest Location

    func updateNearestLocation() {
        let camPos = session.cameraPosition
        guard camPos != .zero else { return }

        var bestWP: Waypoint?
        var bestDist: Float = .infinity

        for wp in graph.locationWaypoints {
            let dist = simd_distance(wp.simdPosition, camPos)
            if dist < bestDist {
                bestDist = dist
                bestWP = wp
            }
        }

        nearestLocation = bestWP
        nearestDistance = bestDist

        checkArrival()
        checkGatewayProximity(camPos: camPos)
    }

    // MARK: - Gateway Proximity Detection

    /// Checks if the user is near a gateway waypoint in the current zone.
    /// If so, finds the linked zone via CrossZoneEdge and triggers an automatic zone switch.
    private func checkGatewayProximity(camPos: SIMD3<Float>) {
        guard isRelocalized, !isLoadingZone else { return }
        guard let activeID = activeZone?.id else { return }

        // Cooldown: prevent bouncing back after a gateway transition
        let now = CACurrentMediaTime()
        guard now - lastGatewayTransitionTime >= gatewayCooldown else { return }

        // During navigation, only switch to the next zone in the path
        let crossZoneEdges = zoneManifest.crossZoneEdges

        for gateway in graph.gatewayWaypoints {
            let correctedPos = session.transform(gateway.simdPosition)
            let dist = simd_distance(camPos, correctedPos)
            guard dist < gatewayProximityThreshold else { continue }

            // Find the cross-zone edge that uses this gateway
            guard let edge = crossZoneEdges.first(where: {
                ($0.fromWaypointID == gateway.id && $0.fromZoneID == activeID) ||
                ($0.toWaypointID == gateway.id && $0.toZoneID == activeID)
            }) else { continue }

            // Determine the other zone
            let otherZoneID = edge.fromZoneID == activeID ? edge.toZoneID : edge.fromZoneID
            guard let otherZone = zoneManifest.zone(byID: otherZoneID) else { continue }

            // During navigation, only switch to the next zone in the path
            if isActive && !isNextZoneInPath(otherZoneID) { continue }

            // Trigger zone transition
            lastGatewayTransitionTime = now
            zoneTransitionState = .transitioning(to: otherZone.name)
            loadZone(otherZone)
            return
        }
    }

    // MARK: - Navigation

    func navigateTo(_ destination: Waypoint) {
        guard let source = nearestLocation else {
            session.status = "Cannot determine your location"
            return
        }

        if source.id == destination.id {
            session.status = "You are already at \(destination.label)"
            return
        }

        // Ensure merged graph has data for pathfinding
        guard !mergedGraph.waypoints.isEmpty else {
            session.status = "Map data still loading — try again in a moment"
            return
        }

        // Use merged graph for cross-zone pathfinding
        guard let path = Dijkstra.shortestPath(in: mergedGraph, from: source.id, to: destination.id) else {
            // Provide diagnostic info — is the source or destination missing from the merged graph?
            let sourceExists = mergedGraph.getWaypoint(byID: source.id) != nil
            let destExists = mergedGraph.getWaypoint(byID: destination.id) != nil
            if !sourceExists {
                session.status = "Your location is not in the navigation graph"
            } else if !destExists {
                session.status = "Destination not found in navigation graph"
            } else {
                session.status = "No connected path to \(destination.label)"
            }
            return
        }

        arrivedMessage = nil
        navigationPath = path
        destinationWaypoint = destination
        navigationDistance = Dijkstra.pathDistance(in: mergedGraph, path: path)
        navigationState = .navigating(destinationID: destination.id)

        // Split path by zone for rendering
        crossZoneSegments = splitPathByZone(path)
        updateNextZoneBanner()

        // Render only the active zone's segment
        renderActiveZoneSegment()
        session.status = "Navigating to \(destination.label)"
    }

    func cancelNavigation() {
        navigationState = .idle
        navigationPath = []
        crossZoneSegments = []
        nextZoneName = nil
        zoneTransitionState = .none
        destinationWaypoint = nil
        distanceToDestination = .infinity
        arrivedMessage = nil
        pathRenderer.clearPath()
        session.status = "Navigation cancelled"
    }

    /// Splits a full cross-zone path into segments grouped by zone.
    private func splitPathByZone(_ waypointIDs: [UUID]) -> [(zoneID: UUID, waypointIDs: [UUID])] {
        guard let activeZoneID = activeZone?.id else {
            return waypointIDs.isEmpty ? [] : [(UUID(), waypointIDs)]
        }

        var segments: [(zoneID: UUID, waypointIDs: [UUID])] = []
        var currentSegment: [UUID] = []
        var currentZoneID: UUID = activeZoneID

        for wpID in waypointIDs {
            let wpZone = mergedGraph.getWaypoint(byID: wpID)?.zoneID ?? activeZoneID
            if wpZone != currentZoneID && !currentSegment.isEmpty {
                segments.append((currentZoneID, currentSegment))
                currentSegment = []
                currentZoneID = wpZone
            }
            currentSegment.append(wpID)
        }
        if !currentSegment.isEmpty {
            segments.append((currentZoneID, currentSegment))
        }
        return segments
    }

    /// Updates the "next zone" banner text based on cross-zone segments.
    private func updateNextZoneBanner() {
        guard let activeID = activeZone?.id else {
            nextZoneName = nil
            return
        }
        // Find the first segment that's NOT in the active zone
        if let nextSegment = crossZoneSegments.first(where: { $0.zoneID != activeID }) {
            nextZoneName = zoneManifest.zone(byID: nextSegment.zoneID)?.name
        } else {
            nextZoneName = nil
        }
    }

    /// Renders only the path segment for the currently active zone.
    private func renderActiveZoneSegment() {
        guard let activeID = activeZone?.id else { return }
        if let segment = crossZoneSegments.first(where: { $0.zoneID == activeID }) {
            // Use local zone graph for position lookup — it has the correct positions
            // in the active zone's ARWorldMap coordinate system. Falling back to
            // mergedGraph for waypoints that might only exist there (e.g., cross-zone
            // boundary waypoints loaded before the local graph was set).
            let positions = segment.waypointIDs.compactMap { wpID -> SIMD3<Float>? in
                graph.getWaypoint(byID: wpID)?.simdPosition
                    ?? mergedGraph.getWaypoint(byID: wpID)?.simdPosition
            }
            pathRenderer.renderPath(positions: positions, correctionTransform: session.correctionTransform)
        } else {
            pathRenderer.clearPath()
        }
    }

    private func renderNavigationPath(_ waypointIDs: [UUID]) {
        let positions = waypointIDs.compactMap { wpID -> SIMD3<Float>? in
            graph.getWaypoint(byID: wpID)?.simdPosition
                ?? mergedGraph.getWaypoint(byID: wpID)?.simdPosition
        }
        pathRenderer.renderPath(positions: positions, correctionTransform: session.correctionTransform)
    }

    // MARK: - Arrival Detection

    private func checkArrival() {
        let camPos = session.cameraPosition
        guard camPos != .zero else { return }

        switch navigationState {
        case .navigating(let destID):
            // Check if the destination is in the current zone's graph
            if let dest = graph.getWaypoint(byID: destID) {
                // Destination is in the active zone — check arrival directly
                let correctedPos = session.transform(dest.simdPosition)
                distanceToDestination = simd_distance(camPos, correctedPos)
                if distanceToDestination < 2.0 {
                    pathRenderer.clearPath()
                    navigationState = .idle
                    navigationPath = []
                    crossZoneSegments = []
                    nextZoneName = nil
                    arrivedMessage = "Arrived at \(dest.label)"
                    session.status = arrivedMessage!
                }
            } else {
                // Destination is in another zone — show distance to the boundary
                // (end of current zone's segment) so the user knows how far to walk
                updateDistanceToSegmentEnd(camPos: camPos)
            }

        case .touring(let stopIndex):
            guard stopIndex < tourStops.count else { return }
            let stop = tourStops[stopIndex]
            let correctedPos = session.transform(stop.simdPosition)
            let dist = simd_distance(camPos, correctedPos)
            if dist < 2.0 {
                advanceToNextTourStop()
            }

        case .idle:
            break
        }
    }

    /// When destination is in another zone, show distance to the boundary waypoint
    /// at the end of the active zone's segment.
    private func updateDistanceToSegmentEnd(camPos: SIMD3<Float>) {
        guard let activeID = activeZone?.id,
              let segment = crossZoneSegments.first(where: { $0.zoneID == activeID }),
              let lastWPID = segment.waypointIDs.last,
              let lastWP = graph.getWaypoint(byID: lastWPID) else {
            distanceToDestination = .infinity
            return
        }
        let correctedPos = session.transform(lastWP.simdPosition)
        distanceToDestination = simd_distance(camPos, correctedPos)
    }

    // MARK: - Tour Mode

    func startTour() {
        guard let tourPath = graph.tourPath,
              tourPath.orderedWaypointIDs.count >= 2 else {
            session.status = "No tour path configured"
            return
        }

        arrivedMessage = nil
        tourStops = tourPath.orderedWaypointIDs.compactMap { graph.getWaypoint(byID: $0) }
        currentTourStopIndex = 0
        navigationState = .touring(stopIndex: 0)

        navigateToTourStop(0)
        session.status = "Tour: \(tourPath.name) — stop 1/\(tourStops.count)"
    }

    private func navigateToTourStop(_ index: Int) {
        guard index < tourStops.count else {
            completeTour()
            return
        }

        let stop = tourStops[index]
        destinationWaypoint = stop

        // Find path from current nearest location to this tour stop
        if let source = nearestLocation,
           source.id != stop.id,
           let path = Dijkstra.shortestPath(in: graph, from: source.id, to: stop.id) {
            renderNavigationPath(path)
            navigationPath = path
        } else {
            // Already at this stop or no path — try next
            if let source = nearestLocation, source.id == stop.id {
                advanceToNextTourStop()
                return
            }
            pathRenderer.clearPath()
            navigationPath = []
        }

        session.status = "Tour stop \(index + 1)/\(tourStops.count): \(stop.label)"
    }

    private func advanceToNextTourStop() {
        currentTourStopIndex += 1
        if currentTourStopIndex >= tourStops.count {
            completeTour()
        } else {
            navigationState = .touring(stopIndex: currentTourStopIndex)
            navigateToTourStop(currentTourStopIndex)
        }
    }

    private func completeTour() {
        pathRenderer.clearPath()
        navigationState = .idle
        navigationPath = []
        destinationWaypoint = nil
        arrivedMessage = "Tour complete!"
        session.status = "Tour complete!"
    }

    func cancelTour() {
        navigationState = .idle
        tourStops = []
        currentTourStopIndex = 0
        destinationWaypoint = nil
        navigationPath = []
        arrivedMessage = nil
        pathRenderer.clearPath()
        session.status = "Tour cancelled"
    }

    // MARK: - Location Waypoints

    /// All location waypoints from the merged graph (across all zones).
    var allLocationWaypoints: [Waypoint] {
        mergedGraph.locationWaypoints
    }

    /// Location waypoints from the active zone's graph only.
    var locationWaypoints: [Waypoint] {
        graph.locationWaypoints
    }
}
