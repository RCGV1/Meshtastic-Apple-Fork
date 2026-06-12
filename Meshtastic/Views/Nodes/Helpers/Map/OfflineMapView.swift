//
//  OfflineMapView.swift
//  Meshtastic
//
//  Created by Codex on 6/4/26.
//

import CoreLocation
import MapLibre
import MapKit
import Network
import SwiftUI
import UIKit

private let nativeTileSize: CGFloat = 256.0

struct SlippyMapProjection {
	static let maximumLatitude = 85.051_128_78

	static func worldSize(zoom: Int) -> CGFloat {
		worldSize(zoomLevel: Double(zoom))
	}

	static func worldSize(zoomLevel: Double) -> CGFloat {
		nativeTileSize * pow(2, CGFloat(zoomLevel))
	}

	static func pixel(for coordinate: CLLocationCoordinate2D, zoom: Int) -> CGPoint {
		pixel(for: coordinate, zoomLevel: Double(zoom))
	}

	static func pixel(for coordinate: CLLocationCoordinate2D, zoomLevel: Double) -> CGPoint {
		let latitude = min(max(coordinate.latitude, -maximumLatitude), maximumLatitude)
		let longitude = normalizedLongitude(coordinate.longitude)
		let latitudeRadians = latitude * .pi / 180
		let size = worldSize(zoomLevel: zoomLevel)
		let x = CGFloat((longitude + 180) / 360) * size
		let y = CGFloat((1 - log(tan(latitudeRadians) + 1 / cos(latitudeRadians)) / .pi) / 2) * size
		return CGPoint(x: x, y: y)
	}

	static func coordinate(for pixel: CGPoint, zoom: Int) -> CLLocationCoordinate2D {
		coordinate(for: pixel, zoomLevel: Double(zoom))
	}

	static func coordinate(for pixel: CGPoint, zoomLevel: Double) -> CLLocationCoordinate2D {
		let size = worldSize(zoomLevel: zoomLevel)
		let wrappedX = pixel.x.truncatingRemainder(dividingBy: size)
		let normalizedX = wrappedX < 0 ? wrappedX + size : wrappedX
		let longitude = Double(normalizedX / size) * 360 - 180
		let mercatorY = .pi * (1 - 2 * Double(pixel.y) / Double(size))
		let latitude = atan(sinh(mercatorY)) * 180 / .pi
		return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
	}

	static func wrappedTileX(_ x: Int, zoom: Int) -> Int {
		let limit = 1 << zoom
		let remainder = x % limit
		return remainder < 0 ? remainder + limit : remainder
	}

	static func clampedTileY(_ y: Int, zoom: Int) -> Int {
		let maxY = (1 << zoom) - 1
		return min(max(y, 0), maxY)
	}

	static func normalizedLongitude(_ longitude: CLLocationDegrees) -> CLLocationDegrees {
		var normalized = longitude
		while normalized < -180 { normalized += 360 }
		while normalized > 180 { normalized -= 360 }
		return normalized
	}

	static func visibleRegion(center: CLLocationCoordinate2D, zoom: Int, size: CGSize, dragOffset: CGSize = .zero) -> MKCoordinateRegion {
		visibleRegion(center: center, zoomLevel: Double(zoom), size: size, dragOffset: dragOffset)
	}

	static func visibleRegion(center: CLLocationCoordinate2D, zoomLevel: Double, size: CGSize, dragOffset: CGSize = .zero) -> MKCoordinateRegion {
		let topLeftPixel = topLeftPixel(center: center, zoomLevel: zoomLevel, size: size, dragOffset: dragOffset)
		let bottomRightPixel = CGPoint(x: topLeftPixel.x + size.width, y: topLeftPixel.y + size.height)
		let topLeft = coordinate(for: topLeftPixel, zoomLevel: zoomLevel)
		let bottomRight = coordinate(for: bottomRightPixel, zoomLevel: zoomLevel)
		let latitudeDelta = abs(topLeft.latitude - bottomRight.latitude)
		var longitudeDelta = abs(bottomRight.longitude - topLeft.longitude)
		if longitudeDelta > 180 {
			longitudeDelta = 360 - longitudeDelta
		}
		return MKCoordinateRegion(
			center: center,
			span: MKCoordinateSpan(
				latitudeDelta: max(latitudeDelta, 0.000_001),
				longitudeDelta: max(longitudeDelta, 0.000_001)
			)
		)
	}

	static func zoomLevel(for region: MKCoordinateRegion, size: CGSize) -> Double {
		guard size.width > 0, size.height > 0 else { return 13 }
		let longitudeDelta = min(max(region.span.longitudeDelta, 0.000_001), 360)
		let zoomX = log2(Double(size.width) * 360 / (Double(nativeTileSize) * longitudeDelta))

		let north = min(max(region.center.latitude + region.span.latitudeDelta / 2, -maximumLatitude), maximumLatitude)
		let south = min(max(region.center.latitude - region.span.latitudeDelta / 2, -maximumLatitude), maximumLatitude)
		let top = pixel(for: CLLocationCoordinate2D(latitude: north, longitude: region.center.longitude), zoomLevel: 0)
		let bottom = pixel(for: CLLocationCoordinate2D(latitude: south, longitude: region.center.longitude), zoomLevel: 0)
		let latitudePixelDelta = max(abs(bottom.y - top.y), 0.000_001)
		let zoomY = log2(Double(size.height) / Double(latitudePixelDelta))

		return min(max(min(zoomX, zoomY), 0), 22)
	}

	static func bestZoom(toFit coordinates: [CLLocationCoordinate2D], size: CGSize, padding: CGFloat = 80, maximumZoom: Int = 18) -> Int {
		guard coordinates.count > 1, size.width > 0, size.height > 0 else {
			return 13
		}

		let usableWidth = max(Double(size.width - padding), 128)
		let usableHeight = max(Double(size.height - padding), 128)
		for zoom in stride(from: maximumZoom, through: 3, by: -1) {
			let pixels = coordinates.map { pixel(for: $0, zoom: zoom) }
			guard let minX = pixels.map(\.x).min(),
				  let maxX = pixels.map(\.x).max(),
				  let minY = pixels.map(\.y).min(),
				  let maxY = pixels.map(\.y).max() else {
				continue
			}
			if Double(maxX - minX) <= usableWidth, Double(maxY - minY) <= usableHeight {
				return zoom
			}
		}
		return 3
	}

	static func center(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
		guard !coordinates.isEmpty else { return nil }
		let latitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
		let longitude = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
		return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
	}

	static func topLeftPixel(center: CLLocationCoordinate2D, zoom: Int, size: CGSize, dragOffset: CGSize = .zero) -> CGPoint {
		topLeftPixel(center: center, zoomLevel: Double(zoom), size: size, dragOffset: dragOffset)
	}

	static func topLeftPixel(center: CLLocationCoordinate2D, zoomLevel: Double, size: CGSize, dragOffset: CGSize = .zero) -> CGPoint {
		let centerPixel = pixel(for: center, zoomLevel: zoomLevel)
		return CGPoint(
			x: centerPixel.x - size.width / 2 - dragOffset.width,
			y: centerPixel.y - size.height / 2 - dragOffset.height
		)
	}
}

private struct SlippyMapRenderContext {
	let centerCoordinate: CLLocationCoordinate2D
	let zoomLevel: Double
	let size: CGSize
	let dragOffset: CGSize

	private var topLeftPixel: CGPoint {
		SlippyMapProjection.topLeftPixel(center: centerCoordinate, zoomLevel: zoomLevel, size: size, dragOffset: dragOffset)
	}

	func point(for coordinate: CLLocationCoordinate2D) -> CGPoint {
		let pixel = SlippyMapProjection.pixel(for: coordinate, zoomLevel: zoomLevel)
		let topLeftPixel = topLeftPixel
		let worldSize = SlippyMapProjection.worldSize(zoomLevel: zoomLevel)
		var x = pixel.x - topLeftPixel.x
		if x < -(worldSize / 2) {
			x += worldSize
		} else if x > worldSize / 2 {
			x -= worldSize
		}
		return CGPoint(x: x, y: pixel.y - topLeftPixel.y)
	}

	func coordinate(for point: CGPoint) -> CLLocationCoordinate2D {
		let topLeftPixel = topLeftPixel
		return SlippyMapProjection.coordinate(
			for: CGPoint(x: topLeftPixel.x + point.x, y: topLeftPixel.y + point.y),
			zoomLevel: zoomLevel
		)
	}

	func screenRadius(center: CLLocationCoordinate2D, meters: CLLocationDistance) -> CGFloat {
		let latitudeRadians = center.latitude * .pi / 180
		let longitudeOffset = meters / max(111_320 * cos(latitudeRadians), 1)
		let edge = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + longitudeOffset)
		return abs(point(for: edge).x - point(for: center).x)
	}
}

private struct NativeDisplayedTile: Identifiable, Hashable {
	let displayX: Int
	let y: Int
	let z: Int
	let sourceX: Int
	let center: CGPoint
	let size: CGFloat

	var id: String {
		"\(z)-\(displayX)-\(y)-\(sourceX)"
	}

	var tile: OfflineMapTile {
		OfflineMapTile(x: sourceX, y: y, z: z)
	}
}

private struct NativeMapPolyline {
	let coordinates: [CLLocationCoordinate2D]
	let color: Color
	let lineWidth: CGFloat
	let dashed: Bool
}

private struct NativeMapPolygon {
	let coordinates: [CLLocationCoordinate2D]
	let stroke: Color
	let fill: Color
	let lineWidth: CGFloat
}

private struct NativeMapStyledFeature {
	let feature: GeoJSONStyledFeature
	let overlay: MKOverlay
}

private struct NativeMapCircle {
	let center: CLLocationCoordinate2D
	let radius: CLLocationDistance
	let stroke: Color
	let fill: Color
	let lineWidth: CGFloat
}

private extension PositionEntity {
	var offlineMapCoordinate: CLLocationCoordinate2D {
		nodeCoordinate ?? LocationsHandler.DefaultLocation
	}

	var offlineMapTitle: String? {
		nodePosition?.user?.longName ?? nodePosition?.user?.shortName ?? "Unknown".localized
	}

	var offlineMapSubtitle: String? {
		time?.formatted(date: .numeric, time: .shortened)
	}
}

private extension WaypointEntity {
	var offlineMapCoordinate: CLLocationCoordinate2D {
		waypointCoordinate ?? LocationsHandler.DefaultLocation
	}

	var offlineMapTitle: String? {
		mapTitle
	}

	var offlineMapSubtitle: String? {
		mapSubtitle
	}
}

enum OfflineMapAnnotationStyle {
	case mesh
	case node

	var identityValue: Int {
		switch self {
		case .mesh:
			return 1
		case .node:
			return 2
		}
	}
}

struct OfflineMapView: View {
	let positions: [PositionEntity]
	let waypoints: [WaypointEntity]
	let routes: [RouteEntity]
	let showNodeHistory: Bool
	let showRouteLines: Bool
	let showConvexHull: Bool
	let showWaypoints: Bool
	@Binding var showUserLocation: Bool
	@Binding var showUserHeading: Bool
	let showTraffic: Bool
	let showPointsOfInterest: Bool
	let tileServer: MapTileServer
	let mapTilesAboveLabels: Bool
	let importedTileSourceID: String
	let use3DElevation: Bool
	let importedMapContent: OfflineMapImportedContent
	let annotationStyle: OfflineMapAnnotationStyle
	let centerOnUserLocationRequest: Int
	@Binding var visibleRegion: MKCoordinateRegion?
	@Binding var selectedPosition: PositionEntity?
	@Binding var selectedWaypoint: WaypointEntity?
	var onLongPress: ((CLLocationCoordinate2D) -> Void)?

	@ObservedObject private var locationsHandler = LocationsHandler.shared
	@State private var centerCoordinate = LocationsHandler.DefaultLocation
	@State private var zoom = 13
	@State private var cameraZoomLevel = 13.0
	@State private var dragOffset: CGSize = .zero
	@State private var dragGestureStartCenter: CLLocationCoordinate2D?
	@State private var didSetInitialCamera = false
	@State private var userCoordinate: CLLocationCoordinate2D?
	@State private var pendingUserLocationCenter = false
	@State private var zoomGestureStartZoom: Int?
	@State private var zoomGestureStartZoomLevel: Double?
	@State private var resetMapHeadingRequest = 0
	@State private var cameraSyncRequest = 0
	@State private var is3DMode = false
	@AppStorage("offlineMapUseVectorRenderer") private var useVectorRenderer = true
	@AppStorage("offlineVectorMapStyle") private var vectorMapStyle: OfflineVectorMapStyle = .liberty

