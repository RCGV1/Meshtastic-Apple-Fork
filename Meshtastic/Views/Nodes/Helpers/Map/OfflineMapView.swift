//
//  OfflineMapView.swift
//  Meshtastic
//
//  Created by Codex on 6/4/26.
//

import CoreLocation
import MapKit
import SwiftUI

enum OfflineMapAnnotationStyle {
	case mesh
	case node
}

struct OfflineMapView: UIViewRepresentable {
	let positions: [PositionEntity]
	let waypoints: [WaypointEntity]
	let routes: [RouteEntity]
	let showNodeHistory: Bool
	let showRouteLines: Bool
	let showConvexHull: Bool
	let showWaypoints: Bool
	let showUserLocation: Bool
	let showTraffic: Bool
	let showPointsOfInterest: Bool
	let tileServer: MapTileServer
	let mapTilesAboveLabels: Bool
	let annotationStyle: OfflineMapAnnotationStyle
	@Binding var visibleRegion: MKCoordinateRegion?
	@Binding var selectedPosition: PositionEntity?
	@Binding var selectedWaypoint: WaypointEntity?
	var onLongPress: ((CLLocationCoordinate2D) -> Void)?

	func makeUIView(context: Context) -> MKMapView {
		let mapView = MKMapView()
		mapView.delegate = context.coordinator
		mapView.isRotateEnabled = true
		mapView.isPitchEnabled = true
		mapView.showsScale = true
		mapView.showsCompass = true

		if onLongPress != nil {
			let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
			recognizer.minimumPressDuration = 0.5
			mapView.addGestureRecognizer(recognizer)
		}

		return mapView
	}

