//
//  NodeMapSwiftUI.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 9/11/23.
//

import SwiftUI
import CoreLocation
import MapKit

struct NodeMapSwiftUI: View {
	@Environment(\.managedObjectContext) var context
	@EnvironmentObject var bleManager: BLEManager
	/// Parameters
	@ObservedObject var node: NodeInfoEntity
	@State var showUserLocation: Bool = false
	@State var positions: [PositionEntity] = []
	/// Map State User Defaults
	@AppStorage("enableMapTraffic") private var showTraffic: Bool = false
	@AppStorage("enableMapPointsOfInterest") private var showPointsOfInterest: Bool = false
	@AppStorage("mapLayer") private var selectedMapLayer: MapLayer = .standard
	@AppStorage("enableOfflineMaps") private var enableOfflineMaps = false
	// Map Configuration
	@Namespace var mapScope
	@State var mapStyle: MapStyle = MapStyle.standard(elevation: .flat, pointsOfInterest: .all, showsTraffic: true)
	@State var position = MapCameraPosition.automatic
	@State var distance = 10000.0
	@State private var visibleRegion: MKCoordinateRegion?
	@State var scene: MKLookAroundScene?
	@State var isLookingAround = false
	@State var isShowingAltitude = false
	@State var isEditingSettings = false
	@State var isMeshMap = false
	@State private var selectedPosition: PositionEntity?

	@State private var mapRegion = MKCoordinateRegion.init()

	@FetchRequest(sortDescriptors: [NSSortDescriptor(key: "name", ascending: false)],
				  predicate: NSPredicate(
					format: "expire == nil || expire >= %@", Date() as NSDate
				  ), animation: .none)
	private var waypoints: FetchedResults<WaypointEntity>

	var body: some View {
		if node.hasPositions {
			mapContainer
		} else {
			ContentUnavailableView("No Positions", systemImage: "mappin.slash")
		}
	}

	private var mapContainer: some View {
		ZStack {
			MapReader { _ in
				mapLayerView
					.overlay(alignment: .bottom) { lookAroundOverlay }
					.overlay(alignment: .bottom) { altitudeOverlay }
					.sheet(isPresented: $isEditingSettings) { settingsSheet }
					.sheet(item: $selectedPosition) { selection in
						PositionPopover(position: selection, popover: false)
							.padding()
					}
					.onChange(of: node) {
						updateMapForCurrentNode()
					}
					.onAppear {
						UIApplication.shared.isIdleTimerDisabled = true
						restoreAppleMapDefaultIfNeeded()
						applyMapLayer(selectedMapLayer)
						updateMapForCurrentNode()
					}
					.safeAreaInset(edge: .bottom, alignment: .trailing) {
						mapActionButtons
					}
					.onDisappear {
						UIApplication.shared.isIdleTimerDisabled = false
					}
			}
		}
		.navigationBarTitle(String((node.user?.shortName ?? "unknown".localized) + (" \(node.positions?.count ?? 0) points")), displayMode: .inline)
		.navigationBarItems(trailing:
								ZStack {
			ConnectedDevice(
				bluetoothOn: bleManager.isSwitchedOn,
				deviceConnected: bleManager.connectedPeripheral != nil,
				name: (bleManager.connectedPeripheral != nil) ? bleManager.connectedPeripheral.shortName : "?")
		})
	}

	@ViewBuilder
	private var mapLayerView: some View {
		if selectedMapLayer == .offline {
			OfflineNodeMapView(
				node: node,
				showUserLocation: $showUserLocation,
				showTraffic: $showTraffic,
				showPointsOfInterest: $showPointsOfInterest,
				visibleRegion: $visibleRegion,
				selectedPosition: $selectedPosition
			)
		} else {
			swiftUIMap
		}
	}

	private var swiftUIMap: some View {
		Map(position: $position, bounds: MapCameraBounds(minimumDistance: 0, maximumDistance: .infinity), scope: mapScope) {
			NodeMapContent(node: node)
		}
		.mapScope(mapScope)
		.mapStyle(mapStyle)
		.mapControls {
			MapScaleView(scope: mapScope)
				.mapControlVisibility(.visible)
			if showUserLocation {
				MapUserLocationButton(scope: mapScope)
					.mapControlVisibility(.visible)
			}
			MapPitchToggle(scope: mapScope)
				.mapControlVisibility(.visible)
			MapCompass(scope: mapScope)
				.mapControlVisibility(.visible)
		}
		.controlSize(.regular)
		.onMapCameraChange(frequency: .continuous) { context in
			visibleRegion = context.region
		}
	}

