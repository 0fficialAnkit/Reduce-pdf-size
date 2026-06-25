//
//  Waypoint.swift
//  Shared
//

import Foundation

enum WaypointType: String, Codable, CaseIterable {
    case location
    case anchor
    case gateway
}

struct Waypoint: Identifiable, Codable, Hashable {
    let id: UUID
    var type: WaypointType
    var label: String
    var description: String?
    var x: Double
    var y: Double
    var z: Double
    var zoneID: UUID?

    init(
        id: UUID = UUID(),
        type: WaypointType = .anchor,
        label: String,
        description: String? = nil,
        x: Double,
        y: Double,
        z: Double,
        zoneID: UUID? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.description = description
        self.x = x
        self.y = y
        self.z = z
        self.zoneID = zoneID
    }

    init(
        id: UUID = UUID(),
        type: WaypointType = .anchor,
        label: String,
        description: String? = nil,
        position: SIMD3<Float>,
        zoneID: UUID? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.description = description
        self.x = Double(position.x)
        self.y = Double(position.y)
        self.z = Double(position.z)
        self.zoneID = zoneID
    }

    var simdPosition: SIMD3<Float> {
        SIMD3(Float(x), Float(y), Float(z))
    }

    func distance(to other: Waypoint) -> Double {
        sqrt(pow(x - other.x, 2) + pow(y - other.y, 2) + pow(z - other.z, 2))
    }

    var isLocation: Bool { type == .location }
    var isAnchor: Bool { type == .anchor }
    var isGateway: Bool { type == .gateway }
}
