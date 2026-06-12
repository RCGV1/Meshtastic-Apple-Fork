//
//  MapSettingsForm.swift
//  Meshtastic
//
//  Created by Garth Vander Houwen on 10/3/23.
//

import SwiftUI
import MapKit
import OSLog
import UniformTypeIdentifiers

struct MapSettingsForm: View {
	@Environment(\.dismiss) private var dismiss
	@State private var currentDetent = PresentationDetent.medium
	@AppStorage("meshMapShowNodeHistory") private var nodeHistory = false
	@AppStorage("meshMapShowRouteLines") private var enableMapRouteLines = false
	@AppStorage("enableMapConvexHull") private var convexHull = false
	@AppStorage("enableMapWaypoints") private var enableMapWaypoints = true
	@AppStorage("mapOverlaysEnabled") private var mapOverlaysEnabled = false
	@ObservedObject private var mapDataManager = MapDataManager.shared
	@Binding var traffic: Bool
	@Binding var pointsOfInterest: Bool
	@Binding var mapLayer: MapLayer
	@AppStorage("meshMapDistance") private var meshMapDistance: Double = 800000
	@Binding var meshMap: Bool
	@Binding var enabledOverlayConfigs: Set<UUID>
	var visibleRegion: MKCoordinateRegion?
	@Binding var downloadSelection: CGRect
	let onOpenDownloadMap: () -> Void
	@ObservedObject private var tileManager = OfflineTileManager.shared
	@AppStorage("enableOfflineMaps") private var enableOfflineMaps = false
	@AppStorage("mapTileServer") private var mapTileServer: MapTileServer = .openStreetMap
	@AppStorage("offlineImportedTileSourceID") private var importedTileSourceID = ""
	@AppStorage("offlineMapUseVectorRenderer") private var useVectorRenderer = true
	@AppStorage("offlineVectorMapStyle") private var vectorMapStyle: OfflineVectorMapStyle = .liberty
	@State private var minimumZoom = 8
	@State private var maximumZoom = 14
	@State private var downloadedTileSize = "0 MB"
	@State private var importedDataSize = "0 MB"
	@State private var isImportingOfflineMapData = false
	@State private var importErrorMessage = ""
	@State private var showImportError = false