	@ViewBuilder
	private var lookAroundOverlay: some View {
		if scene != nil && isLookingAround {
			LookAroundPreview(initialScene: scene)
				.frame(height: UIDevice.current.userInterfaceIdiom == .phone ? 250 : 400)
				.clipShape(RoundedRectangle(cornerRadius: 12))
				.padding(.horizontal, 20)
		}
	}

	@ViewBuilder
	private var altitudeOverlay: some View {
		if !isLookingAround && isShowingAltitude {
			PositionAltitudeChart(node: node)
				.frame(height: UIDevice.current.userInterfaceIdiom == .phone ? 250 : 400)
				.clipShape(RoundedRectangle(cornerRadius: 12))
				.padding(.horizontal, 20)
		}
	}

	private var settingsSheet: some View {
		MapSettingsForm(
			traffic: $showTraffic,
			pointsOfInterest: $showPointsOfInterest,
			mapLayer: $selectedMapLayer,
			meshMap: $isMeshMap,
			visibleRegion: visibleRegion
		)
		.onChange(of: selectedMapLayer) { _, newMapLayer in
			applyMapLayer(newMapLayer)
		}
	}

	private var mapActionButtons: some View {
		HStack {
			Button(action: {
				withAnimation {
					isEditingSettings.toggle()
				}
			}) {
				Image(systemName: isEditingSettings ? "info.circle.fill" : "info.circle")
					.padding(.vertical, 5)
			}
			.tint(Color(UIColor.secondarySystemBackground))
			.foregroundColor(.accentColor)
			.buttonStyle(.borderedProminent)

			if scene != nil {
				Button(action: {
					if isShowingAltitude {
						isShowingAltitude = false
					}
					isLookingAround.toggle()
				}) {
					Image(systemName: isLookingAround ? "binoculars.fill" : "binoculars")
						.padding(.vertical, 5)
				}
				.tint(Color(UIColor.secondarySystemBackground))
				.foregroundColor(.accentColor)
				.buttonStyle(.borderedProminent)
			}

			if node.positions?.count ?? 0 > 1 {
				Button(action: {
					if isLookingAround {
						isLookingAround = false
					}
					isShowingAltitude.toggle()
				}) {
					Image(systemName: isShowingAltitude ? "mountain.2.fill" : "mountain.2")
						.padding(.vertical, 5)
				}
				.tint(Color(UIColor.secondarySystemBackground))
				.foregroundColor(.accentColor)
				.buttonStyle(.borderedProminent)
			}
		}
		.controlSize(.regular)
		.padding(5)
	}

	private func applyMapLayer(_ mapLayer: MapLayer) {
		UserDefaults.mapLayer = mapLayer
		switch mapLayer {
		case .standard:
			mapStyle = MapStyle.standard(elevation: .flat, pointsOfInterest: showPointsOfInterest ? .all : .excludingAll, showsTraffic: showTraffic)
		case .hybrid:
			mapStyle = MapStyle.hybrid(elevation: .flat, pointsOfInterest: showPointsOfInterest ? .all : .excludingAll, showsTraffic: showTraffic)
		case .satellite:
			mapStyle = MapStyle.imagery(elevation: .flat)
		case .offline:
			enableOfflineMaps = true
		}
	}

	private func restoreAppleMapDefaultIfNeeded() {
		guard selectedMapLayer == .offline else { return }
		selectedMapLayer = .standard
		UserDefaults.mapLayer = .standard
	}

	private func updateMapForCurrentNode() {
		isLookingAround = false
		isShowingAltitude = false

		if node.positions?.count ?? 0 > 1 {
			position = .automatic
		} else if let coordinate = (node.positions?.lastObject as? PositionEntity)?.coordinate {
			position = .camera(MapCamera(centerCoordinate: coordinate, distance: distance, heading: 0, pitch: 0))
		}

		if let coordinate = (node.positions?.lastObject as? PositionEntity)?.coordinate {
			Task {
				scene = try? await fetchScene(for: coordinate)
			}
		}
	}

	/// Get the look around scene
	private func fetchScene(for coordinate: CLLocationCoordinate2D) async throws -> MKLookAroundScene? {
		let lookAroundScene = MKLookAroundSceneRequest(coordinate: coordinate)
		return try await lookAroundScene.scene
	}
}
