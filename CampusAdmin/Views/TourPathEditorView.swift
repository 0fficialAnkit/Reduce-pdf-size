//
//  TourPathEditorView.swift
//  CampusAdmin
//

import SwiftUI

struct TourPathEditorView: View {
    var adminManager: AdminARManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Tour Name") {
                    TextField("Tour name", text: tourNameBinding)
                }

                Section("Tour Stops (\(tourStops.count))") {
                    if tourStops.isEmpty {
                        Text("No stops added yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tourStops, id: \.self) { wpID in
                            if let wp = adminManager.graph.getWaypoint(byID: wpID) {
                                HStack {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(.secondary)
                                    Text(wp.label)
                                    Spacer()
                                    if let desc = wp.description {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onMove { from, to in
                            adminManager.moveTourStop(from: from, to: to)
                        }
                        .onDelete { indexSet in
                            adminManager.removeTourStops(at: indexSet)
                        }
                    }
                }

                Section("Available Locations") {
                    let available = availableLocations
                    if available.isEmpty {
                        Text("All locations added to tour")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(available) { wp in
                            Button {
                                adminManager.addTourStop(wp.id)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(wp.label)
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }

                if tourStops.count >= 2 {
                    Section("Preview") {
                        Button {
                            adminManager.previewTourPath()
                            dismiss()
                        } label: {
                            Label("Show Tour Path in AR", systemImage: "eye")
                        }

                        Button {
                            adminManager.clearTourPreview()
                        } label: {
                            Label("Clear Preview", systemImage: "eye.slash")
                        }
                    }
                }
            }
            .navigationTitle("Tour Path")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var tourStops: [UUID] {
        adminManager.graph.tourPath?.orderedWaypointIDs ?? []
    }

    private var availableLocations: [Waypoint] {
        let tourIDs = Set(tourStops)
        return adminManager.graph.locationWaypoints.filter { !tourIDs.contains($0.id) }
    }

    private var tourNameBinding: Binding<String> {
        Binding(
            get: { adminManager.graph.tourPath?.name ?? "" },
            set: { adminManager.updateTourName($0) }
        )
    }
}