	var body: some View {

		NavigationStack {
			Form {
				Section(header: Text("Map Options")) {
					Picker(selection: $mapLayer, label: Text("")) {
						ForEach(MapLayer.allCases, id: \.self) { layer in
							Text(layer.localized.capitalized)
						}
					}
					.pickerStyle(SegmentedPickerStyle())
					.padding(.top, 5)
					.padding(.bottom, 5)
					.onChange(of: mapLayer) { _, newMapLayer in
						UserDefaults.mapLayer = newMapLayer
						if newMapLayer == .offline {
							enableOfflineMaps = true
							UserDefaults.enableOfflineMaps = true
						}
					}
					if meshMap {
					if LocationsHandler.currentPreciseLocation != nil {
							HStack {
								Label("Distance", systemImage: "lines.measurement.horizontal")
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
						}
						Toggle(isOn: $enableMapWaypoints) {
							Label {
								Text("Waypoints")
							} icon: {
								Image(systemName: "signpost.right.and.left")
									.symbolRenderingMode(.multicolor)
							}
						}
						.tint(.accentColor)
					}
					if !meshMap {
						Toggle(isOn: $nodeHistory) {
							Label("Node History", systemImage: "building.columns.fill")
						}
						.toggleStyle(SwitchToggleStyle(tint: .accentColor))
						Toggle(isOn: $enableMapRouteLines) {
							Label("Route Lines", systemImage: "road.lanes")
						}
						.tint(.accentColor)

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
						Label {
							Text("Points of Interest")
						} icon: {
							Image(systemName: "mappin.and.ellipse")
								.symbolRenderingMode(.multicolor)
						}
					}
					.tint(.accentColor)
					.onTapGesture {
						self.pointsOfInterest.toggle()
						UserDefaults.enableMapPointsOfInterest = self.pointsOfInterest
					}
				}
				offlineMapsSection
				offlineImportsSection

				Section(header: Text("Map Overlays")) {
					let hasUserData = GeoJSONOverlayManager.shared.hasUserData()
					// Master toggle for map overlays
					Toggle(isOn: $mapOverlaysEnabled) {
						Label {
							VStack(alignment: .leading) {
								Text("Map Overlays")
								Text(GeoJSONOverlayManager.shared.getActiveDataSource())
									.font(.caption)
									.foregroundColor(.secondary)
							}
						} icon: {
							Image(systemName: "map")
								.symbolRenderingMode(.multicolor)
						}
					}
					.tint(.accentColor)
					.disabled(!hasUserData && !mapOverlaysEnabled)

					// Show individual file toggles when overlays are enabled
					if mapOverlaysEnabled && hasUserData {
						if !mapDataManager.getUploadedFiles().isEmpty {
							// Individual file toggles
							ForEach(mapDataManager.getUploadedFiles()) { file in
								Toggle(isOn: Binding(
									get: {
										return enabledOverlayConfigs.contains(file.id)
									},
									set: { newValue in
										if newValue {
											enabledOverlayConfigs.insert(file.id)
										} else {
											enabledOverlayConfigs.remove(file.id)
										}
									}
								)) {
									Label {
										VStack(alignment: .leading) {
											Text(file.originalName)
												.font(.subheadline)
											HStack {
												Text("\(file.overlayCount) features")
													.font(.caption2)
													.foregroundColor(.secondary)
												Spacer()
												Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
													.font(.caption2)
													.foregroundColor(.secondary)
											}
										}
									} icon: {
										let isEnabled = enabledOverlayConfigs.contains(file.id)
										Image(systemName: isEnabled ? "doc.fill" : "doc")
											.foregroundColor(isEnabled ? .accentColor : .secondary)
									}
								}
								.tint(.accentColor)
							}
							NavigationLink(destination: MapDataFiles()) {
								Label {
									Text("Manage map data")
								} icon: {
									Image(systemName: "folder")
										.symbolRenderingMode(.multicolor)
								}
							}
						} else {
							ContentUnavailableView("No map data files uploaded", systemImage: "exclamationmark.triangle")
						}
					} else if !hasUserData {
						// Upload prompt when no data available
						NavigationLink(destination: MapDataFiles()) {
							Label {
								Text("Upload map data to enable overlays")
							} icon: {
								Image(systemName: "arrow.up.doc")
									.symbolRenderingMode(.multicolor)
							}
						}
					}
				}
			}
			.navigationTitle("Map Options")
			.navigationBarTitleDisplayMode(.inline)
		}
		#if targetEnvironment(macCatalyst)
		.overlay(alignment: .topLeading) {
			Button {
				dismiss()
			} label: {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 34))
					.symbolRenderingMode(.palette)
					.foregroundStyle(.white, Color(.systemGray3))
			}
			.buttonStyle(.plain)
			.padding(.top, 12)
			.padding(.leading, 14)
		}
		#endif
		.presentationDetents([.large], selection: $currentDetent)
		.presentationContentInteraction(.scrolls)
		#if !targetEnvironment(macCatalyst)
		.presentationDragIndicator(.visible)
		#endif
		.presentationBackgroundInteraction(.enabled(upThrough: .medium))
		.onAppear {
			mapDataManager.initialize()
			UserDefaults.migrateNativeOSMRendererSourceIfNeeded()
			mapTileServer = UserDefaults.mapTileServer
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

	}

