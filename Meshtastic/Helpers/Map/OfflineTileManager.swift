//
//  OfflineTileManager.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 4/23/23.
//

import Foundation
import MapKit
import OSLog
import SQLite3
import UIKit

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

struct OfflineTileDownloadEstimate: Equatable {
	let tileCount: Int
	let estimatedBytes: Int64
	let currentTileBytes: Int64

	var projectedTileBytes: Int64 {
		currentTileBytes + estimatedBytes
	}
}

enum OfflineMapImportKind: String, Codable {
	case kml
	case kmz
	case gpx
	case geoJSON
	case mbtiles
	case pmtiles
	case xyzDirectory
	case unknown

	var displayName: String {
		switch self {
		case .kml:
			return "KML"
		case .kmz:
			return "KMZ"
		case .gpx:
			return "GPX"
		case .geoJSON:
			return "GeoJSON"
		case .mbtiles:
			return "MBTiles"
		case .pmtiles:
			return "PMTiles"
		case .xyzDirectory:
			return "XYZ Tile Folder"
		case .unknown:
			return "Offline Data"
		}
	}

	var isVectorOverlay: Bool {
		switch self {
		case .kml, .gpx, .geoJSON:
			return true
		case .kmz, .mbtiles, .pmtiles, .xyzDirectory, .unknown:
			return false
		}
	}
}

struct OfflineMapImport: Codable, Equatable, Identifiable {
	let id: String
	var displayName: String
	var kind: OfflineMapImportKind
	var fileName: String
	var byteCount: Int64
	var importedAt: Date
	var minimumZoom: Int?
	var maximumZoom: Int?
	var tileFormat: String?
	var supportsRasterTiles: Bool
	var supports3D: Bool
}

struct OfflineMapImportedContent {
	var overlays: [MKOverlay] = []
	var annotations: [MKAnnotation] = []

	static let empty = OfflineMapImportedContent()
}

final class OfflineImportedPointAnnotation: NSObject, MKAnnotation {
	let coordinate: CLLocationCoordinate2D
	let title: String?
	let subtitle: String?

	init(coordinate: CLLocationCoordinate2D, title: String?, subtitle: String?) {
		self.coordinate = coordinate
		self.title = title
		self.subtitle = subtitle
	}
}

enum OfflineMapImportError: LocalizedError {
	case unsupportedFileType
	case unreadableSQLiteDatabase
	case sqliteError(String)

	var errorDescription: String? {
		switch self {
		case .unsupportedFileType:
			return "Unsupported offline map file. Import KML, GPX, GeoJSON, MBTiles, PMTiles, or an XYZ tile folder."
		case .unreadableSQLiteDatabase:
			return "Unable to open the MBTiles database."
		case .sqliteError(let message):
			return message
		}
	}
}

class OfflineTileManager: ObservableObject {
	static let shared = OfflineTileManager()

	// MARK: - Public properties

	@Published var status: DownloadStatus = .downloaded
	@Published private(set) var downloadProgress = OfflineTileDownloadProgress()
	@Published private(set) var imports: [OfflineMapImport] = []

	enum DownloadStatus {
		case downloaded, downloading
	}

	init() {
		Logger.services.info("🗂️ Documents Directory = \(self.documentsDirectory.absoluteString, privacy: .public)")
		createDirectoriesIfNecessary()
		loadImports()
	}

	// MARK: - Private properties

	private var documentsDirectory: URL { fileManager.urls(for: .documentDirectory, in: .userDomainMask).first! }
	private let fileManager = FileManager.default
	private let maximumConcurrentDownloads = 6
	private let importsFileName = "offline-map-imports.json"
	private var importedContentCache: [String: OfflineMapImportedContent] = [:]

	// MARK: - Public methods

	func getAllDownloadedSize() -> String {
		fileManager.allocatedSizeOfDirectory(at: documentsDirectory.appendingPathComponent("tiles"))
	}

	func downloadedTileByteCount() -> Int64 {
		allocatedByteCount(at: tilesDirectory)
	}

	func importedDataByteCount() -> Int64 {
		allocatedByteCount(at: importsDirectory)
	}

	func formattedByteCount(_ byteCount: Int64) -> String {
		ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
	}

