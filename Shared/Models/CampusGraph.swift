//
//  CampusGraph.swift
//  Shared
//

import Foundation
import simd

// MARK: - Image Anchor Record

struct ImageAnchorRecord: Codable, Hashable {
    let imageName: String
    let x: Double
    let y: Double
    let z: Double
    // Authored rotation as quaternion components. Optional so old graphs
    // (translation-only records) decode without rotation and fall back
    // to identity rotation, preserving prior behavior.
    let rx: Double?
    let ry: Double?
    let rz: Double?
    let rw: Double?

    init(imageName: String, x: Double, y: Double, z: Double) {
        self.imageName = imageName
        self.x = x
        self.y = y
        self.z = z
        self.rx = nil; self.ry = nil; self.rz = nil; self.rw = nil
    }

    init(imageName: String, position: SIMD3<Float>) {
        self.imageName = imageName
        self.x = Double(position.x)
        self.y = Double(position.y)
        self.z = Double(position.z)
        self.rx = nil; self.ry = nil; self.rz = nil; self.rw = nil
    }

    init(imageName: String, transform: simd_float4x4) {
        self.imageName = imageName
        self.x = Double(transform.columns.3.x)
        self.y = Double(transform.columns.3.y)
        self.z = Double(transform.columns.3.z)
        let q = simd_quaternion(transform)
        self.rx = Double(q.vector.x)
        self.ry = Double(q.vector.y)
        self.rz = Double(q.vector.z)
        self.rw = Double(q.vector.w)
    }

    var simdPosition: SIMD3<Float> {
        SIMD3(Float(x), Float(y), Float(z))
    }

    /// Authored quaternion. Identity if no rotation was recorded.
    var authoredRotation: simd_quatf {
        guard let rx, let ry, let rz, let rw else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_quatf(ix: Float(rx), iy: Float(ry), iz: Float(rz), r: Float(rw))
    }

    var hasAuthoredRotation: Bool {
        rx != nil && ry != nil && rz != nil && rw != nil
    }

    /// Authored 4×4 transform. Falls back to identity rotation when not recorded.
    var authoredTransform: simd_float4x4 {
        var t = simd_float4x4(authoredRotation)
        t.columns.3 = SIMD4(simdPosition, 1)
        return t
    }
}

// MARK: - Campus Graph

struct CampusGraph: Codable {
    var waypoints: [Waypoint]
    var edges: [Edge]
    var tourPath: TourPath?
    var imageAnchorRecords: [ImageAnchorRecord]

    init(
        waypoints: [Waypoint] = [],
        edges: [Edge] = [],
        tourPath: TourPath? = nil,
        imageAnchorRecords: [ImageAnchorRecord] = []
    ) {
        self.waypoints = waypoints
        self.edges = edges
        self.tourPath = tourPath
        self.imageAnchorRecords = imageAnchorRecords
    }

    // MARK: - Waypoint Lookups

    func getWaypoint(byID id: UUID) -> Waypoint? {
        waypoints.first { $0.id == id }
    }

    var locationWaypoints: [Waypoint] {
        waypoints.filter { $0.isLocation }
    }

    var anchorWaypoints: [Waypoint] {
        waypoints.filter { $0.isAnchor }
    }

    var gatewayWaypoints: [Waypoint] {
        waypoints.filter { $0.isGateway }
    }

    /// All waypoints that can be selected as navigation destinations (locations and gateways).
    var navigableWaypoints: [Waypoint] {
        waypoints.filter { $0.isLocation || $0.isGateway }
    }

    // MARK: - Edge Lookups

    func edges(for waypointID: UUID) -> [Edge] {
        edges.filter { $0.connects(waypointID) }
    }

    func neighbors(of waypointID: UUID) -> [(waypoint: Waypoint, edge: Edge)] {
        edges(for: waypointID).compactMap { edge in
            guard let otherID = edge.otherEnd(from: waypointID),
                  let other = getWaypoint(byID: otherID) else { return nil }
            return (other, edge)
        }
    }