	@ViewBuilder
	private var offlineMapsSection: some View {
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

			LabeledContent("Map Engine", value: MapTileServer.openStreetMap.offlineDownloadTitle)
			Text(MapTileServer.openStreetMap.offlineDownloadDescription)
				.font(.caption)
				.foregroundStyle(.secondary)

			Picker("OSM Style", selection: $vectorMapStyle) {
				ForEach(OfflineVectorMapStyle.allCases) { style in
					Text(style.displayName)
						.tag(style)
				}
			}
			.onChange(of: vectorMapStyle) { _, newStyle in
				UserDefaults.offlineVectorMapStyle = newStyle
				useVectorRenderer = true
				UserDefaults.offlineMapUseVectorRenderer = true
			}
			Text(vectorMapStyle.detail)
				.font(.caption)
				.foregroundStyle(.secondary)

			Button {
				mapTileServer = .openStreetMap
				UserDefaults.mapTileServer = .openStreetMap
				importedTileSourceID = ""
				UserDefaults.offlineImportedTileSourceID = ""
				useVectorRenderer = true
				UserDefaults.offlineMapUseVectorRenderer = true
				onOpenDownloadMap()
				dismiss()
			} label: {
				Label("Download Map", systemImage: "arrow.down.map")
			}
			Text("Pick an area on the map, then choose the MapLibre styles and zoom range to save.")
				.font(.caption)
				.foregroundStyle(.secondary)

			if visibleRegion == nil {
				Text("The download screen can estimate size after the map reports its visible region.")
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

		Section(header: Text("Downloaded Map Areas")) {
			if tileManager.downloadedRegions.isEmpty {
				Text("No named downloads yet. Tap Download Map to select an area.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			ForEach(tileManager.downloadedRegions) { downloadedRegion in
				VStack(alignment: .leading, spacing: 6) {
					HStack {
						Label(downloadedRegion.name, systemImage: "map.fill")
						Spacer()
						Text(tileManager.formattedByteCount(downloadedRegion.byteCount))
							.foregroundStyle(.secondary)
					}
					Text(downloadDetail(downloadedRegion))
						.font(.caption)
						.foregroundStyle(.secondary)
					HStack {
						Button {
							updateExistingDownload(downloadedRegion)
						} label: {
							Label("Update", systemImage: "arrow.clockwise")
						}
						.buttonStyle(.borderless)
					}
					Button(role: .destructive) {
						tileManager.removeDownloadedRegion(id: downloadedRegion.id)
						refreshStorageSizes()
					} label: {
						Label("Forget Download Record", systemImage: "trash")
					}
					.buttonStyle(.borderless)
				}
			}
		}
	}

	@ViewBuilder
	private var offlineImportsSection: some View {
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

	private func refreshStorageSizes() {
		downloadedTileSize = tileManager.getAllDownloadedSize()
		importedDataSize = tileManager.formattedByteCount(tileManager.importedDataByteCount())
	}

	private func updateExistingDownload(_ downloadedRegion: OfflineMapDownloadRegion) {
		enableOfflineMaps = true
		UserDefaults.enableOfflineMaps = true
		let styles = downloadedRegion.mapLibreStyles ?? [vectorMapStyle]
		Task {
			_ = await tileManager.downloadMapLibreTiles(
				in: downloadedRegion.bounds.coordinateRegion,
				styles: styles,
				zoomRange: downloadedRegion.minimumZoom...downloadedRegion.maximumZoom,
				name: downloadedRegion.name,
				existingDownloadID: downloadedRegion.id
			)
			await MainActor.run {
				refreshStorageSizes()
			}
		}
	}

	private func downloadDetail(_ downloadedRegion: OfflineMapDownloadRegion) -> String {
		let date = downloadedRegion.updatedAt.formatted(date: .abbreviated, time: .shortened)
		let styles = (downloadedRegion.mapLibreStyles ?? [])
			.map(\.displayName)
			.joined(separator: ", ")
		let styleDetail = styles.isEmpty ? "MapLibre" : styles
		return "\(downloadedRegion.server.normalizedOfflineDownloadSource.offlineDownloadTitle) · \(styleDetail) · z\(downloadedRegion.minimumZoom)-z\(downloadedRegion.maximumZoom) · \(downloadedRegion.tileCount) tiles · updated \(date)"
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
		MapTileServer.openStreetMap.zoomRange.first ?? 0
	}

	private var serverMaximumZoom: Int {
		MapTileServer.openStreetMap.offlineDisplayZoomRange.upperBound
	}

	private func clampZoomRange(to server: MapTileServer) {
		let range = server.normalizedOfflineDownloadSource.offlineDisplayZoomRange
		let minimum = range.lowerBound
		let maximum = range.upperBound
		minimumZoom = min(max(minimumZoom, minimum), maximum)
		maximumZoom = min(max(maximumZoom, minimumZoom), maximum)
	}
}

enum OfflineMapDownloadSelectionGeometry {
	static func region(in visibleRegion: MKCoordinateRegion, selection: CGRect) -> MKCoordinateRegion {
		let selection = normalized(selection)
		let latitudeDelta = max(visibleRegion.span.latitudeDelta * selection.height, 0.000_001)
		let longitudeDelta = max(visibleRegion.span.longitudeDelta * selection.width, 0.000_001)
		let northLatitude = visibleRegion.center.latitude + visibleRegion.span.latitudeDelta / 2
		let westLongitude = visibleRegion.center.longitude - visibleRegion.span.longitudeDelta / 2
		let centerLatitude = northLatitude - visibleRegion.span.latitudeDelta * selection.midY
		let centerLongitude = normalizedLongitude(westLongitude + visibleRegion.span.longitudeDelta * selection.midX)

		return MKCoordinateRegion(
			center: CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude),
			span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
		)
	}

	static func normalized(_ selection: CGRect) -> CGRect {
		let width = min(max(selection.width, 0.18), 1)
		let height = min(max(selection.height, 0.16), 1)
		let x = min(max(selection.origin.x, 0), 1 - width)
		let y = min(max(selection.origin.y, 0), 1 - height)
		return CGRect(x: x, y: y, width: width, height: height)
	}

	static func normalizedLongitude(_ longitude: CLLocationDegrees) -> CLLocationDegrees {
		var normalized = longitude
		while normalized < -180 { normalized += 360 }
		while normalized > 180 { normalized -= 360 }
		return normalized
	}
}

struct OfflineMapDownloadSelectionControls: View {
	@Binding var isSelecting: Bool
	@Binding var isConfiguring: Bool
	let selection: CGRect
	let visibleRegion: MKCoordinateRegion?

	@ObservedObject private var tileManager = OfflineTileManager.shared

	var body: some View {
		VStack {
			Spacer()
			VStack(alignment: .leading, spacing: 12) {
				HStack(alignment: .top, spacing: 10) {
					Image(systemName: "rectangle.dashed")
						.font(.title3.weight(.semibold))
						.foregroundStyle(Color.accentColor)
					VStack(alignment: .leading, spacing: 3) {
						Text("Choose Download Area")
							.font(.headline)
						Text("Drag or resize the box. You will choose layers, name, and zooms on the next screen.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					Spacer()
				}

				if let visibleRegion {
					let estimate = tileManager.downloadEstimate(
						in: OfflineMapDownloadSelectionGeometry.region(
							in: visibleRegion,
							selection: selection
						),
						server: .openStreetMap,
						zoomRange: 8...14
					)
					HStack {
						Label("Typical size", systemImage: "internaldrive")
						Spacer()
						Text(tileManager.formattedByteCount(estimate.estimatedBytes))
							.fontWeight(.semibold)
					}
					.font(.caption)
					.foregroundStyle(.secondary)
				} else {
					Text("Move the map once so the app can calculate the selected area.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				HStack(spacing: 10) {
					Button("Cancel") {
						withAnimation(.snappy) {
							isSelecting = false
						}
					}
					.buttonStyle(.bordered)
					Spacer()
					Button {
						withAnimation(.snappy) {
							isConfiguring = true
						}
					} label: {
						Label("Next", systemImage: "chevron.right")
					}
					.buttonStyle(.borderedProminent)
					.disabled(visibleRegion == nil)
				}
			}
			.padding(16)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 20, style: .continuous)
					.stroke(.white.opacity(0.25), lineWidth: 1)
			}
			.shadow(color: .black.opacity(0.20), radius: 18, y: 8)
			.padding(.horizontal, 12)
			.padding(.bottom, 12)
		}
	}
}

struct OfflineMapDownloadConfigurationSheet: View {
	@Environment(\.dismiss) private var dismiss
	@Binding var isSelecting: Bool
	@Binding var mapLayer: MapLayer
	@Binding var enableOfflineMaps: Bool
	let selection: CGRect
	let visibleRegion: MKCoordinateRegion?

	@ObservedObject private var tileManager = OfflineTileManager.shared
	@AppStorage("mapTileServer") private var mapTileServer: MapTileServer = .openStreetMap
	@AppStorage("offlineMapUseVectorRenderer") private var useVectorRenderer = true
	@AppStorage("offlineVectorMapStyle") private var selectedVectorMapStyle: OfflineVectorMapStyle = .liberty
	@State private var downloadName = ""
	@State private var selectedStyles: Set<OfflineVectorMapStyle> = []
	@State private var minimumZoom = 8
	@State private var maximumZoom = 14
	@State private var styleDownloadMessage = ""
	private let maximumInteractiveDownloadTileCount = 10_000

	private var selectedRegion: MKCoordinateRegion? {
		guard let visibleRegion else { return nil }
		return OfflineMapDownloadSelectionGeometry.region(in: visibleRegion, selection: selection)
	}

	private var estimate: OfflineTileDownloadEstimate? {
		guard let selectedRegion else { return nil }
		return tileManager.downloadEstimate(
			in: selectedRegion,
			server: .openStreetMap,
			zoomRange: minimumZoom...maximumZoom
		)
	}

	private var canDownload: Bool {
		guard let estimate else { return false }
		return !selectedStyles.isEmpty &&
			tileManager.status != .downloading &&
			estimate.tileCount > 0 &&
			estimate.tileCount <= maximumInteractiveDownloadTileCount
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("Name (optional)", text: $downloadName)
						.textInputAutocapitalization(.words)
					if let selectedRegion, let estimate {
						LabeledContent("Estimated Space", value: tileManager.formattedByteCount(estimate.estimatedBytes))
						LabeledContent("Estimated Tiles", value: "\(estimate.tileCount)")
						Text(String(format: "Center %.3f, %.3f", selectedRegion.center.latitude, selectedRegion.center.longitude))
							.font(.caption.monospacedDigit())
							.foregroundStyle(.secondary)
					} else {
						Text("Move the map once so the app can calculate the selected area.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				} header: {
					Text("Selected Area")
				}

				Section {
					styleSelection
				} header: {
					Text("Layers")
				}

				Section {
					Stepper("Minimum Zoom \(minimumZoom)", value: $minimumZoom, in: serverMinimumZoom...maximumZoom)
					Stepper("Maximum Zoom \(maximumZoom)", value: $maximumZoom, in: minimumZoom...serverMaximumZoom)
					if let estimate {
						if estimate.tileCount > maximumInteractiveDownloadTileCount {
							Text("Shrink the box, zoom in, or lower the zoom range before downloading. This prevents accidentally queueing a very large download.")
								.font(.caption)
								.foregroundStyle(.orange)
						} else if estimate.usesScaledNativeZoom {
							Text("Native z\(estimate.requestedZoomRange.lowerBound)-z\(estimate.requestedZoomRange.upperBound) uses source z\(estimate.sourceZoomRange.lowerBound)-z\(estimate.sourceZoomRange.upperBound) where the tile source has no deeper data.")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
				} header: {
					Text("Zoom Range")
				}

				if !styleDownloadMessage.isEmpty {
					Section {
						Text(styleDownloadMessage)
							.font(.caption)
							.foregroundStyle(.orange)
					}
				}

				if tileManager.downloadProgress.isActive || tileManager.downloadProgress.total > 0 {
					Section {
						ProgressView(value: tileManager.downloadProgress.fractionCompleted) {
							Text(tileManager.downloadProgress.isActive ? "Downloading \(tileManager.downloadProgress.styleName)" : "Download Complete")
						} currentValueLabel: {
							Text("\(tileManager.downloadProgress.completed)/\(tileManager.downloadProgress.total)")
						}
					}
				}
			}
			.navigationTitle("Save Offline Map")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Back") {
						dismiss()
					}
					.disabled(tileManager.status == .downloading)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Download") {
						downloadSelectedArea()
					}
					.disabled(!canDownload)
				}
			}
			.onAppear {
				configureDefaultsIfNeeded()
			}
		}
		.presentationDetents([.medium, .large])
		.presentationDragIndicator(.visible)
	}

