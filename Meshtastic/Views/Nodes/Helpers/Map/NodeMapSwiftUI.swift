//
//  NodeMapSwiftUI.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 9/11/23.
//

import SwiftUI
import CoreLocation
import MapKit
import MapCache

// MARK: - MapCache Manager (Singleton)
@MainActor
class MapCacheManager: ObservableObject {
	static let shared = MapCacheManager()
	
	@Published var cacheSize: Int64 = 0
	@Published var isCalculating: Bool = false
	
	private var mapCache: MapCache?
	
	private init() {
		setupMapCache()
	}
	
	func setupMapCache() {
		var config = MapCacheConfig(withUrlTemplate: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png")
		config.subdomains = ["a", "b", "c"]
		config.cacheName = "MeshtasticOfflineCache"
		config.maximumZ = 19
		config.overZoomMaximumZ = true
		config.capacity = 1000 * 1024 * 1024 // 1 GB cache
		
		mapCache = MapCache(withConfig: config)
		calculateCacheSize()
	}
	
	func getMapCache() -> MapCache? {
		return mapCache
	}
	
	func calculateCacheSize() {
		guard let cache = mapCache else { return }
		isCalculating = true
		let size = cache.calculateDiskSize()
		cacheSize = Int64(size)
		isCalculating = false
	}
	
	func clearCache(completion: @escaping () -> Void) {
		guard let cache = mapCache else {
			completion()
			return
		}
		
		cache.clear {
			self.calculateCacheSize()
			completion()
		}
	}
	
	func disableCache() {
		mapCache = nil
		cacheSize = 0
	}
	
	func enableCache() {
		if mapCache == nil {
			setupMapCache()
		}
	}
	
	func isCacheEnabled() -> Bool {
		return mapCache != nil
	}
}

struct NodeMapSwiftUI: View {
	@Environment(\.managedObjectContext) var context
	@EnvironmentObject var accessoryManager: AccessoryManager
	@StateObject private var mapCacheManager = MapCacheManager.shared
	
	/// Parameters
	@ObservedObject var node: NodeInfoEntity
	@State var showUserLocation: Bool = false
	@State var positions: [PositionEntity] = []
	/// Map State User Defaults
	@AppStorage("enableMapTraffic") private var showTraffic: Bool = false
	@AppStorage("enableMapPointsOfInterest") private var showPointsOfInterest: Bool = false
	@AppStorage("mapLayer") private var selectedMapLayer: MapLayer = .hybrid
	@AppStorage("enableMapCache") private var enableMapCache: Bool = true
	
	// Map Configuration
	@Namespace var mapScope
	@State var position = MapCameraPosition.automatic
	@State var distance = 10000.0
	@State var scene: MKLookAroundScene?
	@State var isLookingAround = false
	@State var isShowingAltitude = false
	@State var isEditingSettings = false
	@State var isMeshMap = false
	@State var enabledOverlayConfigs: Set<UUID> = Set()

	@State private var mapRegion = MKCoordinateRegion.init()

	@FetchRequest(sortDescriptors: [NSSortDescriptor(key: "name", ascending: false)],
				  predicate: NSPredicate(
					format: "expire == nil || expire >= %@", Date() as NSDate
				  ), animation: .none)
	private var waypoints: FetchedResults<WaypointEntity>

	var body: some View {
		if node.hasPositions {
			mapWithNavigation
		} else {
			ContentUnavailableView("No Positions", systemImage: "mappin.slash")
		}
	}

	private var mapWithNavigation: some View {
		ZStack {
			MapReader { _ in
				configuredMap
			}
		}
		.navigationBarTitle(String((node.user?.shortName ?? "Unknown".localized) + (" \(node.positions?.count ?? 0) points")), displayMode: .inline)
		.navigationBarItems(trailing:
			ZStack {
				ConnectedDevice(
					deviceConnected: accessoryManager.isConnected,
					name: accessoryManager.activeConnection?.device.shortName ?? "?")
			})
	}