	func downloadEstimate(in region: MKCoordinateRegion?, server: MapTileServer, zoomRange: ClosedRange<Int>) -> OfflineTileDownloadEstimate {
		let tileCount = estimatedTileCount(in: region, server: server, zoomRange: zoomRange)
		return OfflineTileDownloadEstimate(
			tileCount: tileCount,
			estimatedBytes: Int64(tileCount) * estimatedTileByteCount(for: server),
			currentTileBytes: downloadedTileByteCount()
		)
	}

	func removeAll() {
		try? fileManager.removeItem(at: tilesDirectory)
		createDirectoriesIfNecessary()
	}

	func importOfflineMapData(from url: URL) async throws -> OfflineMapImport {
		let shouldStopAccessing = url.startAccessingSecurityScopedResource()
		defer {
			if shouldStopAccessing {
				url.stopAccessingSecurityScopedResource()
			}
		}

		let kind = Self.importKind(for: url)
		guard kind != .unknown else {
			throw OfflineMapImportError.unsupportedFileType
		}

		createDirectoriesIfNecessary()
		let id = UUID().uuidString
		let destinationFileName = "\(id)-\(Self.safeFileName(url.lastPathComponent))"
		let destinationURL = importsDirectory.appendingPathComponent(destinationFileName)

		if fileManager.fileExists(atPath: destinationURL.path) {
			try fileManager.removeItem(at: destinationURL)
		}
		try fileManager.copyItem(at: url, to: destinationURL)

		var imported = OfflineMapImport(
			id: id,
			displayName: Self.defaultImportDisplayName(for: url),
			kind: kind,
			fileName: destinationFileName,
			byteCount: allocatedByteCount(at: destinationURL),
			importedAt: Date(),
			minimumZoom: nil,
			maximumZoom: nil,
			tileFormat: nil,
			supportsRasterTiles: false,
			supports3D: false
		)

		if kind == .mbtiles {
			let metadata = readMBTilesMetadata(at: destinationURL)
			imported.displayName = metadata.name ?? imported.displayName
			imported.minimumZoom = metadata.minimumZoom
			imported.maximumZoom = metadata.maximumZoom
			imported.tileFormat = metadata.format
			imported.supportsRasterTiles = Self.isSupportedRasterTileFormat(metadata.format)
		} else if kind == .xyzDirectory {
			let zoomBounds = readXYZZoomBounds(at: destinationURL)
			imported.minimumZoom = zoomBounds.minimum
			imported.maximumZoom = zoomBounds.maximum
			imported.supportsRasterTiles = zoomBounds.minimum != nil
		}

		let importedSnapshot = imported
		await MainActor.run {
			imports.append(importedSnapshot)
			imports.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
			saveImports()
			importedContentCache.removeValue(forKey: id)
		}

		return importedSnapshot
	}

	func removeImport(id: String) {
		guard let imported = imports.first(where: { $0.id == id }) else { return }
		try? fileManager.removeItem(at: importedFileURL(for: imported))
		imports.removeAll { $0.id == id }
		importedContentCache.removeValue(forKey: id)
		if UserDefaults.standard.string(forKey: UserDefaults.Keys.offlineImportedTileSourceID.rawValue) == id {
			UserDefaults.standard.set("", forKey: UserDefaults.Keys.offlineImportedTileSourceID.rawValue)
		}
		saveImports()
	}

	func importedTileSource(id: String) -> OfflineMapImport? {
		guard !id.isEmpty else { return nil }
		return imports.first { $0.id == id && $0.supportsRasterTiles }
	}

	func importedMapContent() -> OfflineMapImportedContent {
		var content = OfflineMapImportedContent()

		for imported in imports where imported.kind.isVectorOverlay {
			let importedContent = contentForImport(imported)
			content.overlays.append(contentsOf: importedContent.overlays)
			content.annotations.append(contentsOf: importedContent.annotations)
		}

		return content
	}

