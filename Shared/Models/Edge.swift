//
//  Edge.swift
//  Shared
//

import Foundation

struct Edge: Identifiable, Codable, Hashable {
    let id: UUID
    let fromID: UUID
    let toID: UUID
    var weight: Double

    init(id: UUID = UUID(), from: Waypoint, to: Waypoint) {
        self.id = id
        self.fromID = from.id
        self.toID = to.id
        self.weight = from.distance(to: to)
    }

    init(id: UUID = UUID(), fromID: UUID, toID: UUID, weight: Double) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.weight = weight
    }

    /// Returns true if this edge connects the given waypoint
    func connects(_ waypointID: UUID) -> Bool {
        fromID == waypointID || toID == waypointID
    }

    /// Returns the other end of this edge given one end
    func otherEnd(from waypointID: UUID) -> UUID? {
        if fromID == waypointID { return toID }
        if toID == waypointID { return fromID }
        return nil
    }
}
