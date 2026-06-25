//
//  Dijkstra.swift
//  Shared
//

import Foundation

enum Dijkstra {

    /// Returns the ordered list of waypoint IDs for the shortest path, or nil if unreachable.
    static func shortestPath(
        in graph: CampusGraph,
        from startID: UUID,
        to endID: UUID
    ) -> [UUID]? {
        guard graph.getWaypoint(byID: startID) != nil,
              graph.getWaypoint(byID: endID) != nil else { return nil }

        if startID == endID { return [startID] }

        // Distance from start to each node
        var dist: [UUID: Double] = [:]
        // Previous node in optimal path
        var prev: [UUID: UUID] = [:]
        // Unvisited set
        var unvisited: Set<UUID> = []

        for wp in graph.waypoints {
            dist[wp.id] = .infinity
            unvisited.insert(wp.id)
        }
        dist[startID] = 0

        while !unvisited.isEmpty {
            // Find unvisited node with smallest distance
            guard let current = unvisited.min(by: { dist[$0, default: .infinity] < dist[$1, default: .infinity] }) else { break }

            let currentDist = dist[current, default: .infinity]

            // If we reached the target, reconstruct path
            if current == endID {
                return reconstructPath(prev: prev, from: startID, to: endID)
            }

            // If remaining nodes are unreachable, stop
            if currentDist.isInfinite { break }

            unvisited.remove(current)

            // Relax neighbors
            for (neighbor, edge) in graph.neighbors(of: current) {
                guard unvisited.contains(neighbor.id) else { continue }
                let alt = currentDist + edge.weight
                if alt < dist[neighbor.id, default: .infinity] {
                    dist[neighbor.id] = alt
                    prev[neighbor.id] = current
                }
            }
        }

        return nil // No path found
    }

    /// Returns the total distance of a path through the given waypoint IDs.
    static func pathDistance(in graph: CampusGraph, path: [UUID]) -> Double {
        guard path.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 0..<(path.count - 1) {
            guard let a = graph.getWaypoint(byID: path[i]),
                  let b = graph.getWaypoint(byID: path[i + 1]) else { continue }
            total += a.distance(to: b)
        }
        return total
    }

    private static func reconstructPath(prev: [UUID: UUID], from start: UUID, to end: UUID) -> [UUID] {
        var path: [UUID] = [end]
        var current = end
        while current != start {
            guard let previous = prev[current] else { return [] }
            path.append(previous)
            current = previous
        }
        return path.reversed()
    }
}