	func loadImportedTileOverlay(for path: MKTileOverlayPath, importedTileSourceID: String) throws -> Data? {
		guard let imported = importedTileSource(id: importedTileSourceID) else {
			return nil
		}
		let tile = OfflineMapTile(x: path.x, y: path.y, z: path.z)
		if let tileData = try loadImportedTileData(for: tile, imported: imported) {
			return tileData
		}
		return try loadParentTileData(
			for: tile,
			minimumZoom: imported.minimumZoom ?? 0,
			maximumZoom: imported.maximumZoom ?? tile.z,
			loadTileData: { parentTile in
				try self.loadImportedTileData(for: parentTile, imported: imported)
			}
		)
	}

	func loadCachedTileOverlay(for path: MKTileOverlayPath, server: MapTileServer = UserDefaults.mapTileServer) throws -> Data {
		let tile = OfflineMapTile(x: path.x, y: path.y, z: path.z)
		if server.zoomRange.contains(tile.z), let tileData = try loadCachedTileData(for: tile, server: server) {
			return tileData
		}

		let fallbackTileData = try loadParentTileData(
			for: tile,
			minimumZoom: server.zoomRange.first ?? 0,
			maximumZoom: min(server.zoomRange.last ?? tile.z, tile.z),
			loadTileData: { parentTile in
				try self.loadCachedTileData(for: parentTile, server: server)
			}
		)

		if let fallbackTileData {
			return fallbackTileData
		}
		return try alphaTileData()
	}

	private func loadImportedTileData(for tile: OfflineMapTile, imported: OfflineMapImport) throws -> Data? {
		switch imported.kind {
		case .mbtiles:
			return try loadMBTile(for: tile, imported: imported)
		case .xyzDirectory:
			return try loadXYZTile(for: tile, imported: imported)
		case .kml, .kmz, .gpx, .geoJSON, .pmtiles, .unknown:
			return nil
		}
	}

	func transparentTileData() throws -> Data {
		try alphaTileData()
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
		try? fileManager.createDirectory(at: tilesDirectory, withIntermediateDirectories: true, attributes: [:])
		try? fileManager.createDirectory(at: importsDirectory, withIntermediateDirectories: true, attributes: [:])
	}

	private var tilesDirectory: URL {
		documentsDirectory.appendingPathComponent("tiles")
	}

	private var importsDirectory: URL {
		documentsDirectory.appendingPathComponent("offline-map-imports")
	}

	private var importsFileURL: URL {
		importsDirectory.appendingPathComponent(importsFileName)
	}

	private func importedFileURL(for imported: OfflineMapImport) -> URL {
		importsDirectory.appendingPathComponent(imported.fileName)
	}

	private func tileFileURL(for tile: OfflineMapTile, server: MapTileServer) -> URL {
		tilesDirectory
			.appendingPathComponent("\(server.id)-z\(tile.z)x\(tile.x)y\(tile.y)")
			.appendingPathExtension("png")
	}

	private func loadCachedTileData(for tile: OfflineMapTile, server: MapTileServer) throws -> Data? {
		let fileURL = tileFileURL(for: tile, server: server)
		guard fileManager.fileExists(atPath: fileURL.path) else {
			return nil
		}
		return try Data(contentsOf: fileURL)
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
		request.setValue(Self.tileDownloadUserAgent, forHTTPHeaderField: "User-Agent")
		request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")

		let (data, response) = try await URLSession.shared.data(for: request)
		if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
			throw URLError(.badServerResponse)
		}
		guard Self.isRenderableTileData(data, response: response) else {
			throw URLError(.cannotDecodeContentData)
		}

