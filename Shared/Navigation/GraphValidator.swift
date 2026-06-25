//
//  GraphValidator.swift
//  Shared
//

import Foundation

enum GraphValidator {

    /// Returns true if every waypoint is reachable from every other waypoint via edges.
    static func isFullyConnected(_ graph: CampusGraph) -> Bool {
        guard let first = graph.waypoints.first else { return true }
        let reachable = reachableIDs(from: first.id, in: graph)
        return reachable.count == graph.waypoints.count
    }

    /// Returns waypoints that have zero edges (completely disconnected).
    static func orphanedWaypoints(in graph: CampusGraph) -> [Waypoint] {
        graph.waypoints.filter { wp in
            !graph.edges.contains { $0.connects(wp.id) }
        }
    }

    /// Returns pairs of edges that connect the same two waypoints.
    static func duplicateEdges(in graph: CampusGraph) -> [(Edge, Edge)] {
        var result: [(Edge, Edge)] = []
        for i in 0..<graph.edges.count {
            for j in (i + 1)..<graph.edges.count {
                let a = graph.edges[i]
                let b = graph.edges[j]
                if (a.fromID == b.fromID && a.toID == b.toID) ||
                   (a.fromID == b.toID && a.toID == b.fromID) {
                    result.append((a, b))
                }
            }
        }
        return result
    }

    /// Returns all waypoint IDs reachable from the given start via BFS.
    static func reachableIDs(from startID: UUID, in graph: CampusGraph) -> Set<UUID> {
        var visited: Set<UUID> = [startID]
        var queue: [UUID] = [startID]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            for (neighbor, _) in graph.neighbors(of: current) {
                guard !visited.contains(neighbor.id) else { continue }
                visited.insert(neighbor.id)
                queue.append(neighbor.id)
            }
        }

        return visited
    }

    /// Returns connected components as arrays of waypoint IDs.
    static func connectedComponents(in graph: CampusGraph) -> [[UUID]] {
        var unvisited = Set(graph.waypoints.map(\.id))
        var components: [[UUID]] = []

        while let start = unvisited.first {
            let reachable = reachableIDs(from: start, in: graph)
            components.append(Array(reachable))
            unvisited.subtract(reachable)
        }

        return components
    }
}
