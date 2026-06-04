//
//  MapSettingsForm.swift
//  Meshtastic
//
//  Created by Garth Vander Houwen on 10/3/23.
//

import SwiftUI
import MapKit

struct MapSettingsForm: View {
	@Environment(\.dismiss) private var dismiss
	@State private var currentDetent = PresentationDetent.medium
	@AppStorage("meshMapShowNodeHistory") private var nodeHistory = false
	@AppStorage("meshMapShowRouteLines") private var routeLines = false
	@AppStorage("enableMapConvexHull") private var convexHull = false
	@AppStorage("enableMapWaypoints") private var waypoints = true
	@Binding var traffic: Bool
	@Binding var pointsOfInterest: Bool
	@Binding var mapLayer: MapLayer
	@AppStorage("meshMapDistance") private var meshMapDistance: Double = 800000
	@Binding var meshMap: Bool
	var visibleRegion: MKCoordinateRegion?
	@ObservedObject private var tileManager = OfflineTileManager.shared
	@AppStorage("enableOfflineMaps") private var enableOfflineMaps = false
	@AppStorage("mapTileServer") private var mapTileServer: MapTileServer = .openStreetMap
	@AppStorage("mapTilesAboveLabels") private var mapTilesAboveLabels = false
	@State private var minimumZoom = 8
	@State private var maximumZoom = 14
	@State private var downloadedTileSize = "0MB"
	private let maximumInteractiveDownloadTileCount = 10_000