		createDirectoriesIfNecessary()
		try data.write(to: tileFileURL(for: tile, server: server), options: .atomic)
		return data
	}

	private static var tileDownloadUserAgent: String {
		let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
		return "MeshtasticApple/\(version) (iOS; https://meshtastic.org)"
	}

	private static func isRenderableTileData(_ data: Data, response: URLResponse) -> Bool {
		if response.mimeType?.lowercased().hasPrefix("image/") == true {
			return true
		}
		return UIImage(data: data) != nil
	}

	private func alphaTileData() throws -> Data {
		try Data(contentsOf: Bundle.main.url(forResource: "alpha", withExtension: "png")!)
	}

	private func loadImports() {
		guard let data = try? Data(contentsOf: importsFileURL),
			  let storedImports = try? JSONDecoder().decode([OfflineMapImport].self, from: data) else {
			imports = []
			return
		}

		imports = storedImports.filter { fileManager.fileExists(atPath: importedFileURL(for: $0).path) }
	}

	private func saveImports() {
		createDirectoriesIfNecessary()
		guard let data = try? JSONEncoder().encode(imports) else { return }
		try? data.write(to: importsFileURL, options: .atomic)
	}

	private func estimatedTileByteCount(for server: MapTileServer) -> Int64 {
		let cachedTileURLs = (try? fileManager.contentsOfDirectory(at: tilesDirectory, includingPropertiesForKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey]))
			?? []
		let matchingTileURLs = cachedTileURLs.filter { $0.lastPathComponent.hasPrefix("\(server.id)-") }
		let cachedByteCounts = matchingTileURLs
			.prefix(250)
			.map { allocatedByteCount(at: $0) }
			.filter { $0 > 0 }

		guard !cachedByteCounts.isEmpty else {
			return server.fallbackEstimatedTileBytes
		}

		return cachedByteCounts.reduce(0, +) / Int64(cachedByteCounts.count)
	}

	private func allocatedByteCount(at url: URL) -> Int64 {
		var isDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
			return 0
		}

		if isDirectory.boolValue {
			guard let enumerator = fileManager.enumerator(
				at: url,
				includingPropertiesForKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
				options: []
			) else { return 0 }
			var byteCount: Int64 = 0
			for case let fileURL as URL in enumerator {
				byteCount += allocatedByteCount(at: fileURL)
			}
			return byteCount
		}

		do {
			let values = try url.resourceValues(forKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey])
			return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
		} catch {
			Logger.services.error("Failed to read offline map file size: \(error.localizedDescription, privacy: .public)")
			return 0
		}
	}

	static func importKind(for url: URL) -> OfflineMapImportKind {
		var isDirectory: ObjCBool = false
		if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
			return .xyzDirectory
		}

		switch url.pathExtension.lowercased() {
		case "kml":
			return .kml
		case "kmz":
			return .kmz
		case "gpx":
			return .gpx
		case "geojson", "json":
			return .geoJSON
		case "mbtiles":
			return .mbtiles
		case "pmtiles":
			return .pmtiles
		default:
			return .unknown
		}
	}

	private static func defaultImportDisplayName(for url: URL) -> String {
		let name = url.deletingPathExtension().lastPathComponent
		return name.isEmpty ? url.lastPathComponent : name
	}

	private static func safeFileName(_ fileName: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
		let scalars = fileName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
		let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
		return cleaned.isEmpty ? "offline-map-import" : cleaned
	}

	private static func isSupportedRasterTileFormat(_ format: String?) -> Bool {
		guard let format = format?.lowercased() else {
			return true
		}
		return ["png", "jpg", "jpeg", "webp"].contains(format)
	}

	private struct MBTilesMetadata {
		var name: String?
		var format: String?
		var minimumZoom: Int?
		var maximumZoom: Int?
	}

	private func readMBTilesMetadata(at url: URL) -> MBTilesMetadata {
		var metadata = MBTilesMetadata()
		guard let database = openSQLiteDatabase(at: url) else {
			return metadata
		}
		defer { sqlite3_close(database) }

		metadata.name = sqliteMetadataValue("name", database: database)
		metadata.format = sqliteMetadataValue("format", database: database)?.lowercased()
		metadata.minimumZoom = Int(sqliteMetadataValue("minzoom", database: database) ?? "")
		metadata.maximumZoom = Int(sqliteMetadataValue("maxzoom", database: database) ?? "")

		if metadata.minimumZoom == nil || metadata.maximumZoom == nil {
			let zoomBounds = readMBTilesZoomBounds(database: database)
			metadata.minimumZoom = metadata.minimumZoom ?? zoomBounds.minimum
			metadata.maximumZoom = metadata.maximumZoom ?? zoomBounds.maximum
		}

		return metadata
	}

	private func loadMBTile(for tile: OfflineMapTile, imported: OfflineMapImport) throws -> Data? {
		guard let database = openSQLiteDatabase(at: importedFileURL(for: imported)) else {
			throw OfflineMapImportError.unreadableSQLiteDatabase
		}
		defer { sqlite3_close(database) }

		let flippedY = (1 << tile.z) - 1 - tile.y
		let sql = "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1"
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
			throw OfflineMapImportError.sqliteError(sqliteErrorMessage(database))
		}
		defer { sqlite3_finalize(statement) }

		sqlite3_bind_int(statement, 1, Int32(tile.z))
		sqlite3_bind_int(statement, 2, Int32(tile.x))
		sqlite3_bind_int(statement, 3, Int32(flippedY))

		guard sqlite3_step(statement) == SQLITE_ROW,
			  let bytes = sqlite3_column_blob(statement, 0) else {
			return nil
		}

		return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
	}

	private func loadXYZTile(for tile: OfflineMapTile, imported: OfflineMapImport) throws -> Data? {
		let baseURL = importedFileURL(for: imported)
			.appendingPathComponent("\(tile.z)")
			.appendingPathComponent("\(tile.x)")
		let fileNames = [
			"\(tile.y).png",
			"\(tile.y).jpg",
			"\(tile.y).jpeg",
			"\(tile.y).webp"
		]

		for fileName in fileNames {
			let tileURL = baseURL.appendingPathComponent(fileName)
			if fileManager.fileExists(atPath: tileURL.path) {
				return try Data(contentsOf: tileURL)
			}
		}

		return nil
	}

	private func loadParentTileData(
		for tile: OfflineMapTile,
		minimumZoom: Int,
		maximumZoom: Int,
		loadTileData: (OfflineMapTile) throws -> Data?
	) throws -> Data? {
		let highestFallbackZoom = min(maximumZoom, tile.z - 1)
		guard tile.z > minimumZoom, highestFallbackZoom >= minimumZoom else {
			return nil
		}

		for zoom in stride(from: highestFallbackZoom, through: minimumZoom, by: -1) {
			let zoomDelta = tile.z - zoom
			guard zoomDelta > 0, zoomDelta < 23 else { continue }
			let scale = 1 << zoomDelta
			let parentTile = OfflineMapTile(x: tile.x / scale, y: tile.y / scale, z: zoom)
			guard let parentData = try loadTileData(parentTile) else {
				continue
			}
			return scaledChildTileData(from: parentData, targetTile: tile, sourceZoom: zoom)
		}

		return nil
	}

	private func scaledChildTileData(from data: Data, targetTile: OfflineMapTile, sourceZoom: Int) -> Data? {
		let zoomDelta = targetTile.z - sourceZoom
		guard zoomDelta > 0,
			  zoomDelta < 23,
			  let image = UIImage(data: data),
			  let sourceImage = image.cgImage else {
			return nil
		}

		let scale = 1 << zoomDelta
		let cropWidth = CGFloat(sourceImage.width) / CGFloat(scale)
		let cropHeight = CGFloat(sourceImage.height) / CGFloat(scale)
		let cropRect = CGRect(
			x: CGFloat(targetTile.x % scale) * cropWidth,
			y: CGFloat(targetTile.y % scale) * cropHeight,
			width: cropWidth,
			height: cropHeight
		).integral

		guard let croppedImage = sourceImage.cropping(to: cropRect) else {
			return nil
		}

		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		format.opaque = false
		let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
		return renderer.image { _ in
			UIImage(cgImage: croppedImage).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
		}.pngData()
	}

	private func openSQLiteDatabase(at url: URL) -> OpaquePointer? {
		var database: OpaquePointer?
		let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
		guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
			if let database {
				Logger.services.error("Failed to open SQLite offline map import: \(self.sqliteErrorMessage(database), privacy: .public)")
				sqlite3_close(database)
			}
			return nil
		}
		return database
	}

	private func sqliteMetadataValue(_ name: String, database: OpaquePointer?) -> String? {
		let sql = "SELECT value FROM metadata WHERE name = ? LIMIT 1"
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
			return nil
		}
		defer { sqlite3_finalize(statement) }

		let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
		sqlite3_bind_text(statement, 1, name, -1, transient)
		guard sqlite3_step(statement) == SQLITE_ROW,
			  let text = sqlite3_column_text(statement, 0) else {
			return nil
		}
		return String(cString: text)
	}

	private func readMBTilesZoomBounds(database: OpaquePointer?) -> (minimum: Int?, maximum: Int?) {
		let sql = "SELECT MIN(zoom_level), MAX(zoom_level) FROM tiles"
		var statement: OpaquePointer?
		guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
			return (nil, nil)
		}
		defer { sqlite3_finalize(statement) }

		guard sqlite3_step(statement) == SQLITE_ROW else {
			return (nil, nil)
		}

		return (Int(sqlite3_column_int(statement, 0)), Int(sqlite3_column_int(statement, 1)))
	}

	private func readXYZZoomBounds(at url: URL) -> (minimum: Int?, maximum: Int?) {
		let zoomDirectories = (try? fileManager.contentsOfDirectory(
			at: url,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: [.skipsHiddenFiles]
		)) ?? []

		let zooms = zoomDirectories.compactMap { zoomURL -> Int? in
			guard (try? zoomURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
				return nil
			}
			return Int(zoomURL.lastPathComponent)
		}

		return (zooms.min(), zooms.max())
	}

	private func sqliteErrorMessage(_ database: OpaquePointer?) -> String {
		guard let database, let message = sqlite3_errmsg(database) else {
			return "Unknown SQLite error."
		}
		return String(cString: message)
	}

	private func contentForImport(_ imported: OfflineMapImport) -> OfflineMapImportedContent {
		if let cachedContent = importedContentCache[imported.id] {
			return cachedContent
		}

		let content: OfflineMapImportedContent
		do {
			let data = try Data(contentsOf: importedFileURL(for: imported))
			switch imported.kind {
			case .kml:
				content = Self.parseKML(data: data, title: imported.displayName)
			case .gpx:
				content = Self.parseGPX(data: data, title: imported.displayName)
			case .geoJSON:
				content = Self.parseGeoJSON(data: data, title: imported.displayName)
			case .kmz, .mbtiles, .pmtiles, .xyzDirectory, .unknown:
				content = .empty
			}
		} catch {
			Logger.services.error("Failed to parse offline map import \(imported.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
			content = .empty
		}

		importedContentCache[imported.id] = content
		return content
	}

	private static func parseKML(data: Data, title: String) -> OfflineMapImportedContent {
		let parserDelegate = OfflineKMLParser(title: title)
		let parser = XMLParser(data: data)
		parser.delegate = parserDelegate
		guard parser.parse() else {
			return .empty
		}
		return parserDelegate.content
	}

	private static func parseGPX(data: Data, title: String) -> OfflineMapImportedContent {
		let parserDelegate = OfflineGPXParser(title: title)
		let parser = XMLParser(data: data)
		parser.delegate = parserDelegate
		guard parser.parse() else {
			return .empty
		}
		return parserDelegate.content
	}

	private static func parseGeoJSON(data: Data, title: String) -> OfflineMapImportedContent {
		guard let objects = try? MKGeoJSONDecoder().decode(data) else {
			return .empty
		}

		var content = OfflineMapImportedContent()
		for object in objects {
			appendGeoJSONObject(object, title: title, to: &content)
		}
		return content
	}

	private static func appendGeoJSONObject(_ object: MKGeoJSONObject, title: String, to content: inout OfflineMapImportedContent) {
		if let feature = object as? MKGeoJSONFeature {
			let featureTitle = geoJSONFeatureTitle(feature) ?? title
			for geometry in feature.geometry {
				appendMapShape(geometry, title: featureTitle, to: &content)
			}
			return
		}

		if let shape = object as? MKShape {
			appendMapShape(shape, title: title, to: &content)
		}
	}

	private static func appendMapShape(_ shape: MKShape, title: String, to content: inout OfflineMapImportedContent) {
		shape.title = shape.title ?? title

		if let overlay = shape as? MKOverlay {
			if shape.title?.hasPrefix("offline-import:") != true {
				shape.title = "offline-import:\(shape.title ?? title)"
			}
			content.overlays.append(overlay)
		} else {
			content.annotations.append(shape)
		}
	}

	private static func geoJSONFeatureTitle(_ feature: MKGeoJSONFeature) -> String? {
		guard let propertiesData = feature.properties,
			  let properties = try? JSONSerialization.jsonObject(with: propertiesData) as? [String: Any] else {
			return nil
		}
		return properties["name"] as? String ?? properties["title"] as? String
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

private final class OfflineKMLParser: NSObject, XMLParserDelegate {
	private let title: String
	private var activeElement = ""
	private var activeText = ""
	private(set) var content = OfflineMapImportedContent()

	init(title: String) {
		self.title = title
	}

	func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
		activeElement = elementName.lowercased()
		activeText = ""
	}

	func parser(_: XMLParser, foundCharacters string: String) {
		if activeElement == "coordinates" {
			activeText += string
		}
	}

	func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
		guard elementName.lowercased() == "coordinates" else { return }
		let coordinates = Self.parseKMLCoordinates(activeText)
		appendCoordinates(coordinates)
		activeText = ""
	}

	private func appendCoordinates(_ coordinates: [CLLocationCoordinate2D]) {
		if coordinates.count == 1, let coordinate = coordinates.first {
			content.annotations.append(
				OfflineImportedPointAnnotation(
					coordinate: coordinate,
					title: title,
					subtitle: "KML"
				)
			)
		} else if coordinates.count > 1 {
			let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
			polyline.title = "offline-import:\(title)"
			content.overlays.append(polyline)
		}
	}

	private static func parseKMLCoordinates(_ text: String) -> [CLLocationCoordinate2D] {
		text
			.split { $0.isWhitespace }
			.compactMap { coordinateText -> CLLocationCoordinate2D? in
				let parts = coordinateText.split(separator: ",")
				guard parts.count >= 2,
					  let longitude = CLLocationDegrees(String(parts[0])),
					  let latitude = CLLocationDegrees(String(parts[1])),
					  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
					return nil
				}
				return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
			}
	}
}

