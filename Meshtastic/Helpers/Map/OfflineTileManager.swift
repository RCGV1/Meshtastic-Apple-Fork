//
//  OfflineTileManager.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 4/23/23.
//

import Foundation
import MapKit
import OSLog

struct OfflineMapTile: Hashable, Sendable {
	let x: Int
	let y: Int
	let z: Int
}

struct OfflineTileDownloadProgress: Equatable {
	var isActive = false
	var completed = 0
	var total = 0
	var failed = 0
	var styleName = ""

	var fractionCompleted: Double {
		guard total > 0 else { return 0 }
		return Double(completed) / Double(total)
	}
}

class OfflineTileManager: ObservableObject {
	static let shared = OfflineTileManager()

	// MARK: - Public properties

	@Published var status: DownloadStatus = .downloaded
	@Published private(set) var downloadProgress = OfflineTileDownloadProgress()

	enum DownloadStatus {
		case downloaded, downloading
	}

	init() {
		Logger.services.info("🗂️ Documents Directory = \(self.documentsDirectory.absoluteString, privacy: .public)")
		createDirectoriesIfNecessary()
	}

	// MARK: - Private properties

	private var documentsDirectory: URL { fileManager.urls(for: .documentDirectory, in: .userDomainMask).first! }
	private let fileManager = FileManager.default
	private let maximumConcurrentDownloads = 6

	// MARK: - Public methods

	func getAllDownloadedSize() -> String {
		fileManager.allocatedSizeOfDirectory(at: documentsDirectory.appendingPathComponent("tiles"))
	}

	func removeAll() {
		try? fileManager.removeItem(at: documentsDirectory.appendingPathComponent("tiles"))
		createDirectoriesIfNecessary()
	}

	func loadAndCacheTileOverlay(for path: MKTileOverlayPath, server: MapTileServer = UserDefaults.mapTileServer) async throws -> Data {
		guard UserDefaults.enableOfflineMaps, server.zoomRange.contains(path.z) else {
			return try alphaTileData()
		}

		let tile = OfflineMapTile(x: path.x, y: path.y, z: path.z)
		let tilesUrl = tileFileURL(for: tile, server: server)

		do {
			return try Data(contentsOf: tilesUrl)
		} catch let error as NSError where error.code == NSFileReadNoSuchFileError {
			await MainActor.run { self.status = .downloading }
			defer {
				Task { @MainActor in self.status = .downloaded }
			}
			do {
				return try await downloadTileData(tile, server: server)
			} catch {
				Logger.services.error("Failed to load offline map tile z\(tile.z) x\(tile.x) y\(tile.y): \(error.localizedDescription, privacy: .public)")
				return try alphaTileData()
			}
		} catch {
			Logger.services.error("Failed to read cached offline map tile: \(error.localizedDescription, privacy: .public)")
			return try alphaTileData()
		}
	}

	func estimatedTileCount(in region: MKCoordinateRegion?, server: MapTileServer, zoomRange: ClosedRange<Int>) -> Int {
		guard let region else { return 0 }
		return Self.tileCount(in: region, zoomRange: clampedZoomRange(zoomRange, for: server))
	}

	func downloadTiles(in region: MKCoordinateRegion, server: MapTileServer, zoomRange: ClosedRange<Int>) async {
		let tiles = Array(Self.tiles(in: region, zoomRange: clampedZoomRange(zoomRange, for: server)))
		guard !tiles.isEmpty else { return }

		await MainActor.run {
			self.status = .downloading
			self.downloadProgress = OfflineTileDownloadProgress(
				isActive: true,
				completed: 0,
				total: tiles.count,
				failed: 0,
				styleName: server.description
			)
		}

		var iterator = tiles.makeIterator()
		var completed = 0
		var failed = 0

		await withTaskGroup(of: Bool.self) { group in
			for _ in 0..<min(maximumConcurrentDownloads, tiles.count) {
				if let tile = iterator.next() {
					group.addTask { await self.cacheTileIfNeeded(tile, server: server) }
				}
			}

			while let succeeded = await group.next() {
				completed += 1
				if !succeeded {
					failed += 1
				}

				if completed % 10 == 0 || completed == tiles.count {
					let completedSnapshot = completed
					let failedSnapshot = failed
					await MainActor.run {
						self.downloadProgress.completed = completedSnapshot
						self.downloadProgress.failed = failedSnapshot
					}
				}

				if let tile = iterator.next() {
					group.addTask { await self.cacheTileIfNeeded(tile, server: server) }
				}
			}
		}

		let completedSnapshot = completed
		let failedSnapshot = failed
		await MainActor.run {
			self.status = .downloaded
			self.downloadProgress.completed = completedSnapshot
			self.downloadProgress.failed = failedSnapshot
			self.downloadProgress.isActive = false
		}
	}

	// MARK: Private methods

	private func createDirectoriesIfNecessary() {
		let tiles = documentsDirectory.appendingPathComponent("tiles")
		try? fileManager.createDirectory(at: tiles, withIntermediateDirectories: true, attributes: [:])
	}

	private func tileFileURL(for tile: OfflineMapTile, server: MapTileServer) -> URL {
		documentsDirectory
			.appendingPathComponent("tiles")
			.appendingPathComponent("\(server.id)-z\(tile.z)x\(tile.x)y\(tile.y)")
			.appendingPathExtension("png")
	}

	private func tileURL(for tile: OfflineMapTile, server: MapTileServer) -> URL? {
		let urlString = server.tileUrl
			.replacingOccurrences(of: "{z}", with: "\(tile.z)")
			.replacingOccurrences(of: "{x}", with: "\(tile.x)")
			.replacingOccurrences(of: "{y}", with: "\(tile.y)")
		return URL(string: urlString)
	}

