//
//  ARSessionManager.swift
//  Shared
//

import ARKit
import RealityKit
import UIKit

// MARK: - Mapping Quality

enum MappingQuality: String {
    case notAvailable = "Not Available"
    case limited = "Limited"
    case extending = "Extending"
    case mapped = "Mapped"
}

// MARK: - AR Session Manager

@Observable
class ARSessionManager: NSObject {

    // MARK: - Public State (deduplicated to avoid excessive SwiftUI invalidations)

    // @Observable does NOT check for equality — every property write fires a SwiftUI
    // observation notification even if the value is identical. During AR delegate callbacks
    // at 60fps this floods SwiftUI with layout invalidations, which can starve the
    // CAMetalLayer drawable pool and permanently freeze the camera feed.
    //
    // For properties updated at high frequency we use @ObservationIgnored backing storage
    // with manual access()/withMutation() that only fires when the value actually changes.

    @ObservationIgnored private var _status: String = "Initializing..."
    var status: String {
        get {
            access(keyPath: \.status)
            return _status
        }
        set {
            if _status != newValue {
                withMutation(keyPath: \.status) {
                    _status = newValue
                }
            }
        }
    }

    @ObservationIgnored private var _isReady: Bool = false
    var isReady: Bool {
        get {
            access(keyPath: \.isReady)
            return _isReady
        }
        set {
            if _isReady != newValue {
                withMutation(keyPath: \.isReady) {
                    _isReady = newValue
                }
            }
        }
    }

    @ObservationIgnored private var _mappingQuality: MappingQuality = .notAvailable
    var mappingQuality: MappingQuality {
        get {
            access(keyPath: \.mappingQuality)
            return _mappingQuality
        }
        set {
            if _mappingQuality != newValue {
                withMutation(keyPath: \.mappingQuality) {
                    _mappingQuality = newValue
                }
            }
        }
    }

    var canSaveWorldMap: Bool { mappingQuality == .mapped }

    @ObservationIgnored private var _isRelocalizing: Bool = false
    var isRelocalizing: Bool {
        get {
            access(keyPath: \.isRelocalizing)
            return _isRelocalizing
        }
        set {
            if _isRelocalizing != newValue {
                withMutation(keyPath: \.isRelocalizing) {
                    _isRelocalizing = newValue
                }
            }
        }
    }

    var imageAnchorsDetected: Int = 0

    @ObservationIgnored private var _cameraPosition: SIMD3<Float> = .zero
    var cameraPosition: SIMD3<Float> {
        get {
            access(keyPath: \.cameraPosition)
            return _cameraPosition
        }
        set {
            if _cameraPosition != newValue {
                withMutation(keyPath: \.cameraPosition) {
                    _cameraPosition = newValue
                }
            }
        }
    }

    // MARK: - Zone State

    var activeZoneID: UUID?

    // MARK: - Accuracy Correction

    /// Rigid transform that maps an authored-frame position to the live AR-frame
    /// position. Computed (and continuously refined) from detected image anchors
    /// vs their recorded authored poses. Identity when no anchors have been
    /// observed yet. Applied to marker placement and path rendering to correct
    /// both translation drift and yaw drift accumulated by the world map.
    var correctionTransform: simd_float4x4 = matrix_identity_float4x4

    /// Translation component of `correctionTransform`. Retained for callers that
    /// only care about position offset (e.g. legacy code paths).
    var correctionOffset: SIMD3<Float> {
        SIMD3(correctionTransform.columns.3.x,
              correctionTransform.columns.3.y,
              correctionTransform.columns.3.z)
    }

    var hasCorrectionApplied: Bool {
        correctionTransform != matrix_identity_float4x4
    }