private final class OfflineGPXParser: NSObject, XMLParserDelegate {
	private let title: String
	private var currentTrackCoordinates: [CLLocationCoordinate2D] = []
	private var currentRouteCoordinates: [CLLocationCoordinate2D] = []
	private(set) var content = OfflineMapImportedContent()

	init(title: String) {
		self.title = title
	}

	func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
		let lowercasedElement = elementName.lowercased()
		guard ["trkpt", "rtept", "wpt"].contains(lowercasedElement),
			  let coordinate = Self.coordinate(from: attributeDict) else {
			return
		}

		switch lowercasedElement {
		case "trkpt":
			currentTrackCoordinates.append(coordinate)
		case "rtept":
			currentRouteCoordinates.append(coordinate)
		case "wpt":
			content.annotations.append(
				OfflineImportedPointAnnotation(
					coordinate: coordinate,
					title: title,
					subtitle: "GPX"
				)
			)
		default:
			break
		}
	}

	func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
		switch elementName.lowercased() {
		case "trkseg", "trk":
			appendPolylineIfNeeded(&currentTrackCoordinates)
		case "rte":
			appendPolylineIfNeeded(&currentRouteCoordinates)
		default:
			break
		}
	}

	func parserDidEndDocument(_: XMLParser) {
		appendPolylineIfNeeded(&currentTrackCoordinates)
		appendPolylineIfNeeded(&currentRouteCoordinates)
	}

	private func appendPolylineIfNeeded(_ coordinates: inout [CLLocationCoordinate2D]) {
		guard coordinates.count > 1 else {
			coordinates.removeAll(keepingCapacity: true)
			return
		}
		let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
		polyline.title = "offline-import:\(title)"
		content.overlays.append(polyline)
		coordinates.removeAll(keepingCapacity: true)
	}

	private static func coordinate(from attributes: [String: String]) -> CLLocationCoordinate2D? {
		guard let latitudeText = attributes["lat"],
			  let longitudeText = attributes["lon"],
			  let latitude = CLLocationDegrees(latitudeText),
			  let longitude = CLLocationDegrees(longitudeText) else {
			return nil
		}
		let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
		return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
	}
}

private extension MapTileServer {
	var fallbackEstimatedTileBytes: Int64 {
		switch self {
		case .watercolor:
			return 90_000
		case .usgsImageryTopo, .usgsImageryOnly:
			return 120_000
		case .terrain, .openTopoMap, .usgsTopo:
			return 75_000
		case .toner:
			return 35_000
		case .openStreetMap, .openStreetMapDE, .openStreetMapFR, .openCycleMap, .openStreetMapHot:
			return 55_000
		}
	}
}