	private var effectiveTileServer: MapTileServer {
		tileServer.normalizedOfflineDownloadSource
	}

	private var baseBackgroundColor: Color {
		usesNativeMapLibreRenderer ? .clear : Color(uiColor: .systemBackground)
	}

	private var nativeMapLibreStyleURL: URL? {
		guard useVectorRenderer,
			  importedTileSourceID.isEmpty,
			  effectiveTileServer.supportsVectorOfflineRendering else {
			return nil
		}
		return OfflineTileManager.shared.vectorStyleURL(for: vectorMapStyle)
	}

	private var usesNativeMapLibreRenderer: Bool {
		nativeMapLibreStyleURL != nil
	}

	private var visiblePositions: [PositionEntity] {
		if showNodeHistory {
			return positions
		}
		return positions.filter { $0.latest }
	}

	var body: some View {
		GeometryReader { proxy in
			let size = proxy.size
			let renderContext = SlippyMapRenderContext(
				centerCoordinate: centerCoordinate,
				zoomLevel: usesNativeMapLibreRenderer ? cameraZoomLevel : Double(zoom),
				size: size,
				dragOffset: dragOffset
			)

			ZStack {
				baseBackgroundColor
				tileLayer(size: size)
				if !usesNativeMapLibreRenderer {
					NativeMapOverlayCanvas(
						polylines: polylines,
						polygons: polygons,
						circles: circles,
						renderContext: renderContext
					)
					annotationLayer(renderContext: renderContext)
				}
				mapControlsOverlay
				offlineMapControlsOverlay(size: size)
			}
			.clipped()
			.contentShape(Rectangle())
			.onAppear {
				initializeCameraIfNeeded(size: size)
				refreshUserCoordinate()
				publishVisibleRegion(size: size)
			}
			.onChange(of: centerOnUserLocationRequest) { _, _ in
				centerOnPhoneLocation(size: size)
			}
			.onChange(of: locationsHandler.latestLocation?.timestamp) { _, _ in
				completePendingUserLocationCenterIfNeeded(size: size)
			}
			.gesture(dragGesture(size: size), including: usesNativeMapLibreRenderer ? .none : .all)
			.simultaneousGesture(zoomGesture(size: size), including: usesNativeMapLibreRenderer ? .none : .all)
			.simultaneousGesture(longPressGesture(renderContext: renderContext), including: usesNativeMapLibreRenderer ? .none : .all)
			.onTapGesture(count: 2) {
				if !usesNativeMapLibreRenderer {
					zoomIn(size: size)
				}
			}
			.accessibilityIdentifier("native-osm-map")
		}
	}

	@ViewBuilder
	private func tileLayer(size: CGSize) -> some View {
		if let styleURL = nativeMapLibreStyleURL {
			MapLibreVectorOSMView(
				centerCoordinate: $centerCoordinate,
				zoom: $zoom,
				zoomLevel: $cameraZoomLevel,
				styleURL: styleURL,
				allowsInteraction: true,
				showUserLocation: showUserLocation,
				showUserHeading: showUserHeading,
				is3DMode: is3DMode,
				resetMapHeadingRequest: resetMapHeadingRequest,
				cameraSyncRequest: cameraSyncRequest,
				positions: visiblePositions,
				waypoints: showWaypoints ? waypoints : [],
				importedPoints: importedPointAnnotations,
				userCoordinate: showUserLocation ? userCoordinate : nil,
				annotationStyle: annotationStyle,
				polylines: polylines,
				polygons: polygons,
				circles: circles,
				minimumZoom: Double(effectiveTileServer.offlineDisplayZoomRange.lowerBound),
				maximumZoom: Double(effectiveTileServer.offlineDisplayZoomRange.upperBound),
				selectedPosition: $selectedPosition,
				selectedWaypoint: $selectedWaypoint,
				onCameraChange: { center, zoomLevel in
					publishVisibleRegion(center: center, zoomLevel: zoomLevel, size: size)
				},
				onLongPress: onLongPress
			)
		} else {
			ZStack {
				ForEach(visibleTiles(size: size)) { displayedTile in
					NativeOSMTileView(
						tile: displayedTile.tile,
						server: effectiveTileServer,
						importedTileSourceID: importedTileSourceID,
						allowsNetworkLoad: importedTileSourceID.isEmpty
					)
					.frame(width: displayedTile.size, height: displayedTile.size)
					.position(displayedTile.center)
				}
			}
		}
	}

	private func mapKitAnnotationOverlay(size: CGSize, showsStyledOverlays: Bool = true) -> some View {
		MapKitOfflineAnnotationOverlayView(
			centerCoordinate: $centerCoordinate,
			zoom: $zoom,
			zoomLevel: $cameraZoomLevel,
			positions: visiblePositions,
			waypoints: showWaypoints ? waypoints : [],
			importedPoints: importedPointAnnotations,
			userCoordinate: showUserLocation ? userCoordinate : nil,
			annotationStyle: annotationStyle,
			polylines: polylines,
			polygons: polygons,
			circles: circles,
			showsStyledOverlays: showsStyledOverlays,
			minimumZoom: Double(effectiveTileServer.offlineDisplayZoomRange.lowerBound),
			maximumZoom: Double(effectiveTileServer.offlineDisplayZoomRange.upperBound),
			selectedPosition: $selectedPosition,
			selectedWaypoint: $selectedWaypoint,
			onCameraChange: { center, zoomLevel in
				publishVisibleRegion(center: center, zoomLevel: zoomLevel, size: size)
			},
			onLongPress: onLongPress
		)
	}

	private func annotationLayer(renderContext: SlippyMapRenderContext) -> some View {
		ZStack {
			ForEach(visiblePositions, id: \.id) { position in
				OfflinePositionAnnotation(position: position, style: annotationStyle)
					.frame(width: position.latest ? 64 : 22, height: position.latest ? 64 : 22)
					.position(renderContext.point(for: position.offlineMapCoordinate))
					.onTapGesture {
						selectedPosition = selectedPosition == position ? nil : position
					}
			}

			if showWaypoints {
				ForEach(waypoints, id: \.persistentModelID) { waypoint in
					OfflineWaypointAnnotation(waypoint: waypoint)
						.frame(width: 44, height: 44)
						.position(renderContext.point(for: waypoint.offlineMapCoordinate))
						.onTapGesture {
							selectedWaypoint = selectedWaypoint == waypoint ? nil : waypoint
						}
				}
			}

			ForEach(importedPointAnnotations, id: \.id) { importedPoint in
				OfflineImportedPointView(title: importedPoint.title)
					.position(renderContext.point(for: importedPoint.coordinate))
			}

			if showUserLocation, let userCoordinate {
				UserLocationAnnotation()
					.position(renderContext.point(for: userCoordinate))
			}
		}
	}

	private var mapControlsOverlay: some View {
		VStack {
			Spacer()
			HStack {
				Link(destination: effectiveTileServer.attributionURL) {
					Text(effectiveTileServer.shortAttribution)
						.font(.caption2)
						.padding(.horizontal, 8)
						.padding(.vertical, 5)
						.background(.thinMaterial, in: Capsule())
				}
				.foregroundStyle(.secondary)
				Spacer()
			}
			.padding(.leading, usesNativeMapLibreRenderer ? 102 : 10)
			.padding(.trailing, 10)
			.padding(.bottom, 76)
		}
	}

