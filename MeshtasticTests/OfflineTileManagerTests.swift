import CoreLocation
import MapKit
import XCTest

@testable import Meshtastic

final class OfflineTileManagerTests: XCTestCase {

	func testEstimatedTileCountForWorldAtZoomZeroIsOne() {
		let region = MKCoordinateRegion(
			center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
			span: MKCoordinateSpan(latitudeDelta: 170, longitudeDelta: 360)
		)

		let tileCount = OfflineTileManager.shared.estimatedTileCount(
			in: region,
			server: .openStreetMap,
			zoomRange: 0...0
		)

		XCTAssertEqual(tileCount, 1)
	}

	func testEstimatedTileCountHandlesAntimeridianWrapping() {
		let region = MKCoordinateRegion(
			center: CLLocationCoordinate2D(latitude: 37.7749, longitude: 179.5),
			span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 4)
		)

		let tileCount = OfflineTileManager.shared.estimatedTileCount(
			in: region,
			server: .openStreetMap,
			zoomRange: 3...3
		)

		XCTAssertGreaterThan(tileCount, 0)
		XCTAssertLessThan(tileCount, 64)
	}

	func testEstimatedTileCountScalesWithZoomRange() {
		let region = MKCoordinateRegion(
			center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
			span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
		)

		let lowZoomCount = OfflineTileManager.shared.estimatedTileCount(
			in: region,
			server: .openStreetMap,
			zoomRange: 8...8
		)
		let widerZoomCount = OfflineTileManager.shared.estimatedTileCount(
			in: region,
			server: .openStreetMap,
			zoomRange: 8...12
		)

		XCTAssertGreaterThanOrEqual(widerZoomCount, lowZoomCount)
		XCTAssertGreaterThan(widerZoomCount, 0)
	}
}
