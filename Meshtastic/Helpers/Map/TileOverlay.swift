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
		super.init(urlTemplate: nil)
		canReplaceMapContent = false
		minimumZ = 0
		maximumZ = 22
	}

	override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
		if !importedTileSourceID.isEmpty {
			return try OfflineTileManager.shared.loadImportedTileOverlay(for: path, importedTileSourceID: importedTileSourceID)
				?? OfflineTileManager.shared.transparentTileData()
		}
		return try OfflineTileManager.shared.loadCachedTileOverlay(for: path, server: tileServer)
	}
}
