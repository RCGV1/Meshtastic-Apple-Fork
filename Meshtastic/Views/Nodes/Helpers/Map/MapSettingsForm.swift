//
//  MapSettingsForm.swift
//  Meshtastic
//
//  Created by Garth Vander Houwen on 10/3/23.
//

import SwiftUI
import MapKit
import UniformTypeIdentifiers

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
	@AppStorage("offlineImportedTileSourceID") private var importedTileSourceID = ""
	@AppStorage("offlineMapUse3DElevation") private var use3DElevation = false
	@State private var minimumZoom = 8
	@State private var maximumZoom = 14
	@State private var downloadedTileSize = "0MB"
	@State private var importedDataSize = "0MB"
	@State private var isImportingOfflineMapData = false
	@State private var importErrorMessage = ""
	@State private var showImportError = false
	@State private var showOfflineDownloadDetails = false
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
					LabeledContent("Imported Data", value: importedDataSize)
					Toggle(isOn: $enableOfflineMaps) {
						Label("Show Offline Map Data", systemImage: "square.and.arrow.down")
					}
					.toggleStyle(SwitchToggleStyle(tint: .accentColor))
					.onChange(of: enableOfflineMaps) { _, enabled in
						UserDefaults.enableOfflineMaps = enabled
						if !enabled, mapLayer == .offline {
							mapLayer = .standard
							UserDefaults.mapLayer = .standard
						}
					}

					Text("Apple Maps stays as the base map. Downloaded or imported raster tiles are drawn only where offline data exists, so provider error tiles and blocked live tile screens are not shown during normal map use.")
						.font(.caption)
						.foregroundStyle(.secondary)

					Picker("Download Style", selection: $mapTileServer) {
						ForEach(MapTileServer.offlineDownloadSources) { server in
							Text(server.offlineDownloadTitle)
								.tag(server)
						}
					}
					.onChange(of: mapTileServer) { _, newServer in
						UserDefaults.mapTileServer = newServer
						clampZoomRange(to: newServer)
					}

					Text(mapTileServer.offlineDownloadDescription)
						.font(.caption)
						.foregroundStyle(.secondary)

					DisclosureGroup("Download Details", isExpanded: $showOfflineDownloadDetails) {
						Stepper("Minimum Zoom \(minimumZoom)", value: $minimumZoom, in: serverMinimumZoom...maximumZoom)
						Stepper("Maximum Zoom \(maximumZoom)", value: $maximumZoom, in: minimumZoom...serverMaximumZoom)
						Toggle(isOn: $mapTilesAboveLabels) {
							Label("Draw Offline Tiles Above Labels", systemImage: "rectangle.2.swap")
						}
						.toggleStyle(SwitchToggleStyle(tint: .accentColor))
						.onChange(of: mapTilesAboveLabels) { _, newValue in
							UserDefaults.mapTilesAboveLabels = newValue
						}
						Toggle(isOn: $use3DElevation) {
							Label("Use 3D Map Camera", systemImage: "cube.transparent")
						}
						.toggleStyle(SwitchToggleStyle(tint: .accentColor))
						.onChange(of: use3DElevation) { _, newValue in
							UserDefaults.offlineMapUse3DElevation = newValue
						}
						Text("MapKit accepts raster EPSG:3857 offline tiles. Third-party 3D terrain packages can be stored, but Apple MapKit does not consume them as custom offline elevation tiles.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}

					if let visibleRegion {
						let estimate = tileManager.downloadEstimate(
							in: visibleRegion,
							server: mapTileServer,
							zoomRange: minimumZoom...maximumZoom
						)
						Text("\(estimate.tileCount) tiles will be downloaded for the current map area.")
							.font(.caption)
							.foregroundStyle(estimate.tileCount > maximumInteractiveDownloadTileCount ? .orange : .secondary)

						LabeledContent(
							"Estimated Space",
							value: tileManager.formattedByteCount(estimate.estimatedBytes)
						)
						LabeledContent(
							"Tiles After Download",
							value: tileManager.formattedByteCount(estimate.projectedTileBytes)
						)

						if estimate.tileCount > maximumInteractiveDownloadTileCount {
							Text("Zoom in or lower the zoom range before downloading. This prevents accidentally queueing a very large map download.")
								.font(.caption)
								.foregroundStyle(.orange)
						}

						Button {
							enableOfflineMaps = true
							Task {
								await tileManager.downloadTiles(
									in: visibleRegion,
									server: mapTileServer,
									zoomRange: minimumZoom...maximumZoom
								)
								refreshStorageSizes()
							}
						} label: {
							Label("Download Current Map Area", systemImage: "arrow.down.map")
						}
						.disabled(tileManager.status == .downloading || estimate.tileCount == 0 || estimate.tileCount > maximumInteractiveDownloadTileCount)
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

				Section(header: Text("Offline Imports")) {
					Button {
						isImportingOfflineMapData = true
					} label: {
						Label("Import Offline Map Data", systemImage: "square.and.arrow.down.on.square")
					}

					let rasterImports = tileManager.imports.filter(\.supportsRasterTiles)
					if rasterImports.isEmpty {
						Text("Import KML, GPX, or GeoJSON for offline overlays. Import raster MBTiles or XYZ folders to use them as offline map tiles. PMTiles and 3D packages are stored and sized, but need a renderer before they can replace the map.")
							.font(.caption)
							.foregroundStyle(.secondary)
					} else {
						Button {
							importedTileSourceID = ""
							UserDefaults.offlineImportedTileSourceID = ""
						} label: {
							Label(
								importedTileSourceID.isEmpty ? "Using Downloaded Tiles" : "Use Downloaded Tiles",
								systemImage: importedTileSourceID.isEmpty ? "checkmark.circle.fill" : "arrow.down.map"
							)
						}
						.buttonStyle(.borderless)
					}

					ForEach(tileManager.imports) { imported in
						VStack(alignment: .leading, spacing: 4) {
							HStack {
								Label(imported.displayName, systemImage: imported.systemImage)
								Spacer()
								Text(tileManager.formattedByteCount(imported.byteCount))
									.foregroundStyle(.secondary)
							}
							Text(imported.importDetail)
								.font(.caption)
								.foregroundStyle(.secondary)
							if imported.supportsRasterTiles {
								Button {
									importedTileSourceID = imported.id
									UserDefaults.offlineImportedTileSourceID = imported.id
								} label: {
									Label(
										importedTileSourceID == imported.id ? "Using as Offline Tiles" : "Use as Offline Tiles",
										systemImage: importedTileSourceID == imported.id ? "checkmark.circle.fill" : "map"
									)
								}
								.buttonStyle(.borderless)
							}
							Button(role: .destructive) {
								tileManager.removeImport(id: imported.id)
								refreshStorageSizes()
							} label: {
								Label("Remove Import", systemImage: "trash")
							}
							.buttonStyle(.borderless)
						}
					}
				}
			}
			.onAppear {
				normalizeDownloadSourceIfNeeded()
				clampZoomRange(to: mapTileServer)
				refreshStorageSizes()
			}
			.fileImporter(
				isPresented: $isImportingOfflineMapData,
				allowedContentTypes: [.item, .folder],
				allowsMultipleSelection: false
			) { result in
				handleOfflineImport(result)
			}
			.alert("Offline Import Failed", isPresented: $showImportError) {
				Button("OK", role: .cancel) {}
			} message: {
				Text(importErrorMessage)
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

	private func refreshStorageSizes() {
		downloadedTileSize = tileManager.getAllDownloadedSize()
		importedDataSize = tileManager.formattedByteCount(tileManager.importedDataByteCount())
	}

	private func normalizeDownloadSourceIfNeeded() {
		guard !MapTileServer.offlineDownloadSources.contains(mapTileServer) else { return }
		mapTileServer = .defaultOfflineDownloadSource
		UserDefaults.mapTileServer = .defaultOfflineDownloadSource
	}

	private func handleOfflineImport(_ result: Result<[URL], Error>) {
		switch result {
		case .success(let urls):
			guard let url = urls.first else { return }
			Task {
				do {
					_ = try await tileManager.importOfflineMapData(from: url)
					await MainActor.run {
						refreshStorageSizes()
					}
				} catch {
					await MainActor.run {
						importErrorMessage = error.localizedDescription
						showImportError = true
					}
				}
			}
		case .failure(let error):
			importErrorMessage = error.localizedDescription
			showImportError = true
		}
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

private extension OfflineMapImport {
	var systemImage: String {
		switch kind {
		case .kml, .kmz, .gpx, .geoJSON:
			return "point.3.connected.trianglepath.dotted"
		case .mbtiles, .pmtiles, .xyzDirectory:
			return supportsRasterTiles ? "map" : "shippingbox"
		case .unknown:
			return "doc"
		}
	}

	var importDetail: String {
		var details = [kind.displayName]
		if let minimumZoom, let maximumZoom {
			details.append("z\(minimumZoom)-z\(maximumZoom)")
		}
		if let tileFormat {
			details.append(tileFormat.uppercased())
		}
		if supportsRasterTiles {
			details.append("selectable raster source")
		} else if kind.isVectorOverlay {
			details.append("offline overlay")
		} else if supports3D {
			details.append("3D package stored")
		} else {
			details.append("stored")
		}
		return details.joined(separator: " · ")
	}
}
