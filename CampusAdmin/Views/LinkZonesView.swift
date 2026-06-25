//
//  LinkZonesView.swift
//  CampusAdmin
//

import SwiftUI

struct LinkZonesView: View {
    var adminManager: AdminARManager
    @Environment(\.dismiss) private var dismiss

    // Selection state for creating a new cross-zone edge
    @State private var fromZone: Zone?
    @State private var fromWaypoint: Waypoint?
    @State private var toZone: Zone?
    @State private var toWaypoint: Waypoint?
    @State private var distanceText: String = ""
    @State private var displayNameText: String = ""

    var body: some View {
        NavigationStack {
            List {
                existingEdgesSection
                newEdgeSection
            }
            .navigationTitle("Link Zones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Existing Cross-Zone Edges

    private var existingEdgesSection: some View {
        Section("Existing Links (\(adminManager.zoneManifest.crossZoneEdges.count))") {
            if adminManager.zoneManifest.crossZoneEdges.isEmpty {
                Text("No cross-zone links yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(adminManager.zoneManifest.crossZoneEdges) { edge in
                    crossZoneEdgeRow(edge)
                }
                .onDelete { indexSet in
                    let edges = adminManager.zoneManifest.crossZoneEdges
                    for index in indexSet {
                        adminManager.removeCrossZoneEdge(edges[index].id)
                    }
                }
            }
        }
    }

    private func crossZoneEdgeRow(_ edge: CrossZoneEdge) -> some View {
        let fromZoneName = adminManager.zoneManifest.zone(byID: edge.fromZoneID)?.name ?? "?"
        let toZoneName = adminManager.zoneManifest.zone(byID: edge.toZoneID)?.name ?? "?"
        let fromWPLabel = waypointLabel(id: edge.fromWaypointID, zoneID: edge.fromZoneID)
        let toWPLabel = waypointLabel(id: edge.toWaypointID, zoneID: edge.toZoneID)

        return VStack(alignment: .leading, spacing: 4) {
            if let displayName = edge.displayName {
                Text(displayName)
                    .font(.subheadline)
                    .bold()
            }
            HStack {
                Text(fromZoneName)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.blue)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                Text(toZoneName)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.blue)
                Spacer()
                Text(String(format: "%.1fm", edge.weight))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(fromWPLabel) → \(toWPLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func waypointLabel(id: UUID, zoneID: UUID) -> String {
        if let graph = adminManager.loadGraphForZone(zoneID) {
            return graph.getWaypoint(byID: id)?.label ?? "Unknown"
        }
        if zoneID == adminManager.currentZone?.id {
            return adminManager.graph.getWaypoint(byID: id)?.label ?? "Unknown"
        }
        return "Unknown"
    }

    // MARK: - New Edge Creation

    private var newEdgeSection: some View {
        Section("Create New Link") {
            // From zone + waypoint
            zonePicker(label: "From Zone", selection: $fromZone, excluding: toZone?.id)

            if let fz = fromZone {
                waypointPicker(label: "From Waypoint", zoneID: fz.id, selection: $fromWaypoint)
            }

            // To zone + waypoint
            zonePicker(label: "To Zone", selection: $toZone, excluding: fromZone?.id)

            if let tz = toZone {
                waypointPicker(label: "To Waypoint", zoneID: tz.id, selection: $toWaypoint)
            }

            // Distance — auto-calculated via shared image anchor, manual fallback
            if let computed = computedWeight {
                HStack {
                    Text("Distance")
                    Spacer()
                    Text(String(format: "%.2f m (auto)", computed))
                        .foregroundStyle(.secondary)
                }
            } else if fromWaypoint != nil && toWaypoint != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No shared image anchor — enter distance manually")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    HStack {
                        Text("Distance (m)")
                        Spacer()
                        TextField("e.g. 15.0", text: $distanceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                }
            }

            // Display name for destination list
            if fromWaypoint != nil && toWaypoint != nil {
                HStack {
                    Text("Display Name")
                    Spacer()
                    TextField("e.g. Stairs (3rd↔4th)", text: $displayNameText)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 200)
                }
            }

            // Create button
            Button {
                createEdge()
            } label: {
                Label("Create Link", systemImage: "link.badge.plus")
            }
            .disabled(!canCreateEdge)
        }
    }

    private var computedWeight: Double? {
        guard let fz = fromZone, let fw = fromWaypoint,
              let tz = toZone, let tw = toWaypoint,
              fz.id != tz.id else { return nil }
        return adminManager.calculateCrossZoneWeight(
            fromWaypointID: fw.id, fromZoneID: fz.id,
            toWaypointID: tw.id, toZoneID: tz.id
        )
    }

    private var canCreateEdge: Bool {
        guard fromZone != nil && fromWaypoint != nil && toZone != nil && toWaypoint != nil
                && fromZone?.id != toZone?.id else { return false }
        return computedWeight != nil || (Double(distanceText) ?? 0) > 0
    }

    private func createEdge() {
        guard let fz = fromZone, let fw = fromWaypoint,
              let tz = toZone, let tw = toWaypoint else { return }

        let weight = computedWeight ?? Double(distanceText) ?? 0
        guard weight > 0 else { return }

        adminManager.createCrossZoneEdge(
            fromWaypointID: fw.id,
            fromZoneID: fz.id,
            toWaypointID: tw.id,
            toZoneID: tz.id,
            weight: weight,
            displayName: displayNameText.isEmpty ? nil : displayNameText
        )

        // Reset selection
        fromWaypoint = nil
        toWaypoint = nil
        distanceText = ""
        displayNameText = ""
    }

    // MARK: - Pickers

    private func zonePicker(label: String, selection: Binding<Zone?>, excluding: UUID?) -> some View {
        Picker(label, selection: selection) {
            Text("Select...").tag(nil as Zone?)
            ForEach(adminManager.zoneManifest.zones.filter { $0.id != excluding }) { zone in
                Text(zone.name).tag(zone as Zone?)
            }
        }
    }

    private func waypointPicker(label: String, zoneID: UUID, selection: Binding<Waypoint?>) -> some View {
        let waypoints = linkableWaypoints(for: zoneID)
        return Picker(label, selection: selection) {
            Text("Select...").tag(nil as Waypoint?)
            ForEach(waypoints) { wp in
                HStack {
                    Text(wp.label)
                    if wp.isGateway {
                        Text("(gateway)")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                }
                .tag(wp as Waypoint?)
            }
        }
    }

    /// Returns gateway waypoints for linking zones. Falls back to location waypoints
    /// if no gateways exist (backward compatibility).
    private func linkableWaypoints(for zoneID: UUID) -> [Waypoint] {
        let graph: CampusGraph
        if zoneID == adminManager.currentZone?.id {
            graph = adminManager.graph
        } else {
            graph = adminManager.loadGraphForZone(zoneID) ?? CampusGraph()
        }
        let gateways = graph.gatewayWaypoints
        return gateways.isEmpty ? graph.locationWaypoints : gateways
    }
}
