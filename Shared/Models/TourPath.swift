//
//  TourPath.swift
//  Shared
//

import Foundation

struct TourPath: Codable, Hashable {
    var name: String
    var orderedWaypointIDs: [UUID]
}
