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

	init(tileServer: MapTileServer = UserDefaults.mapTileServer) {
		self.tileServer = tileServer
		super.init(urlTemplate: tileServer.tileUrl)
		canReplaceMapContent = true
		minimumZ = tileServer.zoomRange.first ?? 0
		maximumZ = tileServer.zoomRange.last ?? 18
	}

	override func loadTile(at path: MKTileOverlayPath) async throws -> Data {
		return try await OfflineTileManager.shared.loadAndCacheTileOverlay(for: path, server: tileServer)
	}
}
