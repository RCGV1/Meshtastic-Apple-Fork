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

	func testDownloadEstimateIncludesProjectedStorage() {
		let region = MKCoordinateRegion(
			center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
			span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
		)

		let estimate = OfflineTileManager.shared.downloadEstimate(
			in: region,
			server: .openStreetMap,
			zoomRange: 8...10
		)

		XCTAssertGreaterThan(estimate.tileCount, 0)
		XCTAssertGreaterThan(estimate.estimatedBytes, 0)
		XCTAssertEqual(estimate.projectedTileBytes, estimate.currentTileBytes + estimate.estimatedBytes)
	}

	func testOfflineTileOverlayDoesNotUseLiveTileTemplateOrReplaceAppleMap() {
		let overlay = TileOverlay(tileServer: .openStreetMap, importedTileSourceID: "")

		XCTAssertNil(overlay.urlTemplate)
		XCTAssertFalse(overlay.canReplaceMapContent)
		XCTAssertEqual(overlay.minimumZ, 0)
		XCTAssertGreaterThanOrEqual(overlay.maximumZ, 22)
	}

	func testOpenStreetMapStoredSourceNormalizesForOfflineDownloads() {
		XCTAssertEqual(MapTileServer.openStreetMap.normalizedOfflineDownloadSource, .usgsTopo)
		XCTAssertTrue(MapTileServer.offlineDownloadSources.contains(.usgsTopo))
		XCTAssertFalse(MapTileServer.offlineDownloadSources.contains(.openStreetMap))
	}

	func testImportKindRecognizesOfflineMapFiles() throws {
		XCTAssertEqual(OfflineTileManager.importKind(for: URL(fileURLWithPath: "/tmp/trail.kml")), .kml)
		XCTAssertEqual(OfflineTileManager.importKind(for: URL(fileURLWithPath: "/tmp/track.gpx")), .gpx)
		XCTAssertEqual(OfflineTileManager.importKind(for: URL(fileURLWithPath: "/tmp/shape.geojson")), .geoJSON)
		XCTAssertEqual(OfflineTileManager.importKind(for: URL(fileURLWithPath: "/tmp/bay.mbtiles")), .mbtiles)
		XCTAssertEqual(OfflineTileManager.importKind(for: URL(fileURLWithPath: "/tmp/archive.pmtiles")), .pmtiles)

		let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directoryURL) }

		XCTAssertEqual(OfflineTileManager.importKind(for: directoryURL), .xyzDirectory)
	}
}