    /// Maps an authored-frame point into the live AR-frame.
    func transform(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = correctionTransform * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    /// Inverse mapping — converts a live AR-frame point back into the
    /// authored frame. Used by admin tap handling so newly-placed waypoints are
    /// stored in the canonical authored coordinate system regardless of the
    /// current correction.
    func inverseTransform(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let inv = correctionTransform.inverse
        let v = inv * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    // MARK: - Correction Blending

    /// SE(3) correction candidate from a single anchor: the rigid transform that
    /// takes the authored anchor pose onto the live anchor pose, applied around
    /// the anchor location so a waypoint co-located with the anchor maps cleanly.
    ///
    /// `delta_R = q_live * q_authored.inverse`
    /// `delta_t = p_live - delta_R * p_authored`
    ///
    /// When the authored record has no recorded rotation (legacy data) we set
    /// `q_authored = q_live` so the rotation correction is identity — the result
    /// reduces to translation-only, matching the prior behaviour.
    func perAnchorCorrection(
        authored: simd_float4x4,
        live: simd_float4x4,
        hasAuthoredRotation: Bool
    ) -> simd_float4x4 {
        let qLive = simd_quaternion(live)
        let qAuthored = hasAuthoredRotation ? simd_quaternion(authored) : qLive
        let deltaR = qLive * qAuthored.inverse
        let pAuthored = SIMD3<Float>(authored.columns.3.x, authored.columns.3.y, authored.columns.3.z)
        let pLive = SIMD3<Float>(live.columns.3.x, live.columns.3.y, live.columns.3.z)
        let rotated = deltaR.act(pAuthored)
        let deltaT = pLive - rotated
        var result = simd_float4x4(deltaR)
        result.columns.3 = SIMD4<Float>(deltaT.x, deltaT.y, deltaT.z, 1)
        return result
    }

    /// Computes a blended SE(3) correction across every anchor that has been
    /// observed within `correctionBlendWindow` seconds and has a recorded
    /// authored pose, weighted by `exp(-age / correctionBlendTau)`. Quaternions
    /// are averaged via hemisphere-aligned weighted nlerp (good enough for the
    /// small relative rotations that drift correction produces; full slerp
    /// generalises poorly to >2 inputs).
    ///
    /// Returns `nil` when no recently-observed anchor has a matching record.
    func blendedCorrection(
        records lookup: (String) -> ImageAnchorRecord?
    ) -> simd_float4x4? {
        let now = CACurrentMediaTime()
        var candidates: [(matrix: simd_float4x4, weight: Float)] = []

        for (name, info) in recentImageAnchors {
            let age = now - info.timestamp
            if age > correctionBlendWindow { continue }
            guard let record = lookup(name) else { continue }
            let candidate = perAnchorCorrection(
                authored: record.authoredTransform,
                live: info.transform,
                hasAuthoredRotation: record.hasAuthoredRotation
            )
            let weight = Float(exp(-age / correctionBlendTau))
            candidates.append((candidate, weight))
        }

        guard !candidates.isEmpty else { return nil }

        let total = candidates.reduce(Float(0)) { $0 + $1.weight }
        guard total > 1e-6 else { return nil }

        var sumT = SIMD3<Float>.zero
        var sumQ = SIMD4<Float>.zero
        var refQ: SIMD4<Float>?

        for (m, w) in candidates {
            let nw = w / total
            let t = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            sumT += t * nw

            var q = simd_quaternion(m).vector
            if let r = refQ, simd_dot(q, r) < 0 { q = -q }
            if refQ == nil { refQ = q }
            sumQ += q * nw
        }

        // Guard against a degenerate near-zero quaternion from cancellation
        let qLen = simd_length(sumQ)
        let avgVec = qLen > 1e-6 ? sumQ / qLen : SIMD4<Float>(0, 0, 0, 1)
        let avgQ = simd_quatf(vector: avgVec)
        var result = simd_float4x4(avgQ)
        result.columns.3 = SIMD4<Float>(sumT.x, sumT.y, sumT.z, 1)
        return result
    }

    /// Tests whether `candidate` differs from `baseline` enough to be worth
    /// re-rendering for. Defaults: 1cm translation OR 0.5° rotation.
    func correctionDeltaIsSignificant(
        _ candidate: simd_float4x4,
        vs baseline: simd_float4x4,
        translationThreshold: Float = 0.01,
        rotationThreshold: Float = 0.0087
    ) -> Bool {
        let pa = SIMD3<Float>(candidate.columns.3.x, candidate.columns.3.y, candidate.columns.3.z)
        let pb = SIMD3<Float>(baseline.columns.3.x, baseline.columns.3.y, baseline.columns.3.z)
        if simd_length(pa - pb) > translationThreshold { return true }

        let qa = simd_quaternion(candidate).vector
        let qb = simd_quaternion(baseline).vector
        let d = abs(simd_dot(qa, qb))
        let angle = 2 * acos(min(Float(1.0), d))
        return angle > rotationThreshold
    }

    // MARK: - Callbacks (not observed by SwiftUI)

    @ObservationIgnored var onRelocalized: (() -> Void)?
    @ObservationIgnored var onPlaneDetected: (() -> Void)?
    @ObservationIgnored var onImageAnchorDetected: ((String, simd_float4x4) -> Void)?

    // MARK: - ARView

    let arView: ARView = {
        // Initialize with screen bounds so the CAMetalLayer starts with a valid
        // drawable size. Starting at .zero means the layer can't allocate drawables
        // until it's resized, and the first resize during a layout pass can fail
        // if it races with the render loop.
        let view = ARView(frame: UIScreen.main.bounds)
        // Disable auto-configuration. With it enabled, ARView calls session.run()
        // with a default config which races with our deferred runSession(),
        // producing [Request interrupted by user] / FigCaptureSourceRemote errors.
        view.automaticallyConfigureSession = false
        return view
    }()

    // MARK: - Internal State (never read by SwiftUI views)

    @ObservationIgnored private var hasStarted = false
    /// True after `setup()` completes — prevents `runSession()`/`resetSession()` from being
    /// called before the ARView is in the view hierarchy with a valid frame.
    @ObservationIgnored private(set) var isSetupComplete = false
    @ObservationIgnored private var lastCameraUpdateTime: TimeInterval = 0
    @ObservationIgnored private var stableFrameCount = 0
    private let stableFramesRequired = 20

    /// Most-recently-observed live transform per image name, with the wall-clock
    /// timestamp (CACurrentMediaTime) of the observation.
    ///
    /// Doubles as a per-image throttle (callbacks only re-fire when the existing
    /// timestamp is older than `imageCallbackThrottleInterval`) and as the input
    /// to multi-anchor blended correction (everything seen in the last
    /// `correctionBlendWindow` seconds participates in the blend with an
    /// exponentially-decayed weight).
    @ObservationIgnored var recentImageAnchors: [String: (transform: simd_float4x4, timestamp: TimeInterval)] = [:]
    /// How often (seconds) a tracked image anchor re-fires its callback via didUpdate.
    private let imageCallbackThrottleInterval: TimeInterval = 2.0
    /// Anchors observed within this window participate in blended correction.
    let correctionBlendWindow: TimeInterval = 5.0
    /// Time-decay constant (seconds) for weighting recent anchors. Smaller =
    /// snappier handoff between anchors, larger = smoother but laggier.
    let correctionBlendTau: TimeInterval = 2.0

    // MARK: - File URLs

    let docsDir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first!

    var zonesDir: URL { docsDir.appendingPathComponent("zones") }
    var manifestURL: URL { zonesDir.appendingPathComponent("manifest.json") }

    /// Zone-specific graph URL. Falls back to legacy flat path when no zone is active.
    var graphURL: URL {
        if let zoneID = activeZoneID {
            return zonesDir.appendingPathComponent(zoneID.uuidString).appendingPathComponent("graph.json")
        }
        return docsDir.appendingPathComponent("campusGraph.json")
    }

    /// Zone-specific world map URL. Falls back to legacy flat path when no zone is active.
    var worldMapURL: URL {
        if let zoneID = activeZoneID {
            return zonesDir.appendingPathComponent(zoneID.uuidString).appendingPathComponent("map.worldmap")
        }
        return docsDir.appendingPathComponent("campus.worldmap")
    }

    /// Ensure the directory for a zone exists.
    func ensureZoneDirectory(for zoneID: UUID) {
        let dir = zonesDir.appendingPathComponent(zoneID.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Setup

    func setup() {
        guard !hasStarted else { return }
        hasStarted = true

        WaypointMarkerComponent.registerComponent()
        PathSegmentTag.registerComponent()
        EdgeLineTag.registerComponent()

        isSetupComplete = true

        // Defer the first session start to the next run-loop cycle.
        // At makeUIView() time the ARView frame is still .zero — starting
        // an AR session on a zero-sized CAMetalLayer causes permanent
        // drawable allocation failures ([CAMetalLayer nextDrawable] nil).
        DispatchQueue.main.async { [weak self] in
            self?.runSession()
        }
    }

    func runSession() {
        // Don't start the session before the ARView is in the view hierarchy
        guard isSetupComplete else { return }

        // Remove ALL scene entities to free GPU memory (catches orphaned anchors
        // that removeAllMarkers/clearAll might miss)
        let allAnchors = Array(arView.scene.anchors)
        for anchor in allAnchors {
            arView.scene.removeAnchor(anchor)
        }

        // Reset state for new session run
        stableFrameCount = 0
        correctionTransform = matrix_identity_float4x4
        isReady = false
        isRelocalizing = false
        imageAnchorsDetected = 0
        recentImageAnchors = [:]
        status = "Initializing..."

        let url = worldMapURL

        Task.detached(priority: .userInitiated) { [weak self] in
            // Loading ARReferenceImages is a synchronous and heavy read
            let refImages = ARReferenceImage.referenceImages(
                inGroupNamed: "ARReferenceImages", bundle: nil
            )

            // Attempt to load saved world map for relocalization synchronously on background thread
            let worldMap = (try? Data(contentsOf: url)).flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: $0)
            }

            await MainActor.run {
                guard let self = self, self.isSetupComplete else { return }

                let config = ARWorldTrackingConfiguration()
                config.planeDetection = [.horizontal]
                config.environmentTexturing = .automatic

                if let refImages = refImages {
                    config.detectionImages = refImages
                }

                if let worldMap = worldMap {
                    config.initialWorldMap = worldMap
                    self.isRelocalizing = true
                    self.status = "Relocalizing — move around the mapped area..."
                } else {
                    self.status = "Scanning — point at the floor..."
                }

                self.arView.session.delegate = self
                self.arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            }
        }
    }

    // MARK: - World Map Save / Load

    func saveWorldMap(completion: ((Bool) -> Void)? = nil) {
        guard canSaveWorldMap else {
            status = "Need better mapping quality before saving"
            completion?(false)
            return
        }

        status = "Saving world map..."
        let url = worldMapURL
        
        arView.session.getCurrentWorldMap { [weak self] worldMap, error in
            guard let self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.status = "Save failed: \(error.localizedDescription)"
                    completion?(false)
                }
                return
            }
            
            guard let worldMap else {
                DispatchQueue.main.async {
                    self.status = "Save failed: unknown error"
                    completion?(false)
                }
                return
            }
            
            Task.detached(priority: .background) {
                do {
                    let data = try NSKeyedArchiver.archivedData(
                        withRootObject: worldMap,
                        requiringSecureCoding: true
                    )
                    try data.write(to: url, options: .atomic)
                    
                    await MainActor.run {
                        self.status = "World map saved"
                        completion?(true)
                    }
                } catch {
                    await MainActor.run {
                        self.status = "Save error: \(error.localizedDescription)"
                        completion?(false)
                    }
                }
            }
        }
    }