	var body: some View {

		NavigationStack {
			Form {
				Section(header: Text("Map Options")) {
					Picker(selection: $mapLayer, label: Text("")) {
						ForEach(MapLayer.allCases, id: \.self) { layer in
							Text(layer.localized)
						}
					}
					.pickerStyle(SegmentedPickerStyle())
					.padding(.top, 5)
					.padding(.bottom, 5)
					.onChange(of: mapLayer) { _, newMapLayer in
						UserDefaults.mapLayer = newMapLayer
						if newMapLayer == .offline {
							enableOfflineMaps = true
						}
					}
					if meshMap {
						HStack {
							Label("Show nodes", systemImage: "lines.measurement.horizontal")
							Picker("", selection: $meshMapDistance) {
								ForEach(MeshMapDistances.allCases) { di in
									Text(di.description)
										.tag(di.id)
								}
							}
							.pickerStyle(DefaultPickerStyle())
						}
						.onChange(of: meshMapDistance) { _, newMeshMapDistance in
							UserDefaults.meshMapDistance = newMeshMapDistance
						}
						Toggle(isOn: $waypoints) {
							Label("Show Waypoints ", systemImage: "signpost.right.and.left")
						}
						.toggleStyle(SwitchToggleStyle(tint: .accentColor))
						.onTapGesture {
							UserDefaults.enableMapWaypoints = !waypoints
						}
					}

					Toggle(isOn: $nodeHistory) {
						Label("Node History", systemImage: "building.columns.fill")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					.onTapGesture {
						self.nodeHistory.toggle()
						UserDefaults.enableMapNodeHistoryPins = self.nodeHistory
					}
					Toggle(isOn: $routeLines) {
						Label("Route Lines", systemImage: "road.lanes")
					}

					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					.onTapGesture {
						self.routeLines.toggle()
						UserDefaults.enableMapRouteLines = self.routeLines
					}
					Toggle(isOn: $convexHull) {
						Label("Convex Hull", systemImage: "button.angledbottom.horizontal.right")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					.onTapGesture {
						self.convexHull.toggle()
						UserDefaults.enableMapConvexHull = self.convexHull
					}
					Toggle(isOn: $traffic) {
						Label("Traffic", systemImage: "car")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					.onTapGesture {
						self.traffic.toggle()
						UserDefaults.enableMapTraffic = self.traffic
					}
					Toggle(isOn: $pointsOfInterest) {
						Label("Points of Interest", systemImage: "mappin.and.ellipse")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					.onTapGesture {
						self.pointsOfInterest.toggle()
						UserDefaults.enableMapPointsOfInterest = self.pointsOfInterest
					}
				}
				Section(header: Text("Offline Maps")) {
					LabeledContent("Downloaded Tiles", value: downloadedTileSize)
					Toggle(isOn: $enableOfflineMaps) {
						Label("Enable Offline Maps", systemImage: "square.and.arrow.down")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					.onChange(of: enableOfflineMaps) { _, enabled in
						UserDefaults.enableOfflineMaps = enabled
						if !enabled, mapLayer == .offline {
							mapLayer = .standard
							UserDefaults.mapLayer = .standard
						}
					}

					Picker("Map Style", selection: $mapTileServer) {
						ForEach(MapTileServer.allCases) { server in
							Text(server.description)
								.tag(server)
						}
					}
					.onChange(of: mapTileServer) { _, newServer in
						UserDefaults.mapTileServer = newServer
						clampZoomRange(to: newServer)
					}

					Text(LocalizedStringKey(mapTileServer.attribution))
						.font(.caption)
						.foregroundStyle(.secondary)

					Toggle(isOn: $mapTilesAboveLabels) {
						Label("Tiles Above Labels", systemImage: "rectangle.2.swap")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					.onChange(of: mapTilesAboveLabels) { _, newValue in
						UserDefaults.mapTilesAboveLabels = newValue
					}

					Stepper("Minimum Zoom \(minimumZoom)", value: $minimumZoom, in: serverMinimumZoom...maximumZoom)
					Stepper("Maximum Zoom \(maximumZoom)", value: $maximumZoom, in: minimumZoom...serverMaximumZoom)

					if let visibleRegion {
						let tileCount = tileManager.estimatedTileCount(
							in: visibleRegion,
							server: mapTileServer,
							zoomRange: minimumZoom...maximumZoom
						)
						Text("\(tileCount) tiles will be downloaded for the current map area.")
							.font(.caption)
							.foregroundStyle(tileCount > maximumInteractiveDownloadTileCount ? .orange : .secondary)
						if tileCount > maximumInteractiveDownloadTileCount {
							Text("Zoom in or lower the zoom range before downloading. This prevents accidentally queueing a very large map download.")
								.font(.caption)
								.foregroundStyle(.orange)
						}

						Button {
							enableOfflineMaps = true
							mapLayer = .offline
							Task {
								await tileManager.downloadTiles(
									in: visibleRegion,
									server: mapTileServer,
									zoomRange: minimumZoom...maximumZoom
								)
								downloadedTileSize = tileManager.getAllDownloadedSize()
							}
						} label: {
							Label("Download Current Map Area", systemImage: "arrow.down.map")
						}
						.disabled(tileManager.status == .downloading || tileCount == 0 || tileCount > maximumInteractiveDownloadTileCount)
					} else {
						Text("Move the map once, then reopen this sheet to download the visible area.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}

					if tileManager.downloadProgress.isActive || tileManager.downloadProgress.total > 0 {
						ProgressView(value: tileManager.downloadProgress.fractionCompleted) {
							Text(tileManager.downloadProgress.isActive ? "Downloading \(tileManager.downloadProgress.styleName)" : "Download Complete")
						} currentValueLabel: {
							Text("\(tileManager.downloadProgress.completed)/\(tileManager.downloadProgress.total)")
						}
						if tileManager.downloadProgress.failed > 0 {
							Text("\(tileManager.downloadProgress.failed) tiles failed and can be retried.")
								.font(.caption)
								.foregroundStyle(.orange)
						}
					}
				}
			}
			.onAppear {
				clampZoomRange(to: mapTileServer)
				downloadedTileSize = tileManager.getAllDownloadedSize()
			}

#if targetEnvironment(macCatalyst)
Spacer()
				Button {
					dismiss()
				} label: {
					Label("close", systemImage: "xmark")
				}
				.buttonStyle(.bordered)
				.buttonBorderShape(.capsule)
				.controlSize(.large)
				.padding(.bottom)
#endif
		}
		.presentationDetents([.medium, .large], selection: $currentDetent)
		.presentationContentInteraction(.scrolls)
		.presentationDragIndicator(.visible)
		.presentationBackgroundInteraction(.enabled(upThrough: .medium))

	}

	private var serverMinimumZoom: Int {
		mapTileServer.zoomRange.first ?? 0
	}

	private var serverMaximumZoom: Int {
		mapTileServer.zoomRange.last ?? 18
	}

	private func clampZoomRange(to server: MapTileServer) {
		let minimum = server.zoomRange.first ?? 0
		let maximum = server.zoomRange.last ?? 18
		minimumZoom = min(max(minimumZoom, minimum), maximum)
		maximumZoom = min(max(maximumZoom, minimumZoom), maximum)
	}
}
