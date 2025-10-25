//
//  GeoImageOverlay.swift
//  Meshtastic
//
//  Georeferenced image overlay primitives for MapKit/SwiftUI
//

import Foundation
import MapKit
import UIKit

/// Geographic bounding box for a georeferenced image
struct GeographicBounds: Hashable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    var topLeft: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: maxLat, longitude: minLon)
    }

    var topRight: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
    }

    var bottomLeft: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: minLat, longitude: minLon)
    }

    var bottomRight: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: minLat, longitude: maxLon)
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
    }

    var mapRect: MKMapRect {
        let topLeftPoint = MKMapPoint(topLeft)
        let bottomRightPoint = MKMapPoint(bottomRight)

        return MKMapRect(
            x: min(topLeftPoint.x, bottomRightPoint.x),
            y: min(topLeftPoint.y, bottomRightPoint.y),
            width: abs(bottomRightPoint.x - topLeftPoint.x),
            height: abs(bottomRightPoint.y - topLeftPoint.y)
        )
    }
}

/// Data representing a single georeferenced image tile (e.g., from a GeoTIFF)
struct GeoImageTile: Hashable {
    let id: UUID
    let bounds: GeographicBounds
    let image: UIImage
    let opacity: Double

    init(id: UUID, bounds: GeographicBounds, image: UIImage, opacity: Double = 0.7) {
        self.id = id
        self.bounds = bounds
        self.image = image
        self.opacity = opacity
    }
}

/// MKOverlay subclass to hold a georeferenced image
final class GeoImageOverlay: NSObject, MKOverlay {
    let tile: GeoImageTile

    init(tile: GeoImageTile) {
        self.tile = tile
        super.init()
    }

    var coordinate: CLLocationCoordinate2D { tile.bounds.center }
    var boundingMapRect: MKMapRect { tile.bounds.mapRect }
}

/// MKOverlayRenderer that draws the georeferenced image within its boundingMapRect
final class GeoImageOverlayRenderer: MKOverlayRenderer {
    private let image: UIImage
    private let opacity: Double

    init(overlay: GeoImageOverlay) {
        self.image = overlay.tile.image
        self.opacity = overlay.tile.opacity
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let imageRef = image.cgImage else { return }

        // Only draw if the requested mapRect intersects our overlay
        let rectToDraw = overlay.boundingMapRect.intersection(mapRect)
        if rectToDraw.isNull { return }

        // Convert the overlay's full rect to the renderer's coordinate space
        let fullRect = self.rect(for: overlay.boundingMapRect)

        context.saveGState()
        // Flip vertically to match CoreGraphics coordinates
        context.translateBy(x: fullRect.minX, y: fullRect.maxY)
        context.scaleBy(x: 1.0, y: -1.0)
        context.setAlpha(opacity)

        let drawRect = CGRect(x: 0, y: 0, width: fullRect.width, height: fullRect.height)
        context.draw(imageRef, in: drawRect)
        context.restoreGState()
    }
}