	private var styleSelection: some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach(OfflineVectorMapStyle.allCases) { style in
				Button {
					toggleStyle(style)
				} label: {
					HStack(alignment: .top, spacing: 10) {
						Image(systemName: selectedStyles.contains(style) ? "checkmark.circle.fill" : "circle")
							.foregroundStyle(selectedStyles.contains(style) ? Color.accentColor : Color.secondary)
						VStack(alignment: .leading, spacing: 2) {
							Text(style.displayName)
								.font(.subheadline.weight(.semibold))
								.foregroundStyle(.primary)
							Text(style.detail)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(2)
						}
						Spacer()
					}
					.padding(.vertical, 4)
				}
				.buttonStyle(.plain)
			}
			if selectedStyles.isEmpty {
				Text("Select at least one MapLibre style.")
					.font(.caption)
					.foregroundStyle(.orange)
			}
		}
	}

	private var serverMinimumZoom: Int {
		MapTileServer.openStreetMap.zoomRange.first ?? 0
	}

	private var serverMaximumZoom: Int {
		MapTileServer.openStreetMap.offlineDisplayZoomRange.upperBound
	}

	private func configureDefaultsIfNeeded() {
		mapTileServer = .openStreetMap
		UserDefaults.mapTileServer = .openStreetMap
		useVectorRenderer = true
		UserDefaults.offlineMapUseVectorRenderer = true
		minimumZoom = min(max(minimumZoom, serverMinimumZoom), serverMaximumZoom)
		maximumZoom = min(max(maximumZoom, minimumZoom), serverMaximumZoom)
		if selectedStyles.isEmpty {
			selectedStyles = [selectedVectorMapStyle]
		}
	}

	private func toggleStyle(_ style: OfflineVectorMapStyle) {
		if selectedStyles.contains(style) {
			selectedStyles.remove(style)
		} else {
			selectedStyles.insert(style)
			selectedVectorMapStyle = style
			UserDefaults.offlineVectorMapStyle = style
		}
	}

	private func downloadSelectedArea() {
		guard let selectedRegion, !selectedStyles.isEmpty else { return }
		enableOfflineMaps = true
		UserDefaults.enableOfflineMaps = true
		mapLayer = .offline
		UserDefaults.mapLayer = .offline
		mapTileServer = .openStreetMap
		UserDefaults.mapTileServer = .openStreetMap
		UserDefaults.offlineImportedTileSourceID = ""
		useVectorRenderer = true
		UserDefaults.offlineMapUseVectorRenderer = true
		styleDownloadMessage = ""

		let stylesToCache = OfflineVectorMapStyle.allCases.filter { selectedStyles.contains($0) }
		if let firstStyle = stylesToCache.first {
			selectedVectorMapStyle = firstStyle
			UserDefaults.offlineVectorMapStyle = firstStyle
		}
		let selectedZoomRange = minimumZoom...maximumZoom
		let selectedName = downloadName

		Task {
			var styleCacheFailed = false
			for style in stylesToCache {
				do {
					_ = try await tileManager.downloadVectorStyle(style)
				} catch {
					styleCacheFailed = true
				}
			}
			let downloadedRegion = await tileManager.downloadMapLibreTiles(
				in: selectedRegion,
				styles: stylesToCache,
				zoomRange: selectedZoomRange,
				name: selectedName
			)
			await MainActor.run {
				guard downloadedRegion != nil else {
					styleDownloadMessage = "MapLibre could not download this map area. Check the connection and try again."
					return
				}
				if styleCacheFailed {
					styleDownloadMessage = "Some local style files could not be cached. MapLibre still downloaded the selected map resources."
				}
				downloadName = ""
				isSelecting = false
				dismiss()
			}
		}
	}
}

