//
//  WaypointMarkerComponent.swift
//  Shared
//

import RealityKit
import Foundation

/// Attached to the sphere entity of a placed waypoint marker.
struct WaypointMarkerComponent: Component {
    var waypointID: UUID
    var waypointType: WaypointType
}

/// Tags a path segment entity (yellow line between consecutive waypoints).
struct PathSegmentTag: Component {}

/// Tags an edge line entity (green line showing graph connectivity).
struct EdgeLineTag: Component {}
