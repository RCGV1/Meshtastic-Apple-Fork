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

	func testOpenStreetMapIsDefaultNativeOfflineSource() {
		XCTAssertEqual(MapTileServer.openStreetMap.normalizedOfflineDownloadSource, .openStreetMap)
		XCTAssertEqual(MapTileServer.defaultOfflineDownloadSource, .openStreetMap)
		XCTAssertEqual(MapTileServer.offlineDownloadSources, [.openStreetMap])
		XCTAssertEqual(MapTileServer.openStreetMapHot.normalizedOfflineDownloadSource, .openStreetMap)
		XCTAssertEqual(MapTileServer.openTopoMap.normalizedOfflineDownloadSource, .openStreetMap)
		XCTAssertEqual(MapTileServer.usgsTopo.normalizedOfflineDownloadSource, .openStreetMap)
		XCTAssertEqual(MapTileServer.openStreetMap.offlineDisplayZoomRange.upperBound, 22)
	}

	func testOfflineVectorMapStylePersistsWithFallback() {
		let key = UserDefaults.Keys.offlineVectorMapStyle.rawValue
		let previousValue = UserDefaults.standard.object(forKey: key)
		defer {
			if let previousValue {
				UserDefaults.standard.set(previousValue, forKey: key)
			} else {
				UserDefaults.standard.removeObject(forKey: key)
			}
		}

		UserDefaults.offlineVectorMapStyle = .dark
		XCTAssertEqual(UserDefaults.offlineVectorMapStyle, .dark)

		UserDefaults.standard.set("not-a-style", forKey: key)
		XCTAssertEqual(UserDefaults.offlineVectorMapStyle, .liberty)
	}

	func testOfflineDownloadRegionBoundsRoundTrip() {
		let region = MKCoordinateRegion(
			center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
			span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.4)
		)

		let bounds = OfflineMapRegionBounds(region: region)
		let roundTrip = bounds.coordinateRegion

		XCTAssertEqual(roundTrip.center.latitude, region.center.latitude, accuracy: 0.000_001)
		XCTAssertEqual(roundTrip.center.longitude, region.center.longitude, accuracy: 0.000_001)
		XCTAssertEqual(roundTrip.span.latitudeDelta, region.span.latitudeDelta, accuracy: 0.000_001)
		XCTAssertEqual(roundTrip.span.longitudeDelta, region.span.longitudeDelta, accuracy: 0.000_001)
	}

	func testOfflineDownloadRegionCodableRoundTrip() throws {
		let region = MKCoordinateRegion(
			center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
			span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.4)
		)
		let download = OfflineMapDownloadRegion(
			id: "bay-area",
			name: "Bay Area",
			server: .openTopoMap,
			bounds: OfflineMapRegionBounds(region: region),
			minimumZoom: 8,
			maximumZoom: 14,
			tileCount: 42,
			byteCount: 1_024,
			createdAt: Date(timeIntervalSince1970: 100),
			updatedAt: Date(timeIntervalSince1970: 200)
		)

		let data = try JSONEncoder().encode(download)
		let decoded = try JSONDecoder().decode(OfflineMapDownloadRegion.self, from: data)

		XCTAssertEqual(decoded, download)
	}

	func testRasterNativeStyleFileUsesCachedTileTemplate() throws {
		let styleURL = try XCTUnwrap(OfflineTileManager.shared.rasterNativeStyleURL(for: .openStreetMap))
		let data = try Data(contentsOf: styleURL)
		let style = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		let sources = try XCTUnwrap(style["sources"] as? [String: Any])
		let source = try XCTUnwrap(sources["meshtastic-offline-raster"] as? [String: Any])
		let tiles = try XCTUnwrap(source["tiles"] as? [String])

		XCTAssertTrue(styleURL.isFileURL)
		XCTAssertEqual(source["type"] as? String, "raster")
		XCTAssertEqual(source["tileSize"] as? Int, 256)
		XCTAssertTrue(tiles.first?.contains("openStreetMap-z{z}x{x}y{y}.png") == true)
	}

	func testNativeFarZoomDownloadUsesHighestSourceZoom() {
		let region = MKCoordinateRegion(
			center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
			span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
		)

		let estimate = OfflineTileManager.shared.downloadEstimate(
			in: region,
			server: .openStreetMap,
			zoomRange: 19...22
		)

		XCTAssertGreaterThan(estimate.tileCount, 0)
		XCTAssertEqual(estimate.requestedZoomRange, 19...22)
		XCTAssertEqual(estimate.sourceZoomRange, 18...18)
		XCTAssertTrue(estimate.usesScaledNativeZoom)
	}

	func testSlippyProjectionRoundTripsCoordinate() {
		let coordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
		let pixel = SlippyMapProjection.pixel(for: coordinate, zoom: 12)
		let roundTrip = SlippyMapProjection.coordinate(for: pixel, zoom: 12)

		XCTAssertEqual(roundTrip.latitude, coordinate.latitude, accuracy: 0.000_001)
		XCTAssertEqual(roundTrip.longitude, coordinate.longitude, accuracy: 0.000_001)
	}

	func testSlippyProjectionWrapsAntimeridianTileX() {
		XCTAssertEqual(SlippyMapProjection.wrappedTileX(-1, zoom: 3), 7)
		XCTAssertEqual(SlippyMapProjection.wrappedTileX(8, zoom: 3), 0)
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