struct OfflineMapDownloadSelectionOverlay: View {
	static let defaultSelection = CGRect(x: 0.14, y: 0.10, width: 0.72, height: 0.34)

	@Binding var selection: CGRect
	@State private var moveStart: CGRect?
	@State private var resizeStart: CGRect?

	var body: some View {
		GeometryReader { proxy in
			let size = proxy.size
			let selectionRect = rect(for: selection, in: size)

			ZStack(alignment: .topLeading) {
				outsideScrim(selectionRect: selectionRect, size: size)
				selectionCard(selectionRect: selectionRect, size: size)
			}
			.animation(.snappy(duration: 0.12), value: selection)
		}
		.allowsHitTesting(true)
	}

	private func outsideScrim(selectionRect: CGRect, size: CGSize) -> some View {
		ZStack {
			Rectangle()
				.fill(.black.opacity(0.10))
				.frame(width: size.width, height: max(selectionRect.minY, 0))
				.position(x: size.width / 2, y: max(selectionRect.minY, 0) / 2)
			Rectangle()
				.fill(.black.opacity(0.10))
				.frame(width: size.width, height: max(size.height - selectionRect.maxY, 0))
				.position(x: size.width / 2, y: selectionRect.maxY + max(size.height - selectionRect.maxY, 0) / 2)
			Rectangle()
				.fill(.black.opacity(0.10))
				.frame(width: max(selectionRect.minX, 0), height: selectionRect.height)
				.position(x: max(selectionRect.minX, 0) / 2, y: selectionRect.midY)
			Rectangle()
				.fill(.black.opacity(0.10))
				.frame(width: max(size.width - selectionRect.maxX, 0), height: selectionRect.height)
				.position(x: selectionRect.maxX + max(size.width - selectionRect.maxX, 0) / 2, y: selectionRect.midY)
		}
		.allowsHitTesting(false)
	}