    func loadWorldMap() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    var hasSavedWorldMap: Bool {
        FileManager.default.fileExists(atPath: worldMapURL.path)
    }

    // MARK: - Marker Rendering

    func placeWaypointMarker(for waypoint: Waypoint) {
        let position = transform(waypoint.simdPosition)
        let anchor = AnchorEntity(world: position)

        let color: UIColor = switch waypoint.type {
        case .location: .systemBlue
        case .anchor: .systemOrange
        case .gateway: .systemPurple
        }

        let radius: Float = switch waypoint.type {
        case .location: Float(0.05)
        case .anchor: Float(0.03)
        case .gateway: Float(0.06)
        }

        let sphere = ModelEntity(
            mesh: .generateSphere(radius: radius),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        sphere.components.set(WaypointMarkerComponent(
            waypointID: waypoint.id,
            waypointType: waypoint.type
        ))

        anchor.addChild(sphere)

        // Billboard label for location and gateway waypoints
        if waypoint.isLocation || waypoint.isGateway {
            let textMesh = MeshResource.generateText(
                waypoint.label,
                extrusionDepth: 0.001,
                font: .systemFont(ofSize: 0.03, weight: .bold),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byClipping
            )
            let textEntity = ModelEntity(
                mesh: textMesh,
                materials: [UnlitMaterial(color: .white)]
            )
            let textBounds = textMesh.bounds
            textEntity.position = SIMD3(-textBounds.center.x, 0.08, 0)
            textEntity.components.set(BillboardComponent())
            anchor.addChild(textEntity)
        }

        arView.scene.addAnchor(anchor)
    }

    func removeAllMarkers() {
        let anchorsToRemove = arView.scene.anchors.filter { anchor in
            anchor.children.contains { $0.components.has(WaypointMarkerComponent.self) }
        }
        for anchor in anchorsToRemove {
            arView.scene.removeAnchor(anchor)
        }
    }

    // MARK: - Raycast

    /// Raycasts from a screen point against detected horizontal planes.
    func raycastOnFloor(from screenPoint: CGPoint) -> SIMD3<Float>? {
        guard let query = arView.makeRaycastQuery(
            from: screenPoint,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        ) else { return nil }

        let results = arView.session.raycast(query)
        guard let result = results.first else { return nil }

        return SIMD3<Float>(
            result.worldTransform.columns.3.x,
            result.worldTransform.columns.3.y,
            result.worldTransform.columns.3.z
        )
    }

    // MARK: - Existing Image Anchors

    /// Fires the image anchor callback for all currently tracked image anchors.
    /// Resets their throttle timers so they fire fresh.
    func fireCallbackForExistingImageAnchors() {
        guard let callback = onImageAnchorDetected else { return }
        for anchor in arView.session.currentFrame?.anchors ?? [] {
            if let imageAnchor = anchor as? ARImageAnchor, imageAnchor.isTracked {
                let imageName = imageAnchor.referenceImage.name ?? "unknown"
                let liveTransform = imageAnchor.transform
                recentImageAnchors[imageName] = (liveTransform, CACurrentMediaTime())
                DispatchQueue.main.async { callback(imageName, liveTransform) }
            }
        }
    }

    // MARK: - Image Anchor Throttle

    /// Resets throttle timers so the next didUpdate anchors fires callbacks immediately.
    /// Call this when you need the next tracked image anchor to trigger a callback ASAP.
    func resetImageCallbackThrottles() {
        recentImageAnchors.removeAll()
    }

    // MARK: - Coaching Overlay

    /// Dismisses the ARCoachingOverlayView if present on the arView.
    func dismissCoaching() {
        for subview in arView.subviews {
            if let coaching = subview as? ARCoachingOverlayView {
                coaching.setActive(false, animated: true)
            }
        }
    }

    // MARK: - Reset

    func resetSession() {
        guard isSetupComplete else { return }

        isRelocalizing = false
        stableFrameCount = 0
        imageAnchorsDetected = 0
        isReady = false
        correctionTransform = matrix_identity_float4x4
        recentImageAnchors = [:]

        // Remove ALL scene entities to free GPU memory
        let allAnchors = Array(arView.scene.anchors)
        for anchor in allAnchors {
            arView.scene.removeAnchor(anchor)
        }

        status = "Resetting session..."

        Task.detached(priority: .userInitiated) { [weak self] in
            let refImages = ARReferenceImage.referenceImages(
                inGroupNamed: "ARReferenceImages", bundle: nil
            )

            await MainActor.run {
                guard let self = self, self.isSetupComplete else { return }

                let config = ARWorldTrackingConfiguration()
                config.planeDetection = [.horizontal]
                config.environmentTexturing = .automatic
                if let refImages = refImages {
                    config.detectionImages = refImages
                }
                
                self.arView.session.run(config, options: [.removeExistingAnchors, .resetTracking])
                self.status = "Session reset — move slowly, point at the floor"
            }
        }
    }

    // MARK: - Refresh (unstick camera)

    /// Restarts the AR session to recover from a frozen camera feed.
    /// Never calls session.pause() — that tears down the camera capture
    /// pipeline and produces [Request interrupted by user] errors.
    /// session.run() seamlessly replaces the current configuration.
    func refreshSession() {
        runSession()
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ── CRITICAL: Extract ALL primitives from the ARFrame BEFORE any closure ──
        // ARFrame holds GPU-backed camera textures. If a closure captures `frame`,
        // ARC keeps it alive → frames pile up → GPU memory exhausted →
        // [CAMetalLayer nextDrawable] returning nil → permanent camera freeze.
        let mappingStatus = frame.worldMappingStatus
        let trackingState = frame.camera.trackingState
        let timestamp = frame.timestamp
        let camX = frame.camera.transform.columns.3.x
        let camY = frame.camera.transform.columns.3.y
        let camZ = frame.camera.transform.columns.3.z

        MainActor.assumeIsolated {
            let newQuality: MappingQuality = switch mappingStatus {
            case .notAvailable: .notAvailable
            case .limited: .limited
            case .extending: .extending
            case .mapped: .mapped
            @unknown default: .notAvailable
            }
            if newQuality != mappingQuality {
                mappingQuality = newQuality
            }

            if isRelocalizing {
                switch trackingState {
                case .normal:
                    stableFrameCount += 1
                    if stableFrameCount >= stableFramesRequired {
                        isRelocalizing = false
                        isReady = true
                        dismissCoaching()
                        status = "Relocalized — ready"
                        // ── DEFER callback to next run loop ──
                        // onRelocalized triggers restoreMarkers() which creates
                        // entities for ALL waypoints. Running this synchronously
                        // inside the delegate blocks the main thread for 50-200ms,
                        // preventing RealityKit from presenting drawables. Frames
                        // pile up → "retaining 11 ARFrames" → camera freeze.
                        // Deferring lets the render loop run between state update
                        // and heavy entity creation work.
                        if let callback = onRelocalized {
                            DispatchQueue.main.async { callback() }
                        }
                    } else {
                        status = "Stabilizing tracking..."
                    }
                case .limited(let reason):
                    stableFrameCount = 0
                    switch reason {
                    case .relocalizing:
                        status = "Relocalizing — look around slowly..."
                    case .insufficientFeatures:
                        status = "Need more features — point at textured surfaces"
                    case .excessiveMotion:
                        status = "Too fast — slow down"
                    case .initializing:
                        status = "Initializing..."
                    @unknown default:
                        status = "Limited tracking"
                    }
                case .notAvailable:
                    stableFrameCount = 0
                    status = "Tracking not available"
                }
            }

            if !isRelocalizing && !isReady {
                if trackingState == .normal {
                    isReady = true
                    dismissCoaching()
                    status = "Ready — floor detected"
                    if let callback = onPlaneDetected {
                        DispatchQueue.main.async { callback() }
                    }
                }
            }

            // Throttled camera position update (every 0.5s)
            if timestamp - lastCameraUpdateTime >= 0.5 {
                lastCameraUpdateTime = timestamp
                cameraPosition = SIMD3(camX, camY, camZ)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Extract lightweight data from anchors before entering the MainActor closure.
        // Same principle as didUpdate: never let closures retain heavy ARKit objects.
        var planeDetected = false
        var imageInfos: [(name: String, transform: simd_float4x4)] = []

        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor, planeAnchor.alignment == .horizontal {
                planeDetected = true
            }
            if let imageAnchor = anchor as? ARImageAnchor {
                let name = imageAnchor.referenceImage.name ?? "unknown"
                imageInfos.append((name, imageAnchor.transform))
            }
        }

        MainActor.assumeIsolated {
            if planeDetected && !isReady && !isRelocalizing {
                isReady = true
                status = "Floor detected — ready"
                if let callback = onPlaneDetected {
                    DispatchQueue.main.async { callback() }
                }
            }
            let now = CACurrentMediaTime()
            for info in imageInfos {
                imageAnchorsDetected += 1
                recentImageAnchors[info.name] = (info.transform, now)
                status = "Image anchor detected: \(info.name) (\(imageAnchorsDetected) total)"
                // Defer image anchor callbacks — they can trigger zone loading,
                // session restart, entity creation, and file I/O.
                let name = info.name
                let liveTransform = info.transform
                if let callback = onImageAnchorDetected {
                    DispatchQueue.main.async { callback(name, liveTransform) }
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Extract image anchor data for re-detected anchors.
        // didAdd fires only once per anchor; didUpdate fires when a previously
        // detected anchor is tracked again (e.g., user revisits it).
        var imageInfos: [(name: String, transform: simd_float4x4)] = []

        for anchor in anchors {
            if let imageAnchor = anchor as? ARImageAnchor, imageAnchor.isTracked {
                let name = imageAnchor.referenceImage.name ?? "unknown"
                imageInfos.append((name, imageAnchor.transform))
            }
        }

        guard !imageInfos.isEmpty else { return }

        MainActor.assumeIsolated {
            let now = CACurrentMediaTime()
            for info in imageInfos {
                let lastTime = recentImageAnchors[info.name]?.timestamp ?? 0
                // Always update the cached transform/timestamp — even when we
                // skip firing the callback — so the blender sees the freshest
                // pose for every visible anchor.
                recentImageAnchors[info.name] = (info.transform, now)
                guard now - lastTime >= imageCallbackThrottleInterval else { continue }
                status = "Image anchor tracked: \(info.name)"
                let name = info.name
                let liveTransform = info.transform
                if let callback = onImageAnchorDetected {
                    DispatchQueue.main.async { callback(name, liveTransform) }
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            status = "AR error: \(message)"
            if isRelocalizing { isRelocalizing = false }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            status = "Session interrupted"
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            status = "Session resumed"
        }
    }
}