	private func offlineMapControlsOverlay(size: CGSize) -> some View {
		VStack {
			HStack {
				Spacer()
				VStack(spacing: 8) {
					MapKitStyleLocationButton(trackingState: offlineLocationTrackingState) {
						cycleOfflineLocationTracking(size: size)
					}
					MapKitStyleCompassButton {
						showUserHeading = false
						resetMapHeadingRequest += 1
					}
					MapKitStyle3DButton(isActive: is3DMode) {
						is3DMode.toggle()
					}
				}
				.padding(6)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				.shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 2)
			}
			Spacer()
		}
		.padding(.top, 104)
		.padding(.trailing, 10)
	}

	private var offlineLocationTrackingState: OfflineLocationTrackingState {
		if showUserLocation && showUserHeading {
			return .heading
		}
		if showUserLocation {
			return .centered
		}
		return .none
	}

	private func cycleOfflineLocationTracking(size: CGSize) {
		switch offlineLocationTrackingState {
		case .none:
			showUserLocation = true
			showUserHeading = false
			centerOnPhoneLocation(size: size)
		case .centered:
			showUserLocation = true
			showUserHeading = true
			centerOnPhoneLocation(size: size)
		case .heading:
			showUserLocation = true
			showUserHeading = false
			centerOnPhoneLocation(size: size)
		}
	}

	private var polylines: [NativeMapPolyline] {
		var lines: [NativeMapPolyline] = []

		if showRouteLines {
			let latestPositions = positions.filter { $0.latest }
			for position in latestPositions {
				guard let node = position.nodePosition,
					  node.favorite else {
					continue
				}
				let nodePositions = node.positions.sorted { ($0.time ?? .distantPast) < ($1.time ?? .distantPast) }
				let coordinates = nodePositions.compactMap(\.nodeCoordinate)
				guard coordinates.count > 1 else { continue }
				lines.append(
					NativeMapPolyline(
						coordinates: coordinates,
						color: Color(uiColor: UIColor(hex: UInt32(node.num)).lighter()),
						lineWidth: 4,
						dashed: true
					)
				)
			}
		}

		for route in routes {
			let locations = route.locations.sorted { $0.id < $1.id }
			let coordinates = locations.compactMap(\.locationCoordinate)
			guard coordinates.count > 1 else { continue }
			lines.append(
				NativeMapPolyline(
					coordinates: coordinates,
					color: Color(uiColor: UIColor(hex: UInt32(route.color))),
					lineWidth: 3,
					dashed: false
				)
			)
		}

		lines.append(contentsOf: importedMapContent.overlays.flatMap(Self.importedPolylines))
		lines.append(contentsOf: styledImportedFeatures.flatMap(Self.styledFeaturePolylines))
		return lines
	}

	private var polygons: [NativeMapPolygon] {
		var shapes = importedMapContent.overlays.flatMap(Self.importedPolygons)
		shapes.append(contentsOf: styledImportedFeatures.flatMap(Self.styledFeaturePolygons))
		if showConvexHull {
			let coordinates = positions
				.filter { $0.nodePosition?.viaMqtt == false }
				.compactMap(\.nodeCoordinate)
			if coordinates.count > 2 {
				shapes.append(
					NativeMapPolygon(
						coordinates: coordinates.getConvexHull(),
						stroke: .blue,
						fill: .indigo.opacity(0.25),
						lineWidth: 3
					)
				)
			}
		}
		return shapes
	}

	private var styledImportedFeatures: [NativeMapStyledFeature] {
		importedMapContent.styledFeatures.compactMap { feature in
			guard let overlay = feature.createOverlay() else { return nil }
			return NativeMapStyledFeature(feature: feature, overlay: overlay)
		}
	}

	private var circles: [NativeMapCircle] {
		visiblePositions.compactMap { position in
			guard position.latest, 10...19 ~= position.precisionBits else { return nil }
			let center = position.offlineMapCoordinate
			guard CLLocationCoordinate2DIsValid(center) else { return nil }
			let precision = PositionPrecision(rawValue: Int(position.precisionBits))
			let radius = precision?.precisionMeters ?? 0
			guard radius > 0 else { return nil }
			let color = Color(uiColor: UIColor(hex: UInt32(position.nodePosition?.num ?? 0)))
			return NativeMapCircle(
				center: center,
				radius: radius,
				stroke: .white.opacity(0.9),
				fill: color.opacity(0.25),
				lineWidth: 2
			)
		}
	}

	private var importedPointAnnotations: [ImportedPoint] {
		importedMapContent.annotations.enumerated().compactMap { index, annotation in
			guard CLLocationCoordinate2DIsValid(annotation.coordinate) else { return nil }
			return ImportedPoint(
				id: "\(index)-\(annotation.coordinate.latitude)-\(annotation.coordinate.longitude)",
				coordinate: annotation.coordinate,
				title: annotation.title.flatMap { $0 } ?? "Offline Import"
			)
		}
	}

	private func visibleTiles(size: CGSize) -> [NativeDisplayedTile] {
		guard size.width > 0, size.height > 0 else { return [] }
		let sourceZoom = tileSourceZoom(for: zoom)
		let zoomDelta = max(zoom - sourceZoom, 0)
		let scale = CGFloat(1 << zoomDelta)
		let tileSize = nativeTileSize * scale
		let topLeftPixel = SlippyMapProjection.topLeftPixel(
			center: centerCoordinate,
			zoom: zoom,
			size: size,
			dragOffset: dragOffset
		)
		let minTileX = Int(floor(topLeftPixel.x / tileSize)) - 1
		let maxTileX = Int(floor((topLeftPixel.x + size.width) / tileSize)) + 1
		let minTileY = max(Int(floor(topLeftPixel.y / tileSize)) - 1, 0)
		let maxTileY = min(Int(floor((topLeftPixel.y + size.height) / tileSize)) + 1, (1 << sourceZoom) - 1)

		var tiles: [NativeDisplayedTile] = []
		for x in minTileX...maxTileX {
			for y in minTileY...maxTileY {
				let sourceX = SlippyMapProjection.wrappedTileX(x, zoom: sourceZoom)
				let center = CGPoint(
					x: CGFloat(x) * tileSize - topLeftPixel.x + tileSize / 2,
					y: CGFloat(y) * tileSize - topLeftPixel.y + tileSize / 2
				)
				tiles.append(NativeDisplayedTile(displayX: x, y: y, z: sourceZoom, sourceX: sourceX, center: center, size: tileSize))
			}
		}
		return tiles
	}

	private func tileSourceZoom(for displayZoom: Int) -> Int {
		guard importedTileSourceID.isEmpty else {
			return displayZoom
		}
		return min(displayZoom, effectiveTileServer.zoomRange.last ?? displayZoom)
	}

	private func dragGesture(size: CGSize) -> some Gesture {
		DragGesture(minimumDistance: 2)
			.onChanged { value in
				if usesNativeMapLibreRenderer {
					if dragGestureStartCenter == nil {
						dragGestureStartCenter = centerCoordinate
					}
					guard let startCenter = dragGestureStartCenter else { return }
					let centerPixel = SlippyMapProjection.pixel(for: startCenter, zoomLevel: cameraZoomLevel)
					let updatedPixel = CGPoint(
						x: centerPixel.x - value.translation.width,
						y: centerPixel.y - value.translation.height
					)
					centerCoordinate = SlippyMapProjection.coordinate(for: updatedPixel, zoomLevel: cameraZoomLevel)
					publishVisibleRegion(size: size)
				} else {
					dragOffset = value.translation
				}
			}
			.onEnded { value in
				if usesNativeMapLibreRenderer {
					dragGestureStartCenter = nil
				} else {
					let centerPixel = SlippyMapProjection.pixel(for: centerCoordinate, zoom: zoom)
					let updatedPixel = CGPoint(
						x: centerPixel.x - value.translation.width,
						y: centerPixel.y - value.translation.height
					)
					centerCoordinate = SlippyMapProjection.coordinate(for: updatedPixel, zoom: zoom)
					dragOffset = .zero
				}
				publishVisibleRegion(size: size)
			}
	}

	private func zoomGesture(size: CGSize) -> some Gesture {
		MagnificationGesture()
			.onChanged { value in
				if usesNativeMapLibreRenderer {
					if zoomGestureStartZoomLevel == nil {
						zoomGestureStartZoomLevel = cameraZoomLevel
					}
					guard let startZoomLevel = zoomGestureStartZoomLevel else { return }
					let zoomDelta = log2(max(Double(value), 0.01)) * 2
					let updatedZoomLevel = clampedZoomLevel(startZoomLevel + zoomDelta)
					cameraZoomLevel = updatedZoomLevel
					zoom = Int(round(updatedZoomLevel))
					publishVisibleRegion(size: size)
					return
				}

				if zoomGestureStartZoom == nil {
					zoomGestureStartZoom = zoom
				}
				guard let startZoom = zoomGestureStartZoom else { return }
				let zoomDelta = Int((log2(max(Double(value), 0.01)) * 2).rounded())
				let updatedZoom = clampedZoom(startZoom + zoomDelta)
				if updatedZoom != zoom {
					zoom = updatedZoom
					cameraZoomLevel = Double(updatedZoom)
					publishVisibleRegion(size: size)
				}
			}
			.onEnded { _ in
				zoomGestureStartZoomLevel = nil
				zoomGestureStartZoom = nil
				publishVisibleRegion(size: size)
			}
	}

	private func longPressGesture(renderContext: SlippyMapRenderContext) -> some Gesture {
		LongPressGesture(minimumDuration: 0.5)
			.sequenced(before: SpatialTapGesture(coordinateSpace: .local))
			.onEnded { value in
				guard case let .second(_, tapValue) = value,
					  let location = tapValue?.location else {
					return
				}
				onLongPress?(renderContext.coordinate(for: location))
				UINotificationFeedbackGenerator().notificationOccurred(.success)
			}
	}

	private func initializeCameraIfNeeded(size: CGSize) {
		guard !didSetInitialCamera else { return }
		didSetInitialCamera = true
		let coordinates = initialCoordinates
		if let center = SlippyMapProjection.center(of: coordinates) {
			centerCoordinate = center
			zoom = clampedZoom(SlippyMapProjection.bestZoom(toFit: coordinates, size: size, maximumZoom: effectiveTileServer.offlineDisplayZoomRange.upperBound))
			cameraZoomLevel = Double(zoom)
		} else if let location = LocationsHandler.shared.manager.location?.coordinate {
			centerCoordinate = location
			zoom = 13
			cameraZoomLevel = Double(zoom)
		} else {
			centerCoordinate = LocationsHandler.DefaultLocation
			zoom = 12
			cameraZoomLevel = Double(zoom)
		}
	}

	private var initialCoordinates: [CLLocationCoordinate2D] {
		var coordinates = visiblePositions
			.map(\.offlineMapCoordinate)
			.filter(CLLocationCoordinate2DIsValid)
		if showWaypoints {
			coordinates.append(contentsOf: waypoints.map(\.offlineMapCoordinate).filter(CLLocationCoordinate2DIsValid))
		}
		return coordinates
	}

	private func centerOnPhoneLocation(size: CGSize) {
		let locationManager = locationsHandler.manager
		switch locationManager.authorizationStatus {
		case .notDetermined:
			pendingUserLocationCenter = true
			locationManager.requestWhenInUseAuthorization()
			waitForLocationPermissionAndUpdate(size: size)
			return
		case .authorizedAlways, .authorizedWhenInUse:
			if let coordinate = currentPhoneCoordinate {
				centerMap(on: coordinate, size: size)
			} else {
				pendingUserLocationCenter = true
				locationManager.requestLocation()
				waitForLocationPermissionAndUpdate(size: size)
			}
		default:
			pendingUserLocationCenter = false
			return
		}
	}

	private var currentPhoneCoordinate: CLLocationCoordinate2D? {
		locationsHandler.latestLocation?.coordinate ?? locationsHandler.manager.location?.coordinate
	}

	@discardableResult
	private func completePendingUserLocationCenterIfNeeded(size: CGSize) -> Bool {
		guard pendingUserLocationCenter, let coordinate = currentPhoneCoordinate else { return false }
		pendingUserLocationCenter = false
		centerMap(on: coordinate, size: size)
		return true
	}

	private func waitForLocationPermissionAndUpdate(size: CGSize) {
		let locationManager = locationsHandler.manager
		Task { @MainActor in
			var requestedLocation = false
			for _ in 0..<10 {
				guard pendingUserLocationCenter else { return }
				switch locationManager.authorizationStatus {
				case .authorizedAlways, .authorizedWhenInUse:
					if !requestedLocation {
						locationManager.requestLocation()
						requestedLocation = true
					}
					if completePendingUserLocationCenterIfNeeded(size: size) {
						return
					}
				case .denied, .restricted:
					pendingUserLocationCenter = false
					return
				case .notDetermined:
					break
				@unknown default:
					pendingUserLocationCenter = false
					return
				}
				try? await Task.sleep(for: .milliseconds(500))
			}
			pendingUserLocationCenter = false
		}
	}

	private func centerMap(on coordinate: CLLocationCoordinate2D, size: CGSize) {
		userCoordinate = coordinate
		withAnimation(.easeInOut(duration: 0.2)) {
			centerCoordinate = coordinate
			zoom = max(zoom, 15)
			cameraZoomLevel = Double(zoom)
		}
		cameraSyncRequest += 1
		publishVisibleRegion(size: size)
	}

	private func refreshUserCoordinate() {
		userCoordinate = currentPhoneCoordinate
	}

	private func zoomIn(size: CGSize) {
		zoom = clampedZoom(zoom + 1)
		cameraZoomLevel = Double(zoom)
		publishVisibleRegion(size: size)
	}

	private func zoomOut(size: CGSize) {
		zoom = clampedZoom(zoom - 1)
		cameraZoomLevel = Double(zoom)
		publishVisibleRegion(size: size)
	}

	private func clampedZoom(_ zoom: Int) -> Int {
		let zoomRange = effectiveTileServer.offlineDisplayZoomRange
		return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
	}

	private func clampedZoomLevel(_ zoomLevel: Double) -> Double {
		let zoomRange = effectiveTileServer.offlineDisplayZoomRange
		return min(max(zoomLevel, Double(zoomRange.lowerBound)), Double(zoomRange.upperBound))
	}

	private func publishVisibleRegion(size: CGSize) {
		publishVisibleRegion(center: centerCoordinate, zoomLevel: usesNativeMapLibreRenderer ? cameraZoomLevel : Double(zoom), size: size)
	}

	private func publishVisibleRegion(center: CLLocationCoordinate2D, zoomLevel: Double, size: CGSize) {
		let region = SlippyMapProjection.visibleRegion(center: center, zoomLevel: zoomLevel, size: size)
		DispatchQueue.main.async {
			visibleRegion = region
		}
	}

	private static func importedPolylines(from overlay: MKOverlay) -> [NativeMapPolyline] {
		if let polyline = overlay as? MKPolyline {
			return [
				NativeMapPolyline(
					coordinates: polyline.coordinates,
					color: .teal,
					lineWidth: 4,
					dashed: false
				)
			]
		}
		if let multiPolyline = overlay as? MKMultiPolyline {
			return multiPolyline.polylines.flatMap(importedPolylines)
		}
		return []
	}

	private static func styledFeaturePolylines(_ styledFeature: NativeMapStyledFeature) -> [NativeMapPolyline] {
		if let polyline = styledFeature.overlay as? MKPolyline {
			return [
				NativeMapPolyline(
					coordinates: polyline.coordinates,
					color: styledFeature.feature.strokeColor,
					lineWidth: CGFloat(styledFeature.feature.feature.strokeWidth),
					dashed: styledFeature.feature.feature.lineDashArray?.isEmpty == false
				)
			]
		}
		if let multiPolyline = styledFeature.overlay as? MKMultiPolyline {
			return multiPolyline.polylines.map { polyline in
				NativeMapPolyline(
					coordinates: polyline.coordinates,
					color: styledFeature.feature.strokeColor,
					lineWidth: CGFloat(styledFeature.feature.feature.strokeWidth),
					dashed: styledFeature.feature.feature.lineDashArray?.isEmpty == false
				)
			}
		}
		return []
	}

	private static func importedPolygons(from overlay: MKOverlay) -> [NativeMapPolygon] {
		if let polygon = overlay as? MKPolygon {
			return [
				NativeMapPolygon(
					coordinates: polygon.coordinates,
					stroke: .teal,
					fill: .teal.opacity(0.18),
					lineWidth: 3
				)
			]
		}
		if let multiPolygon = overlay as? MKMultiPolygon {
			return multiPolygon.polygons.flatMap(importedPolygons)
		}
		return []
	}

	private static func styledFeaturePolygons(_ styledFeature: NativeMapStyledFeature) -> [NativeMapPolygon] {
		if let polygon = styledFeature.overlay as? MKPolygon {
			return [
				NativeMapPolygon(
					coordinates: polygon.coordinates,
					stroke: styledFeature.feature.strokeColor,
					fill: styledFeature.feature.fillColor,
					lineWidth: CGFloat(styledFeature.feature.feature.strokeWidth)
				)
			]
		}
		if let multiPolygon = styledFeature.overlay as? MKMultiPolygon {
			return multiPolygon.polygons.map { polygon in
				NativeMapPolygon(
					coordinates: polygon.coordinates,
					stroke: styledFeature.feature.strokeColor,
					fill: styledFeature.feature.fillColor,
					lineWidth: CGFloat(styledFeature.feature.feature.strokeWidth)
				)
			}
		}
		return []
	}
}