	private func selectionCard(selectionRect: CGRect, size: CGSize) -> some View {
		ZStack(alignment: .topLeading) {
			RoundedRectangle(cornerRadius: 16, style: .continuous)
				.fill(Color.accentColor.opacity(0.13))
				.overlay {
					RoundedRectangle(cornerRadius: 16, style: .continuous)
						.strokeBorder(.white.opacity(0.9), lineWidth: 4)
				}
				.overlay {
					RoundedRectangle(cornerRadius: 16, style: .continuous)
						.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
				}
				.frame(width: selectionRect.width, height: selectionRect.height)
				.position(x: selectionRect.midX, y: selectionRect.midY)
				.shadow(color: .black.opacity(0.22), radius: 12, y: 4)
				.gesture(moveGesture(in: size))
				.accessibilityLabel("Offline map download area")
				.accessibilityHint("Drag to move the selected download area.")

			Label("Download area", systemImage: "arrow.down.map")
				.font(.caption.bold())
				.padding(.horizontal, 10)
				.padding(.vertical, 7)
				.background(.ultraThinMaterial, in: Capsule())
				.overlay {
					Capsule()
						.stroke(.white.opacity(0.5), lineWidth: 1)
				}
				.position(
					x: selectionRect.midX,
					y: max(selectionRect.minY - 22, 24)
				)

			Image(systemName: "arrow.up.left.and.arrow.down.right")
				.font(.caption.bold())
				.foregroundStyle(.white)
				.padding(9)
				.background(Color.accentColor, in: Circle())
				.overlay {
					Circle()
						.stroke(.white, lineWidth: 2)
				}
				.shadow(radius: 4)
				.position(x: selectionRect.maxX, y: selectionRect.maxY)
				.gesture(resizeGesture(in: size))
				.accessibilityLabel("Resize offline map download area")
				.accessibilityHint("Drag to resize the selected download area.")
		}
	}

