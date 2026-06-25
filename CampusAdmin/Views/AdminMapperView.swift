//
//  AdminMapperView.swift
//  CampusAdmin
//

import SwiftUI

struct AdminMapperView: View {
    @State private var adminManager = AdminARManager()
    @State private var showGraphSheet = false
    @State private var showJSONSheet = false
    @State private var showTourSheet = false
    @State private var showExportSheet = false
    @State private var showClearConfirm = false
    @State private var showZoneSheet = false
    @State private var showNewZoneAlert = false
    @State private var newZoneName = ""
    @State private var showLinkZonesSheet = false

    var body: some View {
        ZStack {
            ARContainerView(sessionManager: adminManager.session)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statusBar
                Spacer()
                controlPanel
            }
        }
        .sheet(isPresented: $showGraphSheet) {
            graphSheet
        }
        .sheet(isPresented: $showJSONSheet) {
            jsonSheet
        }
        .sheet(isPresented: $showTourSheet) {
            TourPathEditorView(adminManager: adminManager)
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet
        }
        .sheet(isPresented: $showZoneSheet) {
            zoneSheet
        }
        .sheet(isPresented: $showLinkZonesSheet) {
            LinkZonesView(adminManager: adminManager)
        }
        .alert("New Zone", isPresented: $showNewZoneAlert) {
            TextField("Zone name", text: $newZoneName)
            Button("Create") {
                let name = newZoneName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                adminManager.createZone(name: name)
                newZoneName = ""
            }
            Button("Cancel", role: .cancel) { newZoneName = "" }
        } message: {
            Text("Enter a name for the new zone.")
        }
        .alert("Clear All Data?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) { adminManager.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all zones, waypoints, edges, and saved world maps.")
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        VStack(spacing: 4) {
            // Zone bar
            HStack {
                Image(systemName: "map")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                if let zone = adminManager.currentZone {
                    Text(zone.name)
                        .font(.caption)
                        .bold()
                    Text("(\(zone.referenceImageNames.count) images)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No zone selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showZoneSheet = true
                } label: {
                    Label("Zones", systemImage: "rectangle.stack")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            HStack {
                Text(adminManager.session.status)
                    .font(.caption)
                    .lineLimit(1)

                Spacer()

                // Graph connectivity indicator
                if adminManager.waypointCount > 1 {
                    Image(systemName: adminManager.isGraphConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(adminManager.isGraphConnected ? .green : .orange)
                        .font(.caption)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(qualityColor)
                        .frame(width: 8, height: 8)
                    Text(adminManager.session.mappingQuality.rawValue)
                        .font(.caption2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var qualityColor: Color {
        switch adminManager.session.mappingQuality {
        case .notAvailable: .red
        case .limited: .orange
        case .extending: .yellow
        case .mapped: .green
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 12) {
            // Mode picker
            Picker("Mode", selection: $adminManager.mode) {
                ForEach(AdminMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .onChange(of: adminManager.mode) {
                if adminManager.edgeStartID != nil {
                    adminManager.cancelEdgeSelection()
                }
            }

            // Mode-specific controls
            if adminManager.mode == .place {
                placeModeControls
            } else {
                connectModeControls
            }

            // Action buttons — row 1
            HStack(spacing: 12) {
                Button {
                    adminManager.saveWorldMap()
                } label: {
                    Label("Save Map", systemImage: "square.and.arrow.down")
                }
                .disabled(!adminManager.session.canSaveWorldMap || adminManager.currentZone == nil)

                Button {
                    showGraphSheet = true
                } label: {
                    Label("\(adminManager.waypointCount)W / \(adminManager.edgeCount)E", systemImage: "point.3.connected.trianglepath.dotted")
                }

                if adminManager.isRecordingImage {
                    Button(role: .destructive) {
                        adminManager.cancelRecordingImage()
                    } label: {
                        Label("Cancel Rec", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        adminManager.startRecordingImage()
                    } label: {
                        Label("Rec Image", systemImage: "camera.viewfinder")
                    }
                    .disabled(adminManager.currentZone == nil)
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)

            // Action buttons — row 2
            HStack(spacing: 12) {
//                Button {
//                    adminManager.refreshSession()
//                } label: {
//                    Label("Refresh", systemImage: "arrow.clockwise")
//                }

                Button {
                    showTourSheet = true
                } label: {
                    Label("Tour (\(adminManager.tourStopCount))", systemImage: "figure.walk")
                }

                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button {
                    showJSONSheet = true
                } label: {
                    Label("JSON", systemImage: "doc.text")
                }

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Place Mode Controls

    private var placeModeControls: some View {
        HStack {
            Picker("Type", selection: $adminManager.selectedType) {
                Text("Location").tag(WaypointType.location)
                Text("Anchor").tag(WaypointType.anchor)
                Text("Gateway").tag(WaypointType.gateway)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            if adminManager.selectedType == .location || adminManager.selectedType == .gateway {
                TextField("Label", text: $adminManager.nextLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
            }

            Spacer()

            Button {
                adminManager.undoLastWaypoint()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(adminManager.graph.waypoints.isEmpty)
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Connect Mode Controls

    private var connectModeControls: some View {
        HStack {
            if let startID = adminManager.edgeStartID,
               let wp = adminManager.graph.getWaypoint(byID: startID) {
                Label("From: \(wp.label)", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.green)

                Spacer()

                Button("Cancel") {
                    adminManager.cancelEdgeSelection()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            } else {
                Text("Tap near a waypoint to start an edge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Graph Sheet

    @State private var graphTab = 0

    private var graphSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $graphTab) {
                    Text("Waypoints (\(adminManager.waypointCount))").tag(0)
                    Text("Edges (\(adminManager.edgeCount))").tag(1)
                    Text("Validation").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                switch graphTab {
                case 0: waypointsList
                case 1: edgesList
                default: validationView
                }
            }
            .navigationTitle("Graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showGraphSheet = false }
                }
            }
        }
    }

    // MARK: - Waypoints List

    private var waypointsList: some View {
        List {
            ForEach(adminManager.graph.waypoints) { wp in
                HStack {
                    Image(systemName: wp.isLocation ? "mappin.circle.fill" : "smallcircle.filled.circle")
                        .foregroundStyle(wp.isLocation ? .blue : .orange)

                    VStack(alignment: .leading) {
                        Text(wp.label)
                            .font(.body)
                        Text(String(format: "(%.2f, %.2f, %.2f)", wp.x, wp.y, wp.z))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Edge count for this waypoint
                    let edgeCount = adminManager.graph.edges(for: wp.id).count
                    Text("\(edgeCount) edges")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(wp.type.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(wp.isLocation ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    adminManager.removeWaypoint(adminManager.graph.waypoints[index].id)
                }
            }
        }
    }

    // MARK: - Edges List

    private var edgesList: some View {
        List {
            ForEach(adminManager.graph.edges) { edge in
                let fromLabel = adminManager.graph.getWaypoint(byID: edge.fromID)?.label ?? "?"
                let toLabel = adminManager.graph.getWaypoint(byID: edge.toID)?.label ?? "?"

                HStack {
                    Image(systemName: "line.diagonal")
                        .foregroundStyle(.green)

                    Text("\(fromLabel) → \(toLabel)")
                        .font(.body)

                    Spacer()

                    Text(String(format: "%.2fm", edge.weight))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    adminManager.removeEdge(adminManager.graph.edges[index].id)
                }
            }
        }
    }

    // MARK: - Validation View

    private var validationView: some View {
        List {
            Section("Connectivity") {
                HStack {
                    Text("Fully connected")
                    Spacer()
                    Image(systemName: adminManager.isGraphConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(adminManager.isGraphConnected ? .green : .red)
                }

                HStack {
                    Text("Connected components")
                    Spacer()
                    Text("\(adminManager.componentCount)")
                        .foregroundStyle(adminManager.componentCount <= 1 ? Color.primary : Color.orange)
                }
            }

            Section("Waypoints") {
                HStack {
                    Text("Total")
                    Spacer()
                    Text("\(adminManager.waypointCount)")
                }
                HStack {
                    Text("Locations")
                    Spacer()
                    Text("\(adminManager.graph.locationWaypoints.count)")
                }
                HStack {
                    Text("Anchors")
                    Spacer()
                    Text("\(adminManager.graph.anchorWaypoints.count)")
                }
                HStack {
                    Text("Orphaned (no edges)")
                    Spacer()
                    Text("\(adminManager.orphanCount)")
                        .foregroundStyle(adminManager.orphanCount == 0 ? Color.primary : Color.orange)
                }
            }

            Section("Edges") {
                HStack {
                    Text("Total")
                    Spacer()
                    Text("\(adminManager.edgeCount)")
                }
            }
        }
    }

    // MARK: - Export Sheet

    private var exportSheet: some View {
        NavigationStack {
            List {
                Section("Zone Bundle") {
                    if let url = adminManager.exportZoneBundle() {
                        ShareLink(item: url) {
                            Label("Share All Zones", systemImage: "folder")
                        }
                    }
                    HStack {
                        Text("Zones")
                        Spacer()
                        Text("\(adminManager.zoneManifest.zones.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Current Zone: \(adminManager.currentZone?.name ?? "None")") {
                    if let url = adminManager.exportGraphFile() {
                        ShareLink(item: url) {
                            Label("Share graph.json", systemImage: "doc")
                        }
                    }
                    HStack {
                        Text("Waypoints")
                        Spacer()
                        Text("\(adminManager.waypointCount)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Edges")
                        Spacer()
                        Text("\(adminManager.edgeCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("World Map") {
                    if let url = adminManager.exportWorldMapFile() {
                        ShareLink(item: url) {
                            Label("Share map.worldmap", systemImage: "globe")
                        }
                    } else {
                        Label("No world map saved yet", systemImage: "globe")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Share the zone bundle folder to the User app. It contains all zones with their graphs, world maps, and the manifest.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showExportSheet = false }
                }
            }
        }
    }

    // MARK: - JSON Sheet

    private var jsonSheet: some View {
        NavigationStack {
            ScrollView {
                Text(adminManager.graph.jsonString)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Graph JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: adminManager.graph.jsonString)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showJSONSheet = false }
                }
            }
        }
    }

    // MARK: - Zone Sheet

    @State private var zoneToDelete: Zone?
    @State private var showDeleteZoneConfirm = false

    private var zoneSheet: some View {
        NavigationStack {
            List {
                Section("Zones (\(adminManager.zoneManifest.zones.count))") {
                    ForEach(adminManager.zoneManifest.zones) { zone in
                        Button {
                            adminManager.switchZone(zone)
                            showZoneSheet = false
                        } label: {
                            HStack {
                                Image(systemName: zone.id == adminManager.currentZone?.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(zone.id == adminManager.currentZone?.id ? .blue : .secondary)

                                VStack(alignment: .leading) {
                                    Text(zone.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text("\(zone.referenceImageNames.count) reference images")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if !zone.referenceImageNames.isEmpty {
                                        Text(zone.referenceImageNames.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                if zone.id == adminManager.currentZone?.id {
                                    Text("Active")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                zoneToDelete = zone
                                showDeleteZoneConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }

                    if adminManager.zoneManifest.zones.isEmpty {
                        Text("No zones yet — create one to start mapping.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Cross-Zone Links (\(adminManager.zoneManifest.crossZoneEdges.count))") {
                    Button {
                        showZoneSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showLinkZonesSheet = true
                        }
                    } label: {
                        Label("Link Zones", systemImage: "arrow.triangle.swap")
                    }
                    .disabled(adminManager.zoneManifest.zones.count < 2)
                }

                Section {
                    Button {
                        showZoneSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showNewZoneAlert = true
                        }
                    } label: {
                        Label("New Zone", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Zones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showZoneSheet = false }
                }
            }
            .alert("Delete Zone?", isPresented: $showDeleteZoneConfirm) {
                Button("Delete", role: .destructive) {
                    if let zone = zoneToDelete {
                        adminManager.deleteZone(zone.id)
                    }
                    zoneToDelete = nil
                }
                Button("Cancel", role: .cancel) { zoneToDelete = nil }
            } message: {
                Text("This will delete all data for \"\(zoneToDelete?.name ?? "")\" including its world map and graph.")
            }
        }
    }
}