	func updateUIView(_ mapView: MKMapView, context: Context) {
		context.coordinator.parent = self
		mapView.delegate = context.coordinator
		configureBaseMap(mapView)
		configureOverlays(mapView, context: context)
		configureAnnotations(mapView, context: context)
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	private func configureBaseMap(_ mapView: MKMapView) {
		mapView.mapType = .standard
		mapView.showsTraffic = showTraffic
		mapView.showsUserLocation = showUserLocation
		mapView.pointOfInterestFilter = showPointsOfInterest ? .includingAll : .excludingAll
		mapView.preferredConfiguration.elevationStyle = .flat
	}

	private func configureOverlays(_ mapView: MKMapView, context: Context) {
		let nonTileOverlays = mapView.overlays.filter { !($0 is TileOverlay) }
		mapView.removeOverlays(nonTileOverlays)

		if context.coordinator.tileServer != tileServer || context.coordinator.mapTilesAboveLabels != mapTilesAboveLabels || !mapView.overlays.contains(where: { $0 is TileOverlay }) {
			let tileOverlays = mapView.overlays.filter { $0 is TileOverlay }
			mapView.removeOverlays(tileOverlays)
			let tileOverlay = TileOverlay(tileServer: tileServer)
			mapView.addOverlay(tileOverlay, level: mapTilesAboveLabels ? .aboveLabels : .aboveRoads)
			context.coordinator.tileServer = tileServer
			context.coordinator.mapTilesAboveLabels = mapTilesAboveLabels
		}

		addNodeRouteLines(to: mapView)
		addRoutes(to: mapView)
		addPrecisionCircles(to: mapView)
		addConvexHull(to: mapView)
	}

	private func configureAnnotations(_ mapView: MKMapView, context: Context) {
		let annotations = mapView.annotations.filter { !($0 is MKUserLocation) }
		mapView.removeAnnotations(annotations)

		let positionAnnotations = visiblePositions
		mapView.addAnnotations(positionAnnotations)
		if showWaypoints {
			mapView.addAnnotations(waypoints)
		}

		guard !context.coordinator.didSetInitialRegion else { return }
		context.coordinator.didSetInitialRegion = true
		let annotationsToFit = mapView.annotations.filter { !($0 is MKUserLocation) }
		if annotationsToFit.count > 1 {
			mapView.showAnnotations(annotationsToFit, animated: false)
		} else if let coordinate = positionAnnotations.first?.coordinate {
			mapView.setRegion(
				MKCoordinateRegion(
					center: coordinate,
					span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
				),
				animated: false
			)
		}
		let region = mapView.region
		let visibleRegionBinding = $visibleRegion
		DispatchQueue.main.async {
			visibleRegionBinding.wrappedValue = region
		}
	}

	private var visiblePositions: [PositionEntity] {
		if showNodeHistory {
			return positions
		}
		return positions.filter { $0.latest }
	}

	private func addNodeRouteLines(to mapView: MKMapView) {
		guard showRouteLines else { return }

		let latestPositions = positions.filter { $0.latest }
		for position in latestPositions {
			guard let node = position.nodePosition, node.favorite, let nodePositions = node.positions?.array as? [PositionEntity] else {
				continue
			}

			let coordinates = nodePositions.compactMap(\.nodeCoordinate)
			guard coordinates.count > 1 else { continue }
			let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
			polyline.title = "\(node.num)"
			mapView.addOverlay(polyline, level: .aboveLabels)
		}
	}

	private func addRoutes(to mapView: MKMapView) {
		for route in routes {
			guard let locations = route.locations?.array as? [LocationEntity] else { continue }
			let coordinates = locations.compactMap(\.locationCoordinate)
			guard coordinates.count > 1 else { continue }
			let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
			polyline.title = "route-\(route.color)"
			mapView.addOverlay(polyline, level: .aboveLabels)
		}
	}

	private func addPrecisionCircles(to mapView: MKMapView) {
		for position in visiblePositions where position.latest && 10...19 ~= position.precisionBits {
			let precision = PositionPrecision(rawValue: Int(position.precisionBits))
			let radius = precision?.precisionMeters ?? 0
			guard radius > 0 else { continue }
			let circle = MKCircle(center: position.coordinate, radius: radius)
			circle.title = "\(position.nodePosition?.num ?? 0)"
			mapView.addOverlay(circle, level: .aboveLabels)
		}
	}

	private func addConvexHull(to mapView: MKMapView) {
		guard showConvexHull else { return }
		let coordinates = positions
			.filter { $0.nodePosition?.viaMqtt == false }
			.compactMap(\.nodeCoordinate)
		guard coordinates.count > 2 else { return }
		let hull = coordinates.getConvexHull()
		let polygon = MKPolygon(coordinates: hull, count: hull.count)
		polygon.title = "convexHull"
		mapView.addOverlay(polygon, level: .aboveLabels)
	}

	final class Coordinator: NSObject, MKMapViewDelegate {
		var parent: OfflineMapView
		var didSetInitialRegion = false
		var tileServer: MapTileServer?
		var mapTilesAboveLabels: Bool?

		init(_ parent: OfflineMapView) {
			self.parent = parent
		}

		func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
			parent.visibleRegion = mapView.region
		}

		func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
			if let position = view.annotation as? PositionEntity {
				parent.selectedPosition = position
			} else if let waypoint = view.annotation as? WaypointEntity {
				parent.selectedWaypoint = waypoint
			}
		}

		func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
			if annotation is MKUserLocation {
				return nil
			}

			if let position = annotation as? PositionEntity {
				return positionAnnotationView(for: position, in: mapView)
			}

			if let waypoint = annotation as? WaypointEntity {
				return waypointAnnotationView(for: waypoint, in: mapView)
			}