private struct MapLibreVectorOSMView: UIViewRepresentable {
	@Binding var centerCoordinate: CLLocationCoordinate2D
	@Binding var zoom: Int
	@Binding var zoomLevel: Double
	let styleURL: URL
	let allowsInteraction: Bool
	let showUserLocation: Bool
	let showUserHeading: Bool
	let is3DMode: Bool
	let resetMapHeadingRequest: Int
	let cameraSyncRequest: Int
	let positions: [PositionEntity]
	let waypoints: [WaypointEntity]
	let importedPoints: [ImportedPoint]
	let userCoordinate: CLLocationCoordinate2D?
	let annotationStyle: OfflineMapAnnotationStyle
	let polylines: [NativeMapPolyline]
	let polygons: [NativeMapPolygon]
	let circles: [NativeMapCircle]
	let minimumZoom: Double
	let maximumZoom: Double
	@Binding var selectedPosition: PositionEntity?
	@Binding var selectedWaypoint: WaypointEntity?
	let onCameraChange: (CLLocationCoordinate2D, Double) -> Void
	let onLongPress: ((CLLocationCoordinate2D) -> Void)?

	private var overlayContentIdentity: Int {
		var hasher = Hasher()
		for polyline in polylines {
			hasher.combine(polyline.lineWidth)
			hasher.combine(polyline.dashed)
			hasher.combine(String(describing: polyline.color))
			for coordinate in polyline.coordinates {
				hasher.combine(coordinate.latitude)
				hasher.combine(coordinate.longitude)
			}
		}
		for polygon in polygons {
			hasher.combine(polygon.lineWidth)
			hasher.combine(String(describing: polygon.stroke))
			hasher.combine(String(describing: polygon.fill))
			for coordinate in polygon.coordinates {
				hasher.combine(coordinate.latitude)
				hasher.combine(coordinate.longitude)
			}
		}
		for circle in circles {
			hasher.combine(circle.center.latitude)
			hasher.combine(circle.center.longitude)
			hasher.combine(circle.radius)
			hasher.combine(circle.lineWidth)
			hasher.combine(String(describing: circle.stroke))
			hasher.combine(String(describing: circle.fill))
		}
		return hasher.finalize()
	}

	func makeUIView(context: Context) -> MLNMapView {
		let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
		mapView.delegate = context.coordinator
		mapView.minimumZoomLevel = minimumZoom
		mapView.maximumZoomLevel = maximumZoom
		mapView.minimumPitch = 0
		mapView.maximumPitch = 60
		mapView.isScrollEnabled = allowsInteraction
		mapView.isZoomEnabled = allowsInteraction
		mapView.isRotateEnabled = allowsInteraction
		mapView.isPitchEnabled = allowsInteraction
		mapView.showsUserLocation = false
		applyUserTrackingMode(to: mapView)
		mapView.setCenter(centerCoordinate, zoomLevel: zoomLevel, animated: false)
		apply3DMode(to: mapView, animated: false)
		configureAttributionButton(mapView)
		if allowsInteraction {
			let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
			recognizer.minimumPressDuration = 0.5
			mapView.addGestureRecognizer(recognizer)
		}
		context.coordinator.refreshMapContent(on: mapView)
		return mapView
	}

	func updateUIView(_ mapView: MLNMapView, context: Context) {
		context.coordinator.parent = self
		mapView.delegate = context.coordinator
		mapView.minimumZoomLevel = minimumZoom
		mapView.maximumZoomLevel = maximumZoom
		mapView.minimumPitch = 0
		mapView.maximumPitch = 60
		mapView.isScrollEnabled = allowsInteraction
		mapView.isZoomEnabled = allowsInteraction
		mapView.isRotateEnabled = allowsInteraction
		mapView.isPitchEnabled = allowsInteraction
		mapView.showsUserLocation = false
		applyUserTrackingMode(to: mapView)
		applyHeadingResetIfNeeded(to: mapView, coordinator: context.coordinator)
		configureAttributionButton(mapView)
		if mapView.styleURL != styleURL {
			mapView.styleURL = styleURL
		}
		context.coordinator.refreshMapContent(on: mapView)

		guard !context.coordinator.isUpdatingFromMap else { return }
		applyCameraSyncIfNeeded(to: mapView, coordinator: context.coordinator)
		apply3DMode(to: mapView, animated: true)
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	final class Coordinator: NSObject, MLNMapViewDelegate {
		var parent: MapLibreVectorOSMView
		var isUpdatingFromMap = false
		var handledResetMapHeadingRequest = 0
		var handledCameraSyncRequest = 0
		private var renderedVisibleAnnotationIdentity: Int?
		private var renderedOverlayContentIdentity: Int?
		private var shapeStyles: [String: MapLibreShapeStyle] = [:]

		init(_ parent: MapLibreVectorOSMView) {
			self.parent = parent
		}

		func mapViewRegionIsChanging(_ mapView: MLNMapView) {
			publishCamera(from: mapView, publishesVisibleRegion: false)
		}

		func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
			publishCamera(from: mapView, publishesVisibleRegion: true)
			refreshVisibleAnnotations(on: mapView)
		}

		func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
			guard let annotation = annotation as? MapLibreHostedAnnotation else { return nil }
			let view = hostedAnnotationView(in: mapView, identifier: annotation.reuseIdentifier)
			switch annotation.payload {
			case .position(let position):
				view.setContent(
					OfflinePositionAnnotation(position: position, style: parent.annotationStyle, showsOnlinePulse: false, showsTitle: position.latest),
					size: position.latest ? CGSize(width: 144, height: 92) : CGSize(width: 28, height: 28),
					identity: annotation.contentIdentity(annotationStyle: parent.annotationStyle)
				)
			case .waypoint(let waypoint):
				view.setContent(OfflineWaypointAnnotation(waypoint: waypoint, showsTitle: true), size: CGSize(width: 144, height: 76), identity: annotation.contentIdentity(annotationStyle: parent.annotationStyle))
			case .importedPoint(let importedPoint):
				view.setContent(OfflineImportedPointView(title: importedPoint.title), size: CGSize(width: 34, height: 34), identity: annotation.contentIdentity(annotationStyle: parent.annotationStyle))
			case .userLocation:
				view.setContent(UserLocationAnnotation(), size: CGSize(width: 36, height: 36), identity: annotation.contentIdentity(annotationStyle: parent.annotationStyle))
			}
			return view
		}

		func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
			guard let annotation = annotation as? MapLibreHostedAnnotation else { return }
			switch annotation.payload {
			case .position(let position):
				parent.selectedPosition = parent.selectedPosition == position ? nil : position
			case .waypoint(let waypoint):
				parent.selectedWaypoint = parent.selectedWaypoint == waypoint ? nil : waypoint
			case .importedPoint, .userLocation:
				break
			}
			mapView.deselectAnnotation(annotation, animated: false)
		}

		func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
			false
		}

		func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
			style(for: annotation).alpha
		}

		func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
			style(for: annotation).strokeColor
		}

		func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
			style(for: annotation).fillColor
		}

		func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
			style(for: annotation).lineWidth
		}

		func mapView(_ mapView: MLNMapView, shapeAnnotationIsEnabled annotation: MLNShape) -> Bool {
			false
		}

		func refreshMapContent(on mapView: MLNMapView) {
			refreshVisibleAnnotations(on: mapView)

			let overlayContentIdentity = parent.overlayContentIdentity
			if renderedOverlayContentIdentity != overlayContentIdentity {
				let existingOverlays = mapView.overlays.filter { overlay in
					guard let shape = overlay as? MLNShape else { return false }
					return shape.title?.hasPrefix(MapLibreShapeStyle.titlePrefix) == true
				}
				if !existingOverlays.isEmpty {
					mapView.removeOverlays(existingOverlays)
				}

				let styledOverlays = parent.makeStyledOverlays()
				shapeStyles = styledOverlays.styles
				if !styledOverlays.overlays.isEmpty {
					mapView.addOverlays(styledOverlays.overlays)
				}
				renderedOverlayContentIdentity = overlayContentIdentity
			}
		}

		private func refreshVisibleAnnotations(on mapView: MLNMapView) {
			let annotations = parent.makeVisibleHostedAnnotations(in: mapView)
			let visibleAnnotationIdentity = parent.contentIdentity(for: annotations)
			guard renderedVisibleAnnotationIdentity != visibleAnnotationIdentity else { return }

			let existingAnnotations = mapView.annotations?.filter { $0 is MapLibreHostedAnnotation } ?? []
			if !existingAnnotations.isEmpty {
				mapView.removeAnnotations(existingAnnotations)
			}

			if !annotations.isEmpty {
				mapView.addAnnotations(annotations)
			}
			renderedVisibleAnnotationIdentity = visibleAnnotationIdentity

			if !annotations.isEmpty {
				DispatchQueue.main.async {
					self.raiseMeshtasticAnnotations(on: mapView)
				}
			}
		}

		@objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
			guard recognizer.state == .began,
				  let mapView = recognizer.view as? MLNMapView,
				  let onLongPress = parent.onLongPress else {
				return
			}
			let point = recognizer.location(in: mapView)
			onLongPress(mapView.convert(point, toCoordinateFrom: mapView))
			UINotificationFeedbackGenerator().notificationOccurred(.success)
		}

		private func publishCamera(from mapView: MLNMapView, publishesVisibleRegion: Bool) {
			isUpdatingFromMap = true
			let mapCenter = mapView.centerCoordinate
			let mapZoomLevel = min(max(mapView.zoomLevel, parent.minimumZoom), parent.maximumZoom)
			let mapZoom = min(max(Int(round(mapZoomLevel)), Int(parent.minimumZoom)), Int(parent.maximumZoom))
			let applyCameraChange = {
				self.parent.centerCoordinate = mapCenter
				self.parent.zoomLevel = mapZoomLevel
				self.parent.zoom = mapZoom
				if publishesVisibleRegion {
					self.parent.onCameraChange(mapCenter, mapZoomLevel)
				}
				DispatchQueue.main.async {
					self.isUpdatingFromMap = false
				}
			}
			if Thread.isMainThread {
				applyCameraChange()
			} else {
				DispatchQueue.main.async(execute: applyCameraChange)
			}
		}

		private func hostedAnnotationView(in mapView: MLNMapView, identifier: String) -> MapLibreSwiftUIAnnotationView {
			if let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MapLibreSwiftUIAnnotationView {
				view.pinAboveMapLabels()
				return view
			}
			let view = MapLibreSwiftUIAnnotationView(reuseIdentifier: identifier)
			view.pinAboveMapLabels()
			return view
		}

		private func style(for annotation: MLNShape) -> MapLibreShapeStyle {
			guard let title = annotation.title, let style = shapeStyles[title] else {
				return MapLibreShapeStyle(id: "fallback", strokeColor: .systemBlue, fillColor: .clear, lineWidth: 3, alpha: 1)
			}
			return style
		}

		private func raiseMeshtasticAnnotations(on mapView: MLNMapView) {
			let visibleAnnotations = mapView.visibleAnnotations ?? mapView.annotations ?? []
			let hostedAnnotations = visibleAnnotations.compactMap { $0 as? MapLibreHostedAnnotation }
			for annotation in hostedAnnotations {
				guard let view = mapView.view(for: annotation) as? MapLibreSwiftUIAnnotationView else { continue }
				view.pinAboveMapLabels()
			}
		}
	}
}

private extension MapLibreVectorOSMView {
	func configureAttributionButton(_ mapView: MLNMapView) {
		mapView.showsAttributionButton = false
	}

