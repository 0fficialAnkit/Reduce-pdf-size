//
//  UserNavigationView.swift
//  CampusUser
//

import SwiftUI
import UniformTypeIdentifiers
import simd

struct UserNavigationView: View {
    @State private var userManager = UserARManager()
    @State private var showLocationList = false
    @State private var showImportSheet = false
    @State private var showZoneList = false
    @State private var showFileImporter = false
    @State private var pendingImport = false

    var body: some View {
        ZStack {
            if userManager.hasZoneData {
                ARContainerView(sessionManager: userManager.session)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    statusBar

                    // Arrived banner
                    if let message = userManager.arrivedMessage {
                        arrivedBanner(message)
                    }

                    // Zone transition banner
                    if case .transitioning(let zoneName) = userManager.zoneTransitionState {
                        transitionBanner(zoneName: zoneName)
                    }

                    // Navigation banner
                    if userManager.isActive, let dest = userManager.destinationWaypoint {
                        navigationBanner(destination: dest)
                    }

                    // Scan prompt (zone data loaded but no zone active yet)
                    if userManager.activeZone == nil && !userManager.isTransitioning {
                        scanPromptBanner
                    }

                    Spacer()

                    bottomBar
                }
            } else {
                noDataView
            }
        }
        .sheet(isPresented: $showLocationList) {
            locationListSheet
        }
        .sheet(isPresented: $showImportSheet) {
            importSheet
        }
        .sheet(isPresented: $showZoneList) {
            zoneListSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.folder],
            onCompletion: { result in
                if case .success(let url) = result {
                    userManager.importZoneBundle(from: url)
                }
            }
        )
        .onChange(of: showImportSheet) { _, isShowing in
            if !isShowing && pendingImport {
                pendingImport = false
                showFileImporter = true
            }
        }
        .onChange(of: userManager.session.cameraPosition) {
            userManager.updateNearestLocation()
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        VStack(spacing: 4) {
            // Zone indicator
            if let zone = userManager.activeZone {
                HStack {
                    Image(systemName: "map.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(zone.name)
                        .font(.caption)
                        .bold()
                    Spacer()

                    if userManager.session.isRelocalizing {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(qualityColor)
                            .frame(width: 8, height: 8)
                        Text(userManager.session.mappingQuality.rawValue)
                            .font(.caption2)
                    }
                }
            }

            HStack {
                Text(userManager.session.status)
                    .font(.caption)
                    .lineLimit(1)

                Spacer()

                if userManager.activeZone == nil && userManager.session.isRelocalizing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            // Nearest location indicator (when not navigating)
            if !userManager.isActive, let nearest = userManager.nearestLocation {
                HStack {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Near: \(nearest.label)")
                        .font(.caption)
                        .bold()
                    Spacer()
                    Text(String(format: "%.1fm", userManager.nearestDistance))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var qualityColor: Color {
        switch userManager.session.mappingQuality {
        case .notAvailable: .red
        case .limited: .orange
        case .extending: .yellow
        case .mapped: .green
        }
    }

    // MARK: - Scan Prompt Banner

    private var scanPromptBanner: some View {
        HStack {
            Image(systemName: "camera.viewfinder")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan a campus marker to begin")
                    .font(.caption)
                    .bold()
                Text("Or choose a zone manually below")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
        .background(.ultraThinMaterial)
    }

    // MARK: - Zone Transition Banner

    private func transitionBanner(zoneName: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Entering \(zoneName)")
                    .font(.caption)
                    .bold()
                Text("Look around slowly to relocalize...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.15))
        .background(.ultraThinMaterial)
    }

    // MARK: - Navigation Banner

    private func navigationBanner(destination: Waypoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if userManager.isTouring {
                    Text("Tour: \(userManager.tourName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Stop \(userManager.currentTourStopIndex + 1)/\(userManager.tourStops.count): \(destination.label)")
                        .font(.caption)
                        .bold()
                } else {
                    Text("Navigating to")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(destination.label)
                        .font(.caption)
                        .bold()
                }

                if let desc = destination.description {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Cross-zone next zone indicator
                if let nextZone = userManager.nextZoneName {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle")
                            .font(.caption2)
                        Text("Next zone: \(nextZone) — scan marker at boundary")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }
            }

            Spacer()

            // Distance to destination
            if userManager.distanceToDestination < .infinity {
                Text(String(format: "%.1fm", userManager.distanceToDestination))
                    .font(.title3)
                    .bold()
                    .foregroundStyle(.blue)
            }

            Button {
                if userManager.isTouring {
                    userManager.cancelTour()
                } else {
                    userManager.cancelNavigation()
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Arrived Banner

    private func arrivedBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.caption)
                .bold()
            Spacer()
            Button {
                userManager.arrivedMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.15))
        .background(.ultraThinMaterial)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if userManager.isRelocalized {
                Button {
                    showLocationList = true
                } label: {
                    Label("Navigate", systemImage: "location.fill")
                }

                if userManager.hasTour {
                    Button {
                        userManager.startTour()
                    } label: {
                        Label("Tour", systemImage: "figure.walk")
                    }
                    .disabled(userManager.isActive)
                }
            }

            if userManager.hasZoneData {
                Button {
                    showZoneList = true
                } label: {
                    Label("Zones", systemImage: "rectangle.stack")
                }
            }

            Button {
                userManager.refreshSession()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Spacer()

            Button {
                showImportSheet = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
        .buttonStyle(.bordered)
        .font(.caption)
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - No Data View

    private var noDataView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("Import Campus Data")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Import a zone bundle exported from the Admin app to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button {
                    pendingImport = true
                    showImportSheet = false
                    showFileImporter = true
                } label: {
                    Label("Import Zone Bundle", systemImage: "folder")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Location List

    private var locationListSheet: some View {
        NavigationStack {
            List {
                // Group locations by zone
                ForEach(userManager.zoneManifest.zones) { zone in
                    let zoneWaypoints = userManager.allLocationWaypoints.filter { $0.zoneID == zone.id }
                    if !zoneWaypoints.isEmpty {
                        Section {
                            ForEach(zoneWaypoints) { wp in
                                locationRow(wp: wp)
                            }
                        } header: {
                            HStack {
                                Text(zone.name)
                                if zone.id == userManager.activeZone?.id {
                                    Text("(current)")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                // Waypoints without a zoneID (legacy)
                let unzoned = userManager.allLocationWaypoints.filter { $0.zoneID == nil }
                if !unzoned.isEmpty {
                    Section("Other") {
                        ForEach(unzoned) { wp in
                            locationRow(wp: wp)
                        }
                    }
                }
            }
            .navigationTitle("Navigate to...")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showLocationList = false }
                }
            }
        }
    }

    private func locationRow(wp: Waypoint) -> some View {
        Button {
            userManager.navigateTo(wp)
            showLocationList = false
        } label: {
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.blue)

                VStack(alignment: .leading) {
                    Text(wp.label)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let desc = wp.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if wp.zoneID != userManager.activeZone?.id {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Zone List Sheet

    private var zoneListSheet: some View {
        NavigationStack {
            List {
                ForEach(userManager.zoneManifest.zones) { zone in
                    Button {
                        userManager.selectZone(zone)
                        showZoneList = false
                    } label: {
                        HStack {
                            Image(systemName: zone.id == userManager.activeZone?.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(zone.id == userManager.activeZone?.id ? .blue : .secondary)

                            VStack(alignment: .leading) {
                                Text(zone.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text("\(zone.referenceImageNames.count) reference images")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if zone.id == userManager.activeZone?.id {
                                Text("Active")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showZoneList = false }
                }
            }
        }
    }

    // MARK: - Import Sheet

    private var importSheet: some View {
        NavigationStack {
            List {
                Section("Zone Bundle") {
                    Button {
                        pendingImport = true
                        showImportSheet = false
                    } label: {
                        Label("Import Zone Bundle (folder)", systemImage: "folder")
                    }

                    if userManager.hasZoneData {
                        HStack {
                            Text("Loaded")
                            Spacer()
                            Text("\(userManager.zoneManifest.zones.count) zone(s)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                Section {
                    Text("Export the zone bundle from the Admin app (e.g. via AirDrop or Files), then import it here. The bundle contains all zones with their graphs and world maps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showImportSheet = false }
                }
            }
        }
    }
}