			return nil
		}

		func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
			if let tileOverlay = overlay as? MKTileOverlay {
				return MKTileOverlayRenderer(tileOverlay: tileOverlay)
			}

			if let polyline = overlay as? MKPolyline {
				let renderer = MKPolylineRenderer(polyline: polyline)
				if polyline.title?.hasPrefix("route-") == true {
					let colorString = polyline.title?.replacingOccurrences(of: "route-", with: "") ?? "0"
					renderer.strokeColor = UIColor(hex: UInt32(colorString) ?? 0)
					renderer.lineWidth = 3
				} else {
					renderer.strokeColor = UIColor(hex: UInt32(polyline.title ?? "0") ?? 0).lighter()
					renderer.lineWidth = 4
					renderer.lineDashPattern = [10, 8]
				}
				return renderer
			}

			if let circle = overlay as? MKCircle {
				let renderer = MKCircleRenderer(circle: circle)
				let color = UIColor(hex: UInt32(circle.title ?? "0") ?? 0)
				renderer.fillColor = color.withAlphaComponent(0.25)
				renderer.strokeColor = UIColor.white.withAlphaComponent(0.9)
				renderer.lineWidth = 2
				return renderer
			}

			if let polygon = overlay as? MKPolygon {
				let renderer = MKPolygonRenderer(polygon: polygon)
				renderer.fillColor = UIColor.systemIndigo.withAlphaComponent(0.25)
				renderer.strokeColor = UIColor.systemBlue
				renderer.lineWidth = 3
				return renderer
			}

			return MKOverlayRenderer(overlay: overlay)
		}

		@objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
			guard recognizer.state == .began, let mapView = recognizer.view as? MKMapView else { return }
			let point = recognizer.location(in: mapView)
			parent.onLongPress?(mapView.convert(point, toCoordinateFrom: mapView))
			UINotificationFeedbackGenerator().notificationOccurred(.success)
		}

		private func positionAnnotationView(for position: PositionEntity, in mapView: MKMapView) -> MKAnnotationView {
			let view = mapView.dequeueReusableAnnotationView(withIdentifier: "offline-position") as? SwiftUIMapAnnotationView
				?? SwiftUIMapAnnotationView(annotation: position, reuseIdentifier: "offline-position")
			view.annotation = position
			view.canShowCallout = true
			view.displayPriority = position.latest ? .required : .defaultHigh
			view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
			view.setContent(
				OfflinePositionAnnotation(position: position, style: parent.annotationStyle),
				size: position.latest ? CGSize(width: 64, height: 64) : CGSize(width: 18, height: 18)
			)
			return view
		}

		private func waypointAnnotationView(for waypoint: WaypointEntity, in mapView: MKMapView) -> MKAnnotationView {
			let view = mapView.dequeueReusableAnnotationView(withIdentifier: "offline-waypoint") as? SwiftUIMapAnnotationView
				?? SwiftUIMapAnnotationView(annotation: waypoint, reuseIdentifier: "offline-waypoint")
			view.annotation = waypoint
			view.canShowCallout = true
			view.displayPriority = .required
			view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
			view.setContent(OfflineWaypointAnnotation(waypoint: waypoint), size: CGSize(width: 44, height: 44))
			return view
		}
	}
}

private final class SwiftUIMapAnnotationView: MKAnnotationView {
	private var hostingController: UIHostingController<AnyView>?

	func setContent<Content: View>(_ content: Content, size: CGSize) {
		bounds = CGRect(origin: .zero, size: size)
		backgroundColor = .clear

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
}

private struct OfflinePositionAnnotation: View {
	let position: PositionEntity
	let style: OfflineMapAnnotationStyle
	@State private var scale: CGFloat = 0.5