	func applyUserTrackingMode(to mapView: MLNMapView) {
		if mapView.userTrackingMode != .none {
			mapView.setUserTrackingMode(.none, animated: false, completionHandler: nil)
		}
		mapView.showsUserHeadingIndicator = false
	}

	func apply3DMode(to mapView: MLNMapView, animated: Bool) {
		let targetPitch: CGFloat = is3DMode ? 55 : 0
		guard abs(mapView.camera.pitch - targetPitch) > 0.5 else { return }
		let camera = mapView.camera.copy() as? MLNMapCamera ?? MLNMapCamera()
		camera.pitch = targetPitch
		mapView.setCamera(camera, animated: animated)
	}

	func applyHeadingResetIfNeeded(to mapView: MLNMapView, coordinator: Coordinator) {
		guard coordinator.handledResetMapHeadingRequest != resetMapHeadingRequest else { return }
		coordinator.handledResetMapHeadingRequest = resetMapHeadingRequest
		mapView.setDirection(0, animated: true)
	}

	func applyCameraSyncIfNeeded(to mapView: MLNMapView, coordinator: Coordinator) {
		guard coordinator.handledCameraSyncRequest != cameraSyncRequest else { return }
		coordinator.handledCameraSyncRequest = cameraSyncRequest
		mapView.setCenter(centerCoordinate, zoomLevel: zoomLevel, animated: true)
	}

	func makeVisibleHostedAnnotations(in mapView: MLNMapView) -> [MapLibreHostedAnnotation] {
		var annotations: [MapLibreHostedAnnotation] = positions.compactMap { position in
			let coordinate = position.offlineMapCoordinate
			guard CLLocationCoordinate2DIsValid(coordinate),
				  isCoordinateInAnnotationRenderWindow(coordinate, in: mapView) else { return nil }
			return MapLibreHostedAnnotation(coordinate: coordinate, payload: .position(position))
		}
		annotations.append(contentsOf: waypoints.compactMap { waypoint in
			let coordinate = waypoint.offlineMapCoordinate
			guard CLLocationCoordinate2DIsValid(coordinate),
				  isCoordinateInAnnotationRenderWindow(coordinate, in: mapView) else { return nil }
			return MapLibreHostedAnnotation(coordinate: coordinate, payload: .waypoint(waypoint))
		})
		annotations.append(contentsOf: importedPoints.compactMap { importedPoint in
			guard CLLocationCoordinate2DIsValid(importedPoint.coordinate),
				  isCoordinateInAnnotationRenderWindow(importedPoint.coordinate, in: mapView) else { return nil }
			return MapLibreHostedAnnotation(coordinate: importedPoint.coordinate, payload: .importedPoint(importedPoint))
		})
		if let userCoordinate,
		   CLLocationCoordinate2DIsValid(userCoordinate),
		   isCoordinateInAnnotationRenderWindow(userCoordinate, in: mapView) {
			annotations.append(MapLibreHostedAnnotation(coordinate: userCoordinate, payload: .userLocation))
		}
		return annotations
	}

	func contentIdentity(for annotations: [MapLibreHostedAnnotation]) -> Int {
		var hasher = Hasher()
		hasher.combine(annotationStyle.identityValue)
		hasher.combine(annotations.count)
		for annotation in annotations {
			hasher.combine(annotation.contentIdentity(annotationStyle: annotationStyle))
		}
		return hasher.finalize()
	}

	func isCoordinateInAnnotationRenderWindow(_ coordinate: CLLocationCoordinate2D, in mapView: MLNMapView) -> Bool {
		let bounds = mapView.bounds
		guard bounds.width > 0, bounds.height > 0 else { return false }
		let point = mapView.convert(coordinate, toPointTo: mapView)
		guard point.x.isFinite, point.y.isFinite else { return false }
		let renderWindow = bounds.insetBy(dx: -Self.annotationRenderWindowMargin, dy: -Self.annotationRenderWindowMargin)
		return renderWindow.contains(point)
	}

	private static var annotationRenderWindowMargin: CGFloat { 192 }

	func makeStyledOverlays() -> (overlays: [MLNOverlay], styles: [String: MapLibreShapeStyle]) {
		var overlays: [MLNOverlay] = []
		var styles: [String: MapLibreShapeStyle] = [:]

		for (index, polyline) in polylines.enumerated() where polyline.coordinates.count > 1 {
			let id = "\(MapLibreShapeStyle.titlePrefix)polyline-\(index)"
			var coordinates = polyline.coordinates
			let overlay = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
			overlay.title = id
			overlays.append(overlay)
			styles[id] = MapLibreShapeStyle(
				id: id,
				strokeColor: UIColor(polyline.color),
				fillColor: .clear,
				lineWidth: polyline.lineWidth,
				alpha: 1
			)
		}

		for (index, polygon) in polygons.enumerated() where polygon.coordinates.count > 2 {
			let id = "\(MapLibreShapeStyle.titlePrefix)polygon-\(index)"
			var coordinates = polygon.closedCoordinates
			let overlay = MLNPolygon(coordinates: &coordinates, count: UInt(coordinates.count))
			overlay.title = id
			overlays.append(overlay)
			styles[id] = MapLibreShapeStyle(
				id: id,
				strokeColor: UIColor(polygon.stroke),
				fillColor: UIColor(polygon.fill),
				lineWidth: polygon.lineWidth,
				alpha: 1
			)
		}

		for (index, circle) in circles.enumerated() {
			let id = "\(MapLibreShapeStyle.titlePrefix)circle-\(index)"
			var coordinates = circle.polygonCoordinates
			let overlay = MLNPolygon(coordinates: &coordinates, count: UInt(coordinates.count))
			overlay.title = id
			overlays.append(overlay)
			styles[id] = MapLibreShapeStyle(
				id: id,
				strokeColor: UIColor(circle.stroke),
				fillColor: UIColor(circle.fill),
				lineWidth: circle.lineWidth,
				alpha: 1
			)
		}

		return (overlays, styles)
	}
}

private enum MapLibreHostedAnnotationPayload {
	case position(PositionEntity)
	case waypoint(WaypointEntity)
	case importedPoint(ImportedPoint)
	case userLocation
}

private final class MapLibreHostedAnnotation: NSObject, MLNAnnotation {
	let coordinate: CLLocationCoordinate2D
	let payload: MapLibreHostedAnnotationPayload

	var title: String? {
		switch payload {
		case .position(let position):
			position.offlineMapTitle
		case .waypoint(let waypoint):
			waypoint.offlineMapTitle
		case .importedPoint(let importedPoint):
			importedPoint.title
		case .userLocation:
			"Phone Location"
		}
	}

	var subtitle: String? {
		switch payload {
		case .position(let position):
			position.offlineMapSubtitle
		case .waypoint(let waypoint):
			waypoint.offlineMapSubtitle
		case .importedPoint, .userLocation:
			nil
		}
	}

	var reuseIdentifier: String {
		switch payload {
		case .position:
			"offline-vector-position"
		case .waypoint:
			"offline-vector-waypoint"
		case .importedPoint:
			"offline-vector-imported-point"
		case .userLocation:
			"offline-vector-user-location"
		}
	}

	func contentIdentity(annotationStyle: OfflineMapAnnotationStyle) -> Int {
		var hasher = Hasher()
		hasher.combine(annotationStyle.identityValue)
		hasher.combine(reuseIdentifier)
		hasher.combine(coordinate.latitude)
		hasher.combine(coordinate.longitude)
		switch payload {
		case .position(let position):
			hasher.combine(position.id)
			hasher.combine(position.latitudeI)
			hasher.combine(position.longitudeI)
			hasher.combine(position.latest)
			hasher.combine(position.heading)
			hasher.combine(position.precisionBits)
			hasher.combine(position.nodePosition?.user?.shortName)
			hasher.combine(position.nodePosition?.user?.longName)
			hasher.combine(position.nodePosition?.isOnline ?? false)
			hasher.combine(position.nodePosition?.metadata?.positionFlags ?? 0)
		case .waypoint(let waypoint):
			hasher.combine(waypoint.persistentModelID.hashValue)
			hasher.combine(waypoint.latitudeI)
			hasher.combine(waypoint.longitudeI)
			hasher.combine(waypoint.icon)
			hasher.combine(waypoint.name)
		case .importedPoint(let importedPoint):
			hasher.combine(importedPoint.id)
			hasher.combine(importedPoint.title)
		case .userLocation:
			break
		}
		return hasher.finalize()
	}

	init(coordinate: CLLocationCoordinate2D, payload: MapLibreHostedAnnotationPayload) {
		self.coordinate = coordinate
		self.payload = payload
	}
}

private struct MapLibreShapeStyle {
	static let titlePrefix = "offline-vector-shape:"

	let id: String
	let strokeColor: UIColor
	let fillColor: UIColor
	let lineWidth: CGFloat
	let alpha: CGFloat
}

private final class MapLibreSwiftUIAnnotationView: MLNAnnotationView {
	private var hostingController: UIHostingController<AnyView>?
	private var renderedContentIdentity: Int?

	override init(reuseIdentifier: String?) {
		super.init(reuseIdentifier: reuseIdentifier)
		configureBaseView()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		configureBaseView()
	}

	override func prepareForReuse() {
		super.prepareForReuse()
		renderedContentIdentity = nil
		hostingController?.rootView = AnyView(EmptyView())
	}

	func setContent<Content: View>(_ content: Content, size: CGSize, identity: Int) {
		bounds = CGRect(origin: .zero, size: size)
		centerOffset = CGVector(dx: 0, dy: 0)
		clipsToBounds = false
		pinAboveMapLabels()
		if renderedContentIdentity == identity {
			hostingController?.view.frame = bounds
			hostingController?.view.clipsToBounds = false
			hostingController?.view.layer.zPosition = Self.annotationZPosition + 1
			return
		}
		renderedContentIdentity = identity

		let rootView = AnyView(content.frame(width: size.width, height: size.height))
		if let hostingController {
			hostingController.rootView = rootView
			hostingController.view.frame = bounds
			hostingController.view.clipsToBounds = false
			hostingController.view.layer.zPosition = Self.annotationZPosition + 1
		} else {
			let hostingController = UIHostingController(rootView: rootView)
			hostingController.view.backgroundColor = .clear
			hostingController.view.isUserInteractionEnabled = false
			hostingController.view.frame = bounds
			hostingController.view.clipsToBounds = false
			hostingController.view.layer.zPosition = Self.annotationZPosition + 1
			addSubview(hostingController.view)
			self.hostingController = hostingController
		}
		superview?.bringSubviewToFront(self)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		pinAboveMapLabels()
		superview?.bringSubviewToFront(self)
	}

	func pinAboveMapLabels() {
		layer.zPosition = Self.annotationZPosition
		superview?.layer.zPosition = Self.annotationZPosition
	}

	private func configureBaseView() {
		backgroundColor = .clear
		isOpaque = false
		clipsToBounds = false
		isEnabled = true
		scalesWithViewingDistance = false
		rotatesToMatchCamera = false
		pinAboveMapLabels()
	}

	private static let annotationZPosition: CGFloat = 10_000
}

private struct MapKitOfflineAnnotationOverlayView: UIViewRepresentable {
	@Binding var centerCoordinate: CLLocationCoordinate2D
	@Binding var zoom: Int
	@Binding var zoomLevel: Double
	let positions: [PositionEntity]
	let waypoints: [WaypointEntity]
	let importedPoints: [ImportedPoint]
	let userCoordinate: CLLocationCoordinate2D?
	let annotationStyle: OfflineMapAnnotationStyle
	let polylines: [NativeMapPolyline]
	let polygons: [NativeMapPolygon]
	let circles: [NativeMapCircle]
	let showsStyledOverlays: Bool
	let minimumZoom: Double
	let maximumZoom: Double
	@Binding var selectedPosition: PositionEntity?
	@Binding var selectedWaypoint: WaypointEntity?
	let onCameraChange: (CLLocationCoordinate2D, Double) -> Void
	let onLongPress: ((CLLocationCoordinate2D) -> Void)?