	private var configuredMap: some View {
		MapViewRepresentable(
			position: $position,
			node: node,
			showUserLocation: showUserLocation,
			showTraffic: showTraffic,
			showPointsOfInterest: showPointsOfInterest,
			mapCache: enableMapCache ? mapCacheManager.getMapCache() : nil,
			selectedMapLayer: selectedMapLayer
		)
		.ignoresSafeArea()
		.overlay(alignment: .bottom) {
			lookAroundView
		}
		.overlay(alignment: .bottom) {
			altitudeView
		}
		.sheet(isPresented: $isEditingSettings) {
			MapSettingsForm(
				traffic: $showTraffic,
				pointsOfInterest: $showPointsOfInterest,
				mapLayer: $selectedMapLayer,
				meshMap: $isMeshMap,
				enabledOverlayConfigs: $enabledOverlayConfigs,
				enableMapCache: $enableMapCache
			)
		}
		.onChange(of: selectedMapLayer) { _, _ in
			// Update handled in representable
		}
		.onChange(of: enableMapCache) { _, isEnabled in
			if isEnabled {
				mapCacheManager.enableCache()
			} else {
				mapCacheManager.disableCache()
			}
		}
		.onChange(of: node) {
			handleNodeChange()
		}
		.onAppear {
			handleAppear()
		}
		.safeAreaInset(edge: .bottom, alignment: .trailing) {
			controlButtons
		}
		.onDisappear {
			UIApplication.shared.isIdleTimerDisabled = false
		}
	}

	private var lookAroundView: some View {
		Group {
			if scene != nil && isLookingAround {
				LookAroundPreview(initialScene: scene)
					.frame(height: UIDevice.current.userInterfaceIdiom == .phone ? 250 : 400)
					.clipShape(RoundedRectangle(cornerRadius: 12))
					.padding(.horizontal, 20)
			}
		}
	}

	private var altitudeView: some View {
		Group {
			if !isLookingAround && isShowingAltitude {
				PositionAltitudeChart(node: node)
					.frame(height: UIDevice.current.userInterfaceIdiom == .phone ? 250 : 400)
					.clipShape(RoundedRectangle(cornerRadius: 12))
					.padding(.horizontal, 20)
			}
		}
	}