	private func cacheTileIfNeeded(_ tile: OfflineMapTile, server: MapTileServer) async -> Bool {
		let fileURL = tileFileURL(for: tile, server: server)
		if fileManager.fileExists(atPath: fileURL.path) {
			return true
		}

		do {
			_ = try await downloadTileData(tile, server: server)
			return true
		} catch {
			Logger.services.error("Failed to cache offline map tile z\(tile.z) x\(tile.x) y\(tile.y): \(error.localizedDescription, privacy: .public)")
			return false
		}
	}

	private func downloadTileData(_ tile: OfflineMapTile, server: MapTileServer) async throws -> Data {
		guard let url = tileURL(for: tile, server: server) else {
			throw URLError(.badURL)
		}

		var request = URLRequest(url: url)
		request.setValue("Meshtastic Apple offline maps", forHTTPHeaderField: "User-Agent")

		let (data, response) = try await URLSession.shared.data(for: request)
		if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
			throw URLError(.badServerResponse)
		}

		createDirectoriesIfNecessary()
		try data.write(to: tileFileURL(for: tile, server: server), options: .atomic)
		return data
	}

	private func alphaTileData() throws -> Data {
		try Data(contentsOf: Bundle.main.url(forResource: "alpha", withExtension: "png")!)
	}

	private func clampedZoomRange(_ zoomRange: ClosedRange<Int>, for server: MapTileServer) -> ClosedRange<Int> {
		let serverMinZoom = server.zoomRange.first ?? 0
		let serverMaxZoom = server.zoomRange.last ?? 18
		let lowerBound = min(max(zoomRange.lowerBound, serverMinZoom), serverMaxZoom)
		let upperBound = min(max(zoomRange.upperBound, serverMinZoom), serverMaxZoom)
		return min(lowerBound, upperBound)...max(lowerBound, upperBound)
	}

	private static func tiles(in region: MKCoordinateRegion, zoomRange: ClosedRange<Int>) -> Set<OfflineMapTile> {
		var tiles = Set<OfflineMapTile>()

		for range in tileRanges(in: region, zoomRange: zoomRange) {
			for xRange in range.xRanges {
				for x in xRange {
					for y in range.yRange {
						tiles.insert(OfflineMapTile(x: x, y: y, z: range.zoom))
					}
				}
			}
		}

		return tiles
	}

	private static func tileCount(in region: MKCoordinateRegion, zoomRange: ClosedRange<Int>) -> Int {
		tileRanges(in: region, zoomRange: zoomRange).reduce(0) { partialResult, range in
			let xCount = range.xRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound + 1) }
			let yCount = range.yRange.upperBound - range.yRange.lowerBound + 1
			return partialResult + (xCount * yCount)
		}
	}

	private static func tileRanges(in region: MKCoordinateRegion, zoomRange: ClosedRange<Int>) -> [(zoom: Int, xRanges: [ClosedRange<Int>], yRange: ClosedRange<Int>)] {
		let minLatitude = max(-85.051_128_78, region.center.latitude - region.span.latitudeDelta / 2)
		let maxLatitude = min(85.051_128_78, region.center.latitude + region.span.latitudeDelta / 2)
		let longitudeDelta = min(max(region.span.longitudeDelta, 0), 360)

		return zoomRange.map { zoom in
			let minY = latitudeToTileY(maxLatitude, zoom: zoom)
			let maxY = latitudeToTileY(minLatitude, zoom: zoom)
			return (
				zoom: zoom,
				xRanges: tileXRanges(centerLongitude: region.center.longitude, longitudeDelta: longitudeDelta, zoom: zoom),
				yRange: min(minY, maxY)...max(minY, maxY)
			)
		}
	}

	private static func tileXRanges(centerLongitude: CLLocationDegrees, longitudeDelta: CLLocationDegrees, zoom: Int) -> [ClosedRange<Int>] {
		let tileLimit = (1 << zoom) - 1
		guard longitudeDelta < 360 else { return [0...tileLimit] }

		let minLongitude = normalizedLongitude(centerLongitude - longitudeDelta / 2)
		let maxLongitude = normalizedLongitude(centerLongitude + longitudeDelta / 2)

		if minLongitude <= maxLongitude {
			return [longitudeToTileX(minLongitude, zoom: zoom)...longitudeToTileX(maxLongitude, zoom: zoom)]
		}

		return [
			longitudeToTileX(minLongitude, zoom: zoom)...tileLimit,
			0...longitudeToTileX(maxLongitude, zoom: zoom)
		]
	}

	private static func normalizedLongitude(_ longitude: CLLocationDegrees) -> CLLocationDegrees {
		var normalized = longitude
		while normalized < -180 { normalized += 360 }
		while normalized > 180 { normalized -= 360 }
		return normalized
	}

	private static func longitudeToTileX(_ longitude: CLLocationDegrees, zoom: Int) -> Int {
		let tileCount = Double(1 << zoom)
		let x = floor((normalizedLongitude(longitude) + 180) / 360 * tileCount)
		return min(max(Int(x), 0), Int(tileCount) - 1)
	}

	private static func latitudeToTileY(_ latitude: CLLocationDegrees, zoom: Int) -> Int {
		let tileCount = Double(1 << zoom)
		let latitudeRadians = latitude * .pi / 180
		let y = floor((1 - log(tan(latitudeRadians) + 1 / cos(latitudeRadians)) / .pi) / 2 * tileCount)
		return min(max(Int(y), 0), Int(tileCount) - 1)
	}
}