	private var contentIdentity: String {
		let positionIdentity = positions.map { position in
			[
				"\(position.id)",
				"\(position.latitudeI)",
				"\(position.longitudeI)",
				"\(position.latest)",
				"\(position.heading)",
				"\(position.precisionBits)",
				position.nodePosition?.user?.shortName ?? "",
				"\(position.nodePosition?.isOnline ?? false)",
				"\(position.nodePosition?.hasDetectionSensorMetrics ?? false)",
				"\(position.nodePosition?.metadata?.positionFlags ?? 0)"
			].joined(separator: ":")
		}.joined(separator: "|")
		let waypointIdentity = waypoints.map { waypoint in
			[
				"\(waypoint.persistentModelID)",
				"\(waypoint.latitudeI)",
				"\(waypoint.longitudeI)",
				"\(waypoint.icon)",
				waypoint.name ?? ""
			].joined(separator: ":")
		}.joined(separator: "|")
		let importedIdentity = importedPoints.map { "\($0.id):\($0.coordinate.latitude):\($0.coordinate.longitude):\($0.title)" }.joined(separator: "|")
		let userIdentity = userCoordinate.map { "\($0.latitude):\($0.longitude)" } ?? ""
		let shapeIdentity = [
			showsStyledOverlays ? polylines.enumerated().map { "\($0.offset):\($0.element.lineWidth):\($0.element.coordinates.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";"))" }.joined(separator: "|") : "",
			showsStyledOverlays ? polygons.enumerated().map { "\($0.offset):\($0.element.lineWidth):\($0.element.coordinates.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";"))" }.joined(separator: "|") : "",
			showsStyledOverlays ? circles.enumerated().map { "\($0.offset):\($0.element.radius):\($0.element.center.latitude),\($0.element.center.longitude)" }.joined(separator: "|") : ""
		].joined(separator: "#")
		return "\(annotationStyle)#\(positionIdentity)#\(waypointIdentity)#\(importedIdentity)#\(userIdentity)#\(shapeIdentity)"
	}

	func makeUIView(context: Context) -> MKMapView {
		let mapView = TransparentAnnotationMapView(frame: .zero)
		mapView.delegate = context.coordinator
		mapView.backgroundColor = .clear
		mapView.isOpaque = false
		mapView.mapType = .standard
		mapView.showsBuildings = false
		mapView.showsCompass = false
		mapView.showsScale = false
		mapView.showsTraffic = false
		mapView.showsUserLocation = false
		mapView.isRotateEnabled = false
		mapView.isPitchEnabled = false
		mapView.pointOfInterestFilter = .excludingAll
		mapView.addOverlay(TransparentMapKitTileOverlay(), level: .aboveLabels)
		let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
		recognizer.minimumPressDuration = 0.5
		mapView.addGestureRecognizer(recognizer)
		context.coordinator.refreshMapContent(on: mapView)
		mapView.keepMapContentTransparent()
		return mapView
	}

	func updateUIView(_ mapView: MKMapView, context: Context) {
		context.coordinator.parent = self
		mapView.delegate = context.coordinator
		context.coordinator.refreshMapContent(on: mapView)
		(mapView as? TransparentAnnotationMapView)?.keepMapContentTransparent()
		guard !context.coordinator.isApplyingMapCamera else { return }
		context.coordinator.applyCameraIfNeeded(on: mapView)
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	final class Coordinator: NSObject, MKMapViewDelegate {
		var parent: MapKitOfflineAnnotationOverlayView
		var isApplyingMapCamera = false
		private var renderedContentIdentity = ""
		private var shapeStyles: [String: MapKitShapeStyle] = [:]

		init(_ parent: MapKitOfflineAnnotationOverlayView) {
			self.parent = parent
		}

		func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
			if overlay is TransparentMapKitTileOverlay {
				return TransparentMapKitTileOverlayRenderer(overlay: overlay)
			}
			if let polyline = overlay as? MKPolyline {
				let renderer = MKPolylineRenderer(polyline: polyline)
				let style = style(for: overlay)
				renderer.strokeColor = style.strokeColor
				renderer.lineWidth = style.lineWidth
				renderer.alpha = style.alpha
				return renderer
			}
			if let polygon = overlay as? MKPolygon {
				let renderer = MKPolygonRenderer(polygon: polygon)
				let style = style(for: overlay)
				renderer.strokeColor = style.strokeColor
				renderer.fillColor = style.fillColor
				renderer.lineWidth = style.lineWidth
				renderer.alpha = style.alpha
				return renderer
			}
			if let circle = overlay as? MKCircle {
				let renderer = MKCircleRenderer(circle: circle)
				let style = style(for: overlay)
				renderer.strokeColor = style.strokeColor
				renderer.fillColor = style.fillColor
				renderer.lineWidth = style.lineWidth
				renderer.alpha = style.alpha
				return renderer
			}
			return MKOverlayRenderer(overlay: overlay)
		}

		func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
			guard let annotation = annotation as? MapKitHostedAnnotation else { return nil }
			let view = hostedAnnotationView(in: mapView, identifier: annotation.reuseIdentifier)
			switch annotation.payload {
			case .position(let position):
				view.setContent(
					OfflinePositionAnnotation(position: position, style: parent.annotationStyle, showsTitle: position.latest),
					size: position.latest ? CGSize(width: 144, height: 92) : CGSize(width: 22, height: 22)
				)
			case .waypoint(let waypoint):
				view.setContent(OfflineWaypointAnnotation(waypoint: waypoint, showsTitle: true), size: CGSize(width: 144, height: 76))
			case .importedPoint(let importedPoint):
				view.setContent(OfflineImportedPointView(title: importedPoint.title), size: CGSize(width: 34, height: 34))
			case .userLocation:
				view.setContent(UserLocationAnnotation(), size: CGSize(width: 36, height: 36))
			}
			return view
		}

		func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
			guard let annotation = annotation as? MapKitHostedAnnotation else { return }
			switch annotation.payload {
			case .position(let position):
				parent.selectedPosition = parent.selectedPosition == position ? nil : position
			case .waypoint(let waypoint):
				parent.selectedWaypoint = parent.selectedWaypoint == waypoint ? nil : waypoint
			case .importedPoint, .userLocation:
				break
			}
			mapView.deselectAnnotation(annotation, animated: false)
		}

		func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
			publishCamera(from: mapView)
		}

		func refreshMapContent(on mapView: MKMapView) {
			let contentIdentity = parent.contentIdentity
			guard renderedContentIdentity != contentIdentity else { return }

			let hostedAnnotations = mapView.annotations.compactMap { $0 as? MapKitHostedAnnotation }
			if !hostedAnnotations.isEmpty {
				mapView.removeAnnotations(hostedAnnotations)
			}

			let styledOverlays = mapView.overlays.filter { $0.title??.hasPrefix(MapKitShapeStyle.titlePrefix) == true }
			if !styledOverlays.isEmpty {
				mapView.removeOverlays(styledOverlays)
			}

			let annotations = parent.makeHostedAnnotations()
			if !annotations.isEmpty {
				mapView.addAnnotations(annotations)
			}

			let overlays = parent.makeStyledOverlays()
			shapeStyles = overlays.styles
			if !overlays.overlays.isEmpty {
				mapView.addOverlays(overlays.overlays, level: .aboveLabels)
			}

			renderedContentIdentity = contentIdentity
		}

		func applyCameraIfNeeded(on mapView: MKMapView) {
			let region = SlippyMapProjection.visibleRegion(
				center: parent.centerCoordinate,
				zoomLevel: parent.zoomLevel,
				size: mapView.bounds.size
			)
			let centerDifference = CLLocation(latitude: mapView.region.center.latitude, longitude: mapView.region.center.longitude)
				.distance(from: CLLocation(latitude: region.center.latitude, longitude: region.center.longitude))
			let spanDifference = abs(mapView.region.span.latitudeDelta - region.span.latitudeDelta) + abs(mapView.region.span.longitudeDelta - region.span.longitudeDelta)
			guard centerDifference > 1 || spanDifference > 0.000_1 else { return }
			isApplyingMapCamera = true
			mapView.setRegion(region, animated: false)
			DispatchQueue.main.async {
				self.isApplyingMapCamera = false
			}
		}

		@objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
			guard recognizer.state == .began,
				  let mapView = recognizer.view as? MKMapView,
				  let onLongPress = parent.onLongPress else {
				return
			}
			let point = recognizer.location(in: mapView)
			onLongPress(mapView.convert(point, toCoordinateFrom: mapView))
			UINotificationFeedbackGenerator().notificationOccurred(.success)
		}

		private func publishCamera(from mapView: MKMapView) {
			guard !isApplyingMapCamera else { return }
			let mapCenter = mapView.region.center
			let mapZoomLevel = min(max(SlippyMapProjection.zoomLevel(for: mapView.region, size: mapView.bounds.size), parent.minimumZoom), parent.maximumZoom)
			let mapZoom = min(max(Int(round(mapZoomLevel)), Int(parent.minimumZoom)), Int(parent.maximumZoom))
			parent.centerCoordinate = mapCenter
			parent.zoomLevel = mapZoomLevel
			parent.zoom = mapZoom
			parent.onCameraChange(mapCenter, mapZoomLevel)
		}

		private func hostedAnnotationView(in mapView: MKMapView, identifier: String) -> MapKitSwiftUIAnnotationView {
			if let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MapKitSwiftUIAnnotationView {
				return view
			}
			return MapKitSwiftUIAnnotationView(annotation: nil, reuseIdentifier: identifier)
		}

		private func style(for overlay: MKOverlay) -> MapKitShapeStyle {
			guard let title = overlay.title, let title, let style = shapeStyles[title] else {
				return MapKitShapeStyle(id: "fallback", strokeColor: .systemBlue, fillColor: .clear, lineWidth: 3, alpha: 1)
			}
			return style
		}
	}
}

private extension MapKitOfflineAnnotationOverlayView {
	func makeHostedAnnotations() -> [MapKitHostedAnnotation] {
		var annotations: [MapKitHostedAnnotation] = positions.compactMap { position in
			let coordinate = position.offlineMapCoordinate
			guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
			return MapKitHostedAnnotation(coordinate: coordinate, payload: .position(position))
		}
		annotations.append(contentsOf: waypoints.compactMap { waypoint in
			let coordinate = waypoint.offlineMapCoordinate
			guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
			return MapKitHostedAnnotation(coordinate: coordinate, payload: .waypoint(waypoint))
		})
		annotations.append(contentsOf: importedPoints.compactMap { importedPoint in
			guard CLLocationCoordinate2DIsValid(importedPoint.coordinate) else { return nil }
			return MapKitHostedAnnotation(coordinate: importedPoint.coordinate, payload: .importedPoint(importedPoint))
		})
		if let userCoordinate, CLLocationCoordinate2DIsValid(userCoordinate) {
			annotations.append(MapKitHostedAnnotation(coordinate: userCoordinate, payload: .userLocation))
		}
		return annotations
	}

	func makeStyledOverlays() -> (overlays: [MKOverlay], styles: [String: MapKitShapeStyle]) {
		guard showsStyledOverlays else {
			return ([], [:])
		}

		var overlays: [MKOverlay] = []
		var styles: [String: MapKitShapeStyle] = [:]

		for (index, polyline) in polylines.enumerated() where polyline.coordinates.count > 1 {
			let id = "\(MapKitShapeStyle.titlePrefix)polyline-\(index)"
			let overlay = MKPolyline(coordinates: polyline.coordinates, count: polyline.coordinates.count)
			overlay.title = id
			overlays.append(overlay)
			styles[id] = MapKitShapeStyle(id: id, strokeColor: UIColor(polyline.color), fillColor: .clear, lineWidth: polyline.lineWidth, alpha: 1)
		}

		for (index, polygon) in polygons.enumerated() where polygon.coordinates.count > 2 {
			let id = "\(MapKitShapeStyle.titlePrefix)polygon-\(index)"
			let overlay = MKPolygon(coordinates: polygon.closedCoordinates, count: polygon.closedCoordinates.count)
			overlay.title = id
			overlays.append(overlay)
			styles[id] = MapKitShapeStyle(id: id, strokeColor: UIColor(polygon.stroke), fillColor: UIColor(polygon.fill), lineWidth: polygon.lineWidth, alpha: 1)
		}

		for (index, circle) in circles.enumerated() {
			let id = "\(MapKitShapeStyle.titlePrefix)circle-\(index)"
			let overlay = MKCircle(center: circle.center, radius: circle.radius)
			overlay.title = id
			overlays.append(overlay)
			styles[id] = MapKitShapeStyle(id: id, strokeColor: UIColor(circle.stroke), fillColor: UIColor(circle.fill), lineWidth: circle.lineWidth, alpha: 1)
		}

		return (overlays, styles)
	}
}

