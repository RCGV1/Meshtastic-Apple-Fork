//
//  TileOverlay.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 5/5/23.
//

import Foundation
import MapKit

class TileOverlay: MKTileOverlay {
	private let tileServer: MapTileServer
	private let importedTileSourceID: String

	init(tileServer: MapTileServer = UserDefaults.mapTileServer, importedTileSourceID: String = UserDefaults.offlineImportedTileSourceID) {
		self.tileServer = tileServer
		self.importedTileSourceID = importedTileSourceID
		super.init(urlTemplate: importedTileSourceID.isEmpty ? tileServer.tileUrl : nil)
		canReplaceMapContent = true
		if let importedTileSource = OfflineTileManager.shared.importedTileSource(id: importedTileSourceID) {
			minimumZ = importedTileSource.minimumZoom ?? 0
			maximumZ = importedTileSource.maximumZoom ?? 18
		} else {
			minimumZ = tileServer.zoomRange.first ?? 0
			maximumZ = tileServer.zoomRange.last ?? 18
		}
	}

	override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
		if !importedTileSourceID.isEmpty {
			return try OfflineTileManager.shared.loadImportedTileOverlay(for: path, importedTileSourceID: importedTileSourceID)
				?? OfflineTileManager.shared.transparentTileData()
		}
		return try await OfflineTileManager.shared.loadAndCacheTileOverlay(for: path, server: tileServer)
	}
}