	private func rect(for selection: CGRect, in size: CGSize) -> CGRect {
		let normalized = Self.normalized(selection)
		return CGRect(
			x: normalized.minX * size.width,
			y: normalized.minY * size.height,
			width: normalized.width * size.width,
			height: normalized.height * size.height
		)
	}

	private func moveGesture(in size: CGSize) -> some Gesture {
		DragGesture(minimumDistance: 1)
			.onChanged { value in
				if moveStart == nil {
					moveStart = Self.normalized(selection)
				}
				guard let moveStart else { return }
				let updated = CGRect(
					x: moveStart.minX + value.translation.width / max(size.width, 1),
					y: moveStart.minY + value.translation.height / max(size.height, 1),
					width: moveStart.width,
					height: moveStart.height
				)
				selection = Self.normalized(updated)
			}
			.onEnded { _ in
				moveStart = nil
			}
	}

	private func resizeGesture(in size: CGSize) -> some Gesture {
		DragGesture(minimumDistance: 1)
			.onChanged { value in
				if resizeStart == nil {
					resizeStart = Self.normalized(selection)
				}
				guard let resizeStart else { return }
				let updated = CGRect(
					x: resizeStart.minX,
					y: resizeStart.minY,
					width: resizeStart.width + value.translation.width / max(size.width, 1),
					height: resizeStart.height + value.translation.height / max(size.height, 1)
				)
				selection = Self.normalized(updated)
			}
			.onEnded { _ in
				resizeStart = nil
			}
	}

	private static func normalized(_ selection: CGRect) -> CGRect {
		let width = min(max(selection.width, 0.18), 1)
		let height = min(max(selection.height, 0.16), 1)
		let x = min(max(selection.origin.x, 0), 1 - width)
		let y = min(max(selection.origin.y, 0), 1 - height)
		return CGRect(x: x, y: y, width: width, height: height)
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

#Preview {
	MapSettingsForm(
		traffic: .constant(false),
		pointsOfInterest: .constant(true),
		mapLayer: .constant(.standard),
		meshMap: .constant(true),
		enabledOverlayConfigs: .constant(Set<UUID>()),
		visibleRegion: nil,
		downloadSelection: .constant(OfflineMapDownloadSelectionOverlay.defaultSelection),
		onOpenDownloadMap: {}
	)
}