private final class TransparentMapKitTileOverlay: MKTileOverlay {
	override init(urlTemplate URLTemplate: String? = nil) {
		super.init(urlTemplate: URLTemplate)
		canReplaceMapContent = true
		minimumZ = 0
		maximumZ = 22
	}
}

private final class TransparentMapKitTileOverlayRenderer: MKTileOverlayRenderer {
	override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {}
}

private final class TransparentAnnotationMapView: MKMapView {
	override func layoutSubviews() {
		super.layoutSubviews()
		keepMapContentTransparent()
	}

	func keepMapContentTransparent() {
		backgroundColor = .clear
		isOpaque = false
		clearOpaqueMapSurfaces(in: self)
	}

	private func clearOpaqueMapSurfaces(in view: UIView) {
		for subview in view.subviews {
			subview.backgroundColor = .clear
			subview.isOpaque = false
			if subview is MKAnnotationView {
				subview.alpha = 1
				subview.isHidden = false
				continue
			}
			if isMapRenderingSurface(subview), !containsAnnotationView(subview) {
				subview.alpha = 0
				subview.isHidden = true
				continue
			}
			clearOpaqueMapSurfaces(in: subview)
		}
	}

	private func containsAnnotationView(_ view: UIView) -> Bool {
		if view is MKAnnotationView { return true }
		return view.subviews.contains { containsAnnotationView($0) }
	}

	private func isMapRenderingSurface(_ view: UIView) -> Bool {
		let typeName = String(describing: type(of: view))
		return typeName.contains("VK") ||
			typeName.contains("Vector") ||
			typeName.contains("Tile") ||
			typeName.contains("Label") ||
			typeName.contains("Canvas") ||
			typeName.contains("Render")
	}
}

private enum MapKitHostedAnnotationPayload {
	case position(PositionEntity)
	case waypoint(WaypointEntity)
	case importedPoint(ImportedPoint)
	case userLocation
}

private final class MapKitHostedAnnotation: NSObject, MKAnnotation {
	let coordinate: CLLocationCoordinate2D
	let payload: MapKitHostedAnnotationPayload

	var title: String? {
		switch payload {
		case .position(let position):
			position.offlineMapTitle
		case .waypoint(let waypoint):
			waypoint.offlineMapTitle
		case .importedPoint(let importedPoint):
			importedPoint.title
		case .userLocation:
			"Phone Location"
		}
	}

	var subtitle: String? {
		switch payload {
		case .position(let position):
			position.offlineMapSubtitle
		case .waypoint(let waypoint):
			waypoint.offlineMapSubtitle
		case .importedPoint, .userLocation:
			nil
		}
	}

	var reuseIdentifier: String {
		switch payload {
		case .position:
			"offline-mapkit-position"
		case .waypoint:
			"offline-mapkit-waypoint"
		case .importedPoint:
			"offline-mapkit-imported-point"
		case .userLocation:
			"offline-mapkit-user-location"
		}
	}

	init(coordinate: CLLocationCoordinate2D, payload: MapKitHostedAnnotationPayload) {
		self.coordinate = coordinate
		self.payload = payload
	}
}

private struct MapKitShapeStyle {
	static let titlePrefix = "offline-mapkit-shape:"

	let id: String
	let strokeColor: UIColor
	let fillColor: UIColor
	let lineWidth: CGFloat
	let alpha: CGFloat
}

private final class MapKitSwiftUIAnnotationView: MKAnnotationView {
	private var hostingController: UIHostingController<AnyView>?

	override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
		super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
		configureBaseView()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		configureBaseView()
	}

	override func prepareForReuse() {
		super.prepareForReuse()
		hostingController?.rootView = AnyView(EmptyView())
	}

	func setContent<Content: View>(_ content: Content, size: CGSize) {
		bounds = CGRect(origin: .zero, size: size)
		centerOffset = CGPoint(x: 0, y: 0)
		let rootView = AnyView(content.frame(width: size.width, height: size.height))
		if let hostingController {
			hostingController.rootView = rootView
			hostingController.view.frame = bounds
		} else {
			let hostingController = UIHostingController(rootView: rootView)
			hostingController.view.backgroundColor = .clear
			hostingController.view.isUserInteractionEnabled = false
			hostingController.view.frame = bounds
			addSubview(hostingController.view)
			self.hostingController = hostingController
		}
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		hostingController?.view.frame = bounds
	}

	private func configureBaseView() {
		backgroundColor = .clear
		isOpaque = false
		canShowCallout = false
		isEnabled = true
		displayPriority = .required
		collisionMode = .none
	}
}

private extension NativeMapPolygon {
	var closedCoordinates: [CLLocationCoordinate2D] {
		guard let first = coordinates.first, let last = coordinates.last else { return coordinates }
		if first.latitude == last.latitude && first.longitude == last.longitude {
			return coordinates
		}
		return coordinates + [first]
	}
}

private extension NativeMapCircle {
	var polygonCoordinates: [CLLocationCoordinate2D] {
		let vertexCount = 64
		let earthRadius = 6_378_137.0
		let centerLatitude = center.latitude * .pi / 180
		let centerLongitude = center.longitude * .pi / 180
		let angularDistance = radius / earthRadius
		var coordinates: [CLLocationCoordinate2D] = []
		coordinates.reserveCapacity(vertexCount + 1)

		for index in 0...vertexCount {
			let bearing = 2 * .pi * Double(index) / Double(vertexCount)
			let latitude = asin(
				sin(centerLatitude) * cos(angularDistance) +
				cos(centerLatitude) * sin(angularDistance) * cos(bearing)
			)
			let longitude = centerLongitude + atan2(
				sin(bearing) * sin(angularDistance) * cos(centerLatitude),
				cos(angularDistance) - sin(centerLatitude) * sin(latitude)
			)
			coordinates.append(
				CLLocationCoordinate2D(
					latitude: latitude * 180 / .pi,
					longitude: SlippyMapProjection.normalizedLongitude(longitude * 180 / .pi)
				)
			)
		}
		return coordinates
	}
}

private struct NativeOSMTileView: View {
	let tile: OfflineMapTile
	let server: MapTileServer
	let importedTileSourceID: String
	let allowsNetworkLoad: Bool

	@State private var image: UIImage?
	@State private var currentTileLoadID = ""

	private var tileLoadID: String {
		"\(server.id)-\(importedTileSourceID)-\(tile.z)-\(tile.x)-\(tile.y)-\(allowsNetworkLoad)"
	}

	var body: some View {
		ZStack {
			Rectangle()
				.fill(Color(uiColor: .secondarySystemBackground))
			if let image {
				Image(uiImage: image)
					.resizable()
					.interpolation(.medium)
			}
		}
		.task(id: tileLoadID) {
			await loadTile()
		}
	}

	private func loadTile() async {
		let loadID = tileLoadID
		await MainActor.run {
			if currentTileLoadID != loadID {
				currentTileLoadID = loadID
				image = nil
			}
		}

		let data = await OfflineTileManager.shared.loadTileData(
			for: tile,
			server: server,
			importedTileSourceID: importedTileSourceID,
			allowsNetworkLoad: allowsNetworkLoad
		)
		guard !Task.isCancelled else { return }
		await MainActor.run {
			guard currentTileLoadID == loadID else { return }
			image = data.flatMap(UIImage.init(data:))
		}
	}
}

private struct NativeMapOverlayCanvas: View {
	let polylines: [NativeMapPolyline]
	let polygons: [NativeMapPolygon]
	let circles: [NativeMapCircle]
	let renderContext: SlippyMapRenderContext

	var body: some View {
		Canvas { context, _ in
			for polygon in polygons {
				let path = path(for: polygon.coordinates, close: true)
				context.fill(path, with: .color(polygon.fill))
				context.stroke(path, with: .color(polygon.stroke), lineWidth: polygon.lineWidth)
			}
			for circle in circles {
				let center = renderContext.point(for: circle.center)
				let radius = renderContext.screenRadius(center: circle.center, meters: circle.radius)
				let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
				let path = Path(ellipseIn: rect)
				context.fill(path, with: .color(circle.fill))
				context.stroke(path, with: .color(circle.stroke), lineWidth: circle.lineWidth)
			}
			for polyline in polylines {
				let path = path(for: polyline.coordinates, close: false)
				context.stroke(
					path,
					with: .color(polyline.color),
					style: StrokeStyle(
						lineWidth: polyline.lineWidth,
						lineCap: .round,
						lineJoin: .round,
						dash: polyline.dashed ? [10, 8] : []
					)
				)
			}
		}
		.allowsHitTesting(false)
	}

	private func path(for coordinates: [CLLocationCoordinate2D], close: Bool) -> Path {
		var path = Path()
		guard let firstCoordinate = coordinates.first else { return path }
		path.move(to: renderContext.point(for: firstCoordinate))
		for coordinate in coordinates.dropFirst() {
			path.addLine(to: renderContext.point(for: coordinate))
		}
		if close {
			path.closeSubpath()
		}
		return path
	}
}

private struct ImportedPoint: Identifiable {
	let id: String
	let coordinate: CLLocationCoordinate2D
	let title: String
}

private struct OfflineImportedPointView: View {
	let title: String

	var body: some View {
		Image(systemName: "mappin.circle.fill")
			.symbolRenderingMode(.palette)
			.foregroundStyle(.white, .teal)
			.font(.title2)
			.shadow(radius: 2)
			.accessibilityLabel(title)
	}
}

private struct UserLocationAnnotation: View {
	var body: some View {
		ZStack {
			Circle()
				.fill(.blue.opacity(0.18))
				.frame(width: 36, height: 36)
			Circle()
				.fill(.blue)
				.stroke(.white, lineWidth: 3)
				.frame(width: 18, height: 18)
		}
		.shadow(radius: 2)
		.accessibilityLabel("Phone Location")
	}
}

private struct OfflinePositionAnnotation: View {
	let position: PositionEntity
	let style: OfflineMapAnnotationStyle
	var showsOnlinePulse = true
	var showsTitle = false
	@State private var scale: CGFloat = 0.5

	var body: some View {
		if showsTitle, let labelTitle {
			VStack(spacing: 3) {
				markerBody
				OfflineAnnotationTitle(text: labelTitle)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			markerBody
		}
	}

	@ViewBuilder
	private var markerBody: some View {
		if position.latest {
			switch style {
			case .mesh:
				meshLatestAnnotation
			case .node:
				nodeLatestAnnotation
			}
		} else {
			historyAnnotation
		}
	}

	private var meshLatestAnnotation: some View {
		ZStack {
			if showsOnlinePulse, position.nodePosition?.isOnline ?? false {
				Circle()
					.fill(Color(nodeColor.lighter()).opacity(0.4).shadow(.drop(color: Color(nodeColor).isLight() ? .black : .white, radius: 5)))
					.foregroundStyle(Color(nodeColor.lighter()).opacity(0.3))
					.scaleEffect(scale)
					.animation(Animation.easeInOut(duration: 0.6).repeatForever(), value: scale)
					.onAppear {
						scale = 1
					}
					.frame(width: 60, height: 60)
			}
			if position.nodePosition?.hasDetectionSensorMetrics ?? false {
				Image(systemName: "sensor.fill")
					.symbolRenderingMode(.palette)
					.symbolEffect(.variableColor)
					.padding()
					.foregroundStyle(.white)
					.background(Color(nodeColor))
					.clipShape(Circle())
			} else {
				CircleText(text: position.nodePosition?.user?.shortName ?? "?", color: Color(nodeColor), circleSize: 40)
			}
		}
	}

	private var nodeLatestAnnotation: some View {
		ZStack {
			Circle()
				.fill(Color(nodeColor.lighter()).opacity(0.4).shadow(.drop(color: Color(nodeColor).isLight() ? .black : .white, radius: 5)))
				.foregroundStyle(Color(nodeColor.lighter()).opacity(0.3))
				.frame(width: 50, height: 50)
			Image(systemName: nodeSymbolName)
				.symbolEffect(.pulse.byLayer)
				.padding(5)
				.foregroundStyle(Color(nodeColor).isLight() ? .black : .white)
				.background(Color(nodeColor.darker()))
				.clipShape(Circle())
				.rotationEffect(headingDegrees)
		}
	}

	private var historyAnnotation: some View {
		Group {
			if positionFlags.contains(.Heading) {
				Image(systemName: "location.north.circle")
					.resizable()
					.scaledToFit()
					.foregroundStyle(Color(nodeColor).isLight() ? .black : .white)
					.background(Color(nodeColor))
					.clipShape(Circle())
					.rotationEffect(headingDegrees)
					.frame(width: 16, height: 16)
			} else {
				Circle()
					.fill(Color(nodeColor))
					.strokeBorder(Color(nodeColor).isLight() ? .black : .white, lineWidth: 2)
					.frame(width: 12, height: 12)
			}
		}
	}

	private var nodeColor: UIColor {
		UIColor(hex: UInt32(position.nodePosition?.num ?? 0))
	}

	private var positionFlags: PositionFlags {
		PositionFlags(rawValue: Int(position.nodePosition?.metadata?.positionFlags ?? 771))
	}

	private var headingDegrees: Angle {
		Angle.degrees(Double(position.heading))
	}

	private var nodeSymbolName: String {
		if positionFlags.contains(.Heading) {
			return positionFlags.contains(.Speed) && position.speed > 1 ? "location.north" : "octagon"
		}
		return "flipphone"
	}

	private var labelTitle: String? {
		if let longName = position.nodePosition?.user?.longName, !longName.isEmpty {
			return longName
		}
		if let shortName = position.nodePosition?.user?.shortName, !shortName.isEmpty {
			return shortName
		}
		return nil
	}
}

private struct OfflineWaypointAnnotation: View {
	let waypoint: WaypointEntity
	var showsTitle = false