	var body: some View {
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
			if position.nodePosition?.isOnline ?? false {
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
}

private struct OfflineWaypointAnnotation: View {
	let waypoint: WaypointEntity

	var body: some View {
		CircleText(
			text: String(UnicodeScalar(Int(waypoint.icon)) ?? "📍"),
			color: Color.orange,
			circleSize: 40
		)
	}
}

struct OfflineMeshMapView: View {
	@Binding var showUserLocation: Bool
	@Binding var showTraffic: Bool
	@Binding var showPointsOfInterest: Bool
	@Binding var visibleRegion: MKCoordinateRegion?
	@Binding var selectedPosition: PositionEntity?
	@Binding var selectedWaypoint: WaypointEntity?
	var onLongPress: (CLLocationCoordinate2D) -> Void

	@AppStorage("meshMapShowNodeHistory") private var showNodeHistory = false
	@AppStorage("meshMapShowRouteLines") private var showRouteLines = false
	@AppStorage("enableMapConvexHull") private var showConvexHull = false
	@AppStorage("enableMapWaypoints") private var showWaypoints = false
	@AppStorage("mapTileServer") private var tileServer: MapTileServer = .openStreetMap
	@AppStorage("mapTilesAboveLabels") private var mapTilesAboveLabels = false

	@FetchRequest(fetchRequest: PositionEntity.allPositionsFetchRequest(), animation: .easeIn)
	var positions: FetchedResults<PositionEntity>

	@FetchRequest(fetchRequest: WaypointEntity.allWaypointssFetchRequest(), animation: .none)
	var waypoints: FetchedResults<WaypointEntity>

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(key: "name", ascending: true)],
		predicate: NSPredicate(format: "enabled == true", ""),
		animation: .none
	)
	private var routes: FetchedResults<RouteEntity>

	var body: some View {
		OfflineMapView(
			positions: displayPositions,
			waypoints: Array(waypoints),
			routes: Array(routes),
			showNodeHistory: showNodeHistory,
			showRouteLines: showRouteLines,
			showConvexHull: showConvexHull,
			showWaypoints: showWaypoints,
			showUserLocation: showUserLocation,
			showTraffic: showTraffic,
			showPointsOfInterest: showPointsOfInterest,
			tileServer: tileServer,
			mapTilesAboveLabels: mapTilesAboveLabels,
			annotationStyle: .mesh,
			visibleRegion: $visibleRegion,
			selectedPosition: $selectedPosition,
			selectedWaypoint: $selectedWaypoint,
			onLongPress: onLongPress
		)
	}

	private var displayPositions: [PositionEntity] {
		let latestPositions = Array(positions)
		guard showNodeHistory else { return latestPositions }

		let history = latestPositions.flatMap { position -> [PositionEntity] in
			guard position.nodePosition?.favorite == true else { return [] }
			return (position.nodePosition?.positions?.array as? [PositionEntity] ?? []).filter { !$0.latest }
		}
		return latestPositions + history
	}
}

struct OfflineNodeMapView: View {
	@ObservedObject var node: NodeInfoEntity
	@Binding var showUserLocation: Bool
	@Binding var showTraffic: Bool
	@Binding var showPointsOfInterest: Bool
	@Binding var visibleRegion: MKCoordinateRegion?
	@Binding var selectedPosition: PositionEntity?
	@State private var selectedWaypoint: WaypointEntity?

	@AppStorage("meshMapShowNodeHistory") private var showNodeHistory = false
	@AppStorage("meshMapShowRouteLines") private var showRouteLines = false
	@AppStorage("enableMapConvexHull") private var showConvexHull = false
	@AppStorage("mapTileServer") private var tileServer: MapTileServer = .openStreetMap
	@AppStorage("mapTilesAboveLabels") private var mapTilesAboveLabels = false

	var body: some View {
		OfflineMapView(
			positions: node.positions?.array as? [PositionEntity] ?? [],
			waypoints: [],
			routes: [],
			showNodeHistory: showNodeHistory,
			showRouteLines: showRouteLines,
			showConvexHull: showConvexHull,
			showWaypoints: false,
			showUserLocation: showUserLocation,
			showTraffic: showTraffic,
			showPointsOfInterest: showPointsOfInterest,
			tileServer: tileServer,
			mapTilesAboveLabels: mapTilesAboveLabels,
			annotationStyle: .node,
			visibleRegion: $visibleRegion,
			selectedPosition: $selectedPosition,
			selectedWaypoint: $selectedWaypoint,
			onLongPress: nil
		)
	}
}