	private var controlButtons: some View {
		HStack {
			Button(action: {
				withAnimation {
					isEditingSettings = !isEditingSettings
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
					isLookingAround = !isLookingAround
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
					isShowingAltitude = !isShowingAltitude
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

	private func handleNodeChange() {
		isLookingAround = false
		isShowingAltitude = false
		let newMostRecent = node.positions?.lastObject as? PositionEntity
		if node.positions?.count ?? 0 > 1 {
			position = .automatic
		} else if let mrCoord = newMostRecent?.coordinate {
			position = .camera(MapCamera(centerCoordinate: mrCoord, distance: distance, heading: 0, pitch: 0))
		}
		if let newMostRecent {
			Task {
				scene = try? await fetchScene(for: newMostRecent.coordinate)
			}
		}
	}

	private func handleAppear() {
		UIApplication.shared.isIdleTimerDisabled = true
		
		// Ensure cache is setup based on user preference
		if enableMapCache {
			mapCacheManager.enableCache()
		}
		
		let mostRecent = node.positions?.lastObject as? PositionEntity
		if node.positions?.count ?? 0 > 1 {
			position = .automatic
		} else if let mrCoord = mostRecent?.coordinate {
			position = .camera(MapCamera(centerCoordinate: mrCoord, distance: distance, heading: 0, pitch: 0))
		}
		if scene == nil, let mrCoord = mostRecent?.coordinate {
			Task {
				scene = try? await fetchScene(for: mrCoord)
			}
		}
	}
	
	/// Get the look around scene
	private func fetchScene(for coordinate: CLLocationCoordinate2D) async throws -> MKLookAroundScene? {
		let lookAroundScene = MKLookAroundSceneRequest(coordinate: coordinate)
		return try await lookAroundScene.scene
	}
}

// MARK: - MapViewRepresentable for MapCache Integration
struct MapViewRepresentable: UIViewRepresentable {
	@Binding var position: MapCameraPosition
	let node: NodeInfoEntity
	let showUserLocation: Bool
	let showTraffic: Bool
	let showPointsOfInterest: Bool
	let mapCache: MapCache?
	let selectedMapLayer: MapLayer
	
	func makeUIView(context: Context) -> MKMapView {
		let mapView = MKMapView()
		mapView.delegate = context.coordinator
		mapView.showsUserLocation = showUserLocation
		
		// Apply MapCache if enabled
		if let cache = mapCache {
			mapView.useCache(cache)
			// Set canReplaceMapContent to true to hide underlying Apple maps
			for overlay in mapView.overlays {
				if let tileOverlay = overlay as? MKTileOverlay {
					tileOverlay.canReplaceMapContent = true
				}
			}
		}
		
		return mapView
	}
	
	func updateUIView(_ mapView: MKMapView, context: Context) {
		// Update user location visibility
		mapView.showsUserLocation = showUserLocation
		
		// Set map type
		var mapType: MKMapType = .standard
		if mapCache == nil {
			switch selectedMapLayer {
			case .standard:
				mapType = .standard
			case .hybrid:
				mapType = .hybrid
			case .satellite:
				mapType = .satellite
			case .offline:
				mapType = .standard
			}
		} else {
			mapType = .standard // Use standard for cached tiles
		}
		mapView.mapType = mapType
		
		// Set traffic and POI
		mapView.showsTraffic = showTraffic
		mapView.pointOfInterestFilter = showPointsOfInterest ? .includingAll : .excludingAll
		
		// Handle cache overlay if changed
		if mapCache == nil {
			mapView.removeOverlays(mapView.overlays)
		} else if mapView.overlays.isEmpty {
			// If cache enabled but no overlay, add it
			mapView.useCache(mapCache!)
			for overlay in mapView.overlays {
				if let tileOverlay = overlay as? MKTileOverlay {
					tileOverlay.canReplaceMapContent = true
				}
			}
		}
		
		// Add annotations for all positions
		mapView.removeAnnotations(mapView.annotations)
		let positions = node.positions?.array as? [PositionEntity] ?? []
		for positionEntity in positions {
			let annotation = MKPointAnnotation()
			annotation.coordinate = positionEntity.coordinate
			annotation.title = node.user?.shortName ?? "Unknown"
			mapView.addAnnotation(annotation)
		}
		
		// Update map position
		if positions.isEmpty {
			return
		}
		// Update map position
		guard !positions.isEmpty else { return }

		if position == .automatic {
			if !mapView.annotations.isEmpty {
				mapView.showAnnotations(mapView.annotations, animated: true)
			}
		} else if let camera = position.camera {
			mapView.setCamera(camera, animated: true)
		} else if let region = position.region {
			mapView.setRegion(region, animated: true)
		} else if let mostRecent = positions.last {
			let coordinate = mostRecent.coordinate
			let region = MKCoordinateRegion(
				center: coordinate,
				span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
			)
			mapView.setRegion(region, animated: true)
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}
	
	class Coordinator: NSObject, MKMapViewDelegate {
		var parent: MapViewRepresentable
		
		init(_ parent: MapViewRepresentable) {
			self.parent = parent
		}
		
		func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
			return mapView.mapCacheRenderer(forOverlay: overlay)
		}
		
		func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
			guard !(annotation is MKUserLocation) else { return nil }
			
			let identifier = "NodeAnnotation"
			var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
			
			if annotationView == nil {
				annotationView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
				annotationView?.canShowCallout = true
			} else {
				annotationView?.annotation = annotation
			}
			
			return annotationView
		}
	}
}