	var body: some View {
		if showsTitle, let title = waypoint.name, !title.isEmpty {
			VStack(spacing: 3) {
				waypointMarker
				OfflineAnnotationTitle(text: title)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		} else {
			waypointMarker
		}
	}

	private var waypointMarker: some View {
		CircleText(
			text: String(UnicodeScalar(Int(waypoint.icon)) ?? "📍"),
			color: Color.orange,
			circleSize: 40
		)
	}
}

private struct OfflineAnnotationTitle: View {
	let text: String

	var body: some View {
		Text(text)
			.font(.caption2.weight(.semibold))
			.lineLimit(1)
			.minimumScaleFactor(0.8)
			.foregroundStyle(.primary)
			.padding(.horizontal, 6)
			.padding(.vertical, 3)
			.background(.regularMaterial, in: Capsule())
			.shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
	}
}

private enum OfflineLocationTrackingState {
	case none
	case centered
	case heading
}

private struct MapKitStyleMapControlButton: View {
	let systemImage: String
	let isActive: Bool
	let accessibilityLabel: String
	let accessibilityHint: String
	var action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.symbolRenderingMode(.hierarchical)
				.font(.system(size: 19, weight: .semibold))
				.foregroundStyle(isActive ? Color.accentColor : Color.primary)
				.frame(width: 32, height: 32)
				.contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
		}
		.buttonStyle(.plain)
		.background(isActive ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
		.accessibilityLabel(accessibilityLabel)
		.accessibilityHint(accessibilityHint)
	}
}

private struct MapKitStyleLocationButton: View {
	let trackingState: OfflineLocationTrackingState
	var action: () -> Void

	var body: some View {
		MapKitStyleMapControlButton(
			systemImage: systemImage,
			isActive: trackingState != .none,
			accessibilityLabel: accessibilityLabel,
			accessibilityHint: "Cycles offline map location tracking between off, centered, and heading follow.",
			action: action
		)
	}

	private var systemImage: String {
		switch trackingState {
		case .none:
			return "location"
		case .centered:
			return "location.fill"
		case .heading:
			return "location.north.line.fill"
		}
	}

	private var accessibilityLabel: String {
		switch trackingState {
		case .none:
			return "Center on my location"
		case .centered:
			return "Follow my heading"
		case .heading:
			return "Stop following heading"
		}
	}
}

private struct MapKitStyleCompassButton: View {
	var action: () -> Void

	var body: some View {
		MapKitStyleMapControlButton(
			systemImage: "safari",
			isActive: false,
			accessibilityLabel: "Reset map compass",
			accessibilityHint: "Rotates the offline map back to north.",
			action: action
		)
	}
}

private struct MapKitStyle3DButton: View {
	let isActive: Bool
	var action: () -> Void

	var body: some View {
		MapKitStyleMapControlButton(
			systemImage: "view.3d",
			isActive: isActive,
			accessibilityLabel: isActive ? "Turn off 3D map" : "Turn on 3D map",
			accessibilityHint: "Toggles pitched 3D mode for the offline vector map.",
			action: action
		)
	}
}

@MainActor
final class OfflineMapConnectivityMonitor: ObservableObject {
	static let shared = OfflineMapConnectivityMonitor()

	@Published private(set) var isOffline = false

	private let monitor = NWPathMonitor()
	private let queue = DispatchQueue(label: "meshtastic.offline-map-connectivity")

	private init() {
		monitor.pathUpdateHandler = { [weak self] path in
			Task { @MainActor in
				self?.isOffline = path.status != .satisfied
			}
		}
		monitor.start(queue: queue)
	}
}

struct OfflineMapAvailablePrompt: View {
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(systemName: "wifi.slash")
					.font(.headline)
				VStack(alignment: .leading, spacing: 2) {
					Text("Offline maps available")
						.font(.subheadline.weight(.semibold))
					Text("Use downloaded map data while the phone is offline.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer(minLength: 8)
				Image(systemName: "chevron.right")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 14)
			.padding(.vertical, 12)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.stroke(.white.opacity(0.25), lineWidth: 1)
			}
			.shadow(color: .black.opacity(0.18), radius: 12, y: 5)
			.padding(.horizontal, 12)
		}
		.buttonStyle(.plain)
		.accessibilityLabel("Use offline maps")
		.accessibilityHint("Switches the map to downloaded offline map data.")
	}
}

struct OfflineMeshMapView: View {
	let positions: [PositionEntity]
	let waypoints: [WaypointEntity]
	let routes: [RouteEntity]
	@Binding var showUserLocation: Bool
	@Binding var showUserHeading: Bool
	@Binding var showTraffic: Bool
	@Binding var showPointsOfInterest: Bool
	@Binding var visibleRegion: MKCoordinateRegion?
	@Binding var selectedPosition: PositionEntity?
	@Binding var selectedWaypoint: WaypointEntity?
	let centerOnUserLocationRequest: Int
	var onLongPress: (CLLocationCoordinate2D) -> Void

	@AppStorage("meshMapShowNodeHistory") private var showNodeHistory = false
	@AppStorage("meshMapShowRouteLines") private var showRouteLines = false
	@AppStorage("enableMapConvexHull") private var showConvexHull = false
	@AppStorage("enableMapWaypoints") private var showWaypoints = false
	@AppStorage("mapTileServer") private var tileServer: MapTileServer = .openStreetMap
	@AppStorage("mapTilesAboveLabels") private var mapTilesAboveLabels = false
	@AppStorage("offlineImportedTileSourceID") private var importedTileSourceID = ""
	@AppStorage("offlineMapUse3DElevation") private var use3DElevation = false
	@ObservedObject private var tileManager = OfflineTileManager.shared

	var body: some View {
		OfflineMapView(
			positions: displayPositions,
			waypoints: waypoints,
			routes: routes,
			showNodeHistory: showNodeHistory,
				showRouteLines: showRouteLines,
				showConvexHull: showConvexHull,
				showWaypoints: showWaypoints,
				showUserLocation: $showUserLocation,
				showUserHeading: $showUserHeading,
				showTraffic: showTraffic,
			showPointsOfInterest: showPointsOfInterest,
			tileServer: tileServer,
			mapTilesAboveLabels: mapTilesAboveLabels,
			importedTileSourceID: importedTileSourceID,
			use3DElevation: use3DElevation,
			importedMapContent: tileManager.importedMapContent(),
			annotationStyle: .mesh,
			centerOnUserLocationRequest: centerOnUserLocationRequest,
			visibleRegion: $visibleRegion,
			selectedPosition: $selectedPosition,
			selectedWaypoint: $selectedWaypoint,
			onLongPress: onLongPress
		)
		.onAppear {
			UserDefaults.migrateNativeOSMRendererSourceIfNeeded()
			tileServer = UserDefaults.mapTileServer
		}
	}

	private var displayPositions: [PositionEntity] {
		guard showNodeHistory else { return positions }

		let history = positions.flatMap { position -> [PositionEntity] in
			guard position.nodePosition?.favorite == true else { return [] }
			return (position.nodePosition?.positions ?? []).filter { !$0.latest }
		}
		return positions + history
	}
}

struct OfflineNodeMapView: View {
	let node: NodeInfoEntity
	let positions: [PositionEntity]
	@Binding var showUserLocation: Bool
	@Binding var showUserHeading: Bool
	@Binding var showTraffic: Bool
	@Binding var showPointsOfInterest: Bool
	@Binding var visibleRegion: MKCoordinateRegion?
	@Binding var selectedPosition: PositionEntity?
	let centerOnUserLocationRequest: Int
	@State private var selectedWaypoint: WaypointEntity?

	@AppStorage("meshMapShowNodeHistory") private var showNodeHistory = false
	@AppStorage("meshMapShowRouteLines") private var showRouteLines = false
	@AppStorage("enableMapConvexHull") private var showConvexHull = false
	@AppStorage("mapTileServer") private var tileServer: MapTileServer = .openStreetMap
	@AppStorage("mapTilesAboveLabels") private var mapTilesAboveLabels = false
	@AppStorage("offlineImportedTileSourceID") private var importedTileSourceID = ""
	@AppStorage("offlineMapUse3DElevation") private var use3DElevation = false
	@ObservedObject private var tileManager = OfflineTileManager.shared

	var body: some View {
		OfflineMapView(
			positions: positions,
			waypoints: [],
			routes: [],
			showNodeHistory: showNodeHistory,
			showRouteLines: showRouteLines,
			showConvexHull: showConvexHull,
			showWaypoints: false,
			showUserLocation: $showUserLocation,
			showUserHeading: $showUserHeading,
			showTraffic: showTraffic,
			showPointsOfInterest: showPointsOfInterest,
			tileServer: tileServer,
			mapTilesAboveLabels: mapTilesAboveLabels,
			importedTileSourceID: importedTileSourceID,
			use3DElevation: use3DElevation,
			importedMapContent: tileManager.importedMapContent(),
			annotationStyle: .node,
			centerOnUserLocationRequest: centerOnUserLocationRequest,
			visibleRegion: $visibleRegion,
			selectedPosition: $selectedPosition,
			selectedWaypoint: $selectedWaypoint,
			onLongPress: nil
		)
		.onAppear {
			UserDefaults.migrateNativeOSMRendererSourceIfNeeded()
			tileServer = UserDefaults.mapTileServer
		}
	}
}

private extension MKMultiPoint {
	var coordinates: [CLLocationCoordinate2D] {
		var coordinates = Array(repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
		getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
		return coordinates.filter(CLLocationCoordinate2DIsValid)
	}
}

private extension MapTileServer {
	var shortAttribution: String {
		switch self {
		case .openStreetMap, .openStreetMapDE, .openStreetMapFR, .openCycleMap, .openStreetMapHot, .openTopoMap:
			return "© OpenStreetMap contributors"
		case .usgsTopo, .usgsImageryTopo, .usgsImageryOnly:
			return "USGS National Map"
		case .terrain, .toner, .watercolor:
			return description
		}
	}

	var attributionURL: URL {
		switch self {
		case .openStreetMap, .openStreetMapDE, .openStreetMapFR, .openCycleMap, .openStreetMapHot, .openTopoMap:
			return URL(string: "https://www.openstreetmap.org/copyright")!
		case .usgsTopo, .usgsImageryTopo, .usgsImageryOnly:
			return URL(string: "https://www.usgs.gov/programs/national-geospatial-program/national-map")!
		case .terrain, .toner:
			return URL(string: "https://stamen.com")!
		case .watercolor:
			return URL(string: "https://watercolormaps.collection.cooperhewitt.org")!
		}
	}
}