    func hasEdge(between a: UUID, and b: UUID) -> Bool {
        edges.contains { ($0.fromID == a && $0.toID == b) || ($0.fromID == b && $0.toID == a) }
    }

    // MARK: - Image Anchor Lookups

    func imageAnchorRecord(named imageName: String) -> ImageAnchorRecord? {
        imageAnchorRecords.first { $0.imageName == imageName }
    }

    // MARK: - Mutations

    mutating func addWaypoint(_ waypoint: Waypoint) {
        waypoints.append(waypoint)
    }

    mutating func addEdge(from: UUID, to: UUID) {
        guard let wp1 = getWaypoint(byID: from),
              let wp2 = getWaypoint(byID: to),
              !hasEdge(between: from, and: to),
              from != to
        else { return }
        edges.append(Edge(from: wp1, to: wp2))
    }

    mutating func removeWaypoint(_ id: UUID) {
        waypoints.removeAll { $0.id == id }
        edges.removeAll { $0.connects(id) }
        tourPath?.orderedWaypointIDs.removeAll { $0 == id }
    }

    mutating func removeEdge(_ id: UUID) {
        edges.removeAll { $0.id == id }
    }

    mutating func addImageAnchorRecord(_ record: ImageAnchorRecord) {
        // Replace existing record for the same image name, or append
        if let idx = imageAnchorRecords.firstIndex(where: { $0.imageName == record.imageName }) {
            imageAnchorRecords[idx] = record
        } else {
            imageAnchorRecords.append(record)
        }
    }

    mutating func removeImageAnchorRecord(named imageName: String) {
        imageAnchorRecords.removeAll { $0.imageName == imageName }
    }

    mutating func updateWaypoint(_ updated: Waypoint) {
        guard let idx = waypoints.firstIndex(where: { $0.id == updated.id }) else { return }
        waypoints[idx] = updated
        // Recalculate weights for connected edges
        for i in edges.indices {
            if edges[i].fromID == updated.id, let other = getWaypoint(byID: edges[i].toID) {
                edges[i].weight = updated.distance(to: other)
            } else if edges[i].toID == updated.id, let other = getWaypoint(byID: edges[i].fromID) {
                edges[i].weight = other.distance(to: updated)
            }
        }
    }

    // MARK: - Merged Graph Builder

    /// Builds a single unified graph from multiple zone graphs and cross-zone edges.
    /// Used for cross-zone Dijkstra pathfinding.
    static func merged(
        zoneGraphs: [(zoneID: UUID, graph: CampusGraph)],
        crossZoneEdges: [CrossZoneEdge]
    ) -> CampusGraph {
        var allWaypoints: [Waypoint] = []
        var allEdges: [Edge] = []

        for (zoneID, graph) in zoneGraphs {
            // Stamp each waypoint with its owning zone ID.
            // Waypoints may have nil zoneID if created before the zones feature
            // or if the admin didn't have a zone selected. This ensures
            // splitPathByZone can correctly segment cross-zone paths.
            for var wp in graph.waypoints {
                if wp.zoneID == nil {
                    wp.zoneID = zoneID
                }
                allWaypoints.append(wp)
            }
            allEdges.append(contentsOf: graph.edges)
        }

        // Add cross-zone edges as regular edges in the merged graph
        for czEdge in crossZoneEdges {
            let edge = Edge(
                id: czEdge.id,
                fromID: czEdge.fromWaypointID,
                toID: czEdge.toWaypointID,
                weight: czEdge.weight
            )
            allEdges.append(edge)
        }

        return CampusGraph(waypoints: allWaypoints, edges: allEdges)
    }

    // MARK: - Serialization

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    var jsonData: Data? {
        try? Self.jsonEncoder.encode(self)
    }

    var jsonString: String {
        guard let data = jsonData,
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    static func from(jsonData: Data) -> CampusGraph? {
        try? jsonDecoder.decode(CampusGraph.self, from: jsonData)
    }

    static func from(bundleResource name: String) -> CampusGraph? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return from(jsonData: data)
    }
}
