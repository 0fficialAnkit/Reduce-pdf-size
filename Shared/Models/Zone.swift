//
//  Zone.swift
//  Shared
//

import Foundation

struct Zone: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var referenceImageNames: [String]

    init(id: UUID = UUID(), name: String, referenceImageNames: [String] = []) {
        self.id = id
        self.name = name
        self.referenceImageNames = referenceImageNames
    }
}

struct CrossZoneEdge: Identifiable, Codable, Hashable {
    let id: UUID
    let fromWaypointID: UUID
    let fromZoneID: UUID
    let toWaypointID: UUID
    let toZoneID: UUID
    var weight: Double
    /// User-facing name for this gateway pair (e.g., "Stairs (4th↔5th floor)").
    /// Shown in the destination list instead of individual gateway labels.
    var displayName: String?

    init(
        id: UUID = UUID(),
        fromWaypointID: UUID,
        fromZoneID: UUID,
        toWaypointID: UUID,
        toZoneID: UUID,
        weight: Double,
        displayName: String? = nil
    ) {
        self.id = id
        self.fromWaypointID = fromWaypointID
        self.fromZoneID = fromZoneID
        self.toWaypointID = toWaypointID
        self.toZoneID = toZoneID
        self.weight = weight
        self.displayName = displayName
    }
}

struct ZoneManifest: Codable {
    var zones: [Zone]
    var crossZoneEdges: [CrossZoneEdge]

    init(zones: [Zone] = [], crossZoneEdges: [CrossZoneEdge] = []) {
        self.zones = zones
        self.crossZoneEdges = crossZoneEdges
    }

    // MARK: - Lookups

    func zone(byID id: UUID) -> Zone? {
        zones.first { $0.id == id }
    }

    /// Finds the zone that owns a given reference image name.
    func zone(forImageNamed imageName: String) -> Zone? {
        zones.first { $0.referenceImageNames.contains(imageName) }
    }

    // MARK: - Mutations

    mutating func addZone(_ zone: Zone) {
        zones.append(zone)
    }

    mutating func removeZone(_ id: UUID) {
        zones.removeAll { $0.id == id }
        crossZoneEdges.removeAll { $0.fromZoneID == id || $0.toZoneID == id }
    }

    mutating func updateZone(_ updated: Zone) {
        guard let idx = zones.firstIndex(where: { $0.id == updated.id }) else { return }
        zones[idx] = updated
    }

    mutating func addImageName(_ imageName: String, toZone zoneID: UUID) {
        guard let idx = zones.firstIndex(where: { $0.id == zoneID }) else { return }
        if !zones[idx].referenceImageNames.contains(imageName) {
            zones[idx].referenceImageNames.append(imageName)
        }
    }

    // MARK: - Cross-Zone Edge Mutations

    mutating func addCrossZoneEdge(_ edge: CrossZoneEdge) {
        crossZoneEdges.append(edge)
    }

    mutating func removeCrossZoneEdge(_ id: UUID) {
        crossZoneEdges.removeAll { $0.id == id }
    }

    /// Returns cross-zone edges involving a given zone.
    func crossZoneEdges(for zoneID: UUID) -> [CrossZoneEdge] {
        crossZoneEdges.filter { $0.fromZoneID == zoneID || $0.toZoneID == zoneID }
    }

    // MARK: - Serialization

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let jsonDecoder = JSONDecoder()

    var jsonData: Data? {
        try? Self.jsonEncoder.encode(self)
    }

    static func from(jsonData: Data) -> ZoneManifest? {
        try? jsonDecoder.decode(ZoneManifest.self, from: jsonData)
    }
}
