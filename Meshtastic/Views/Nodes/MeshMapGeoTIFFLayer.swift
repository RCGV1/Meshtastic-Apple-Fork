//
//  MeshMapGeoTIFFLayer.swift
//  Meshtastic
//
//  SwiftUI MapContent that renders georeferenced image overlays (GeoTIFF-like) for enabled IDs.
//

import SwiftUI
import MapKit
import UIKit

/// A minimal in-memory provider for georeferenced image tiles keyed by UUID.
/// Populate this registry elsewhere in the app when files are loaded and mark them enabled via `enabledOverlayConfigs` in MeshMap.
final class GeoImageRegistry {
    static let shared = GeoImageRegistry()
    private init() {}

    // Thread-safe simple storage (no external synchronization assumed for simplicity)
    private var storage: [UUID: GeoImageTile] = [:]

    func set(_ tile: GeoImageTile) {
        storage[tile.id] = tile
    }

    func remove(id: UUID) {
        storage.removeValue(forKey: id)
    }

    func tile(for id: UUID) -> GeoImageTile? {
        storage[id]
    }
}

// Custom overlay class (keep this the same)
class ImageOverlay: NSObject, MKOverlay {
	let coordinate: CLLocationCoordinate2D
	let boundingMapRect: MKMapRect
	let image: UIImage
	
	init(image: UIImage, bounds: GeographicBounds) {
		self.image = image
		self.coordinate = bounds.center
		
		let topLeft = MKMapPoint(bounds.topLeft)
		let bottomRight = MKMapPoint(bounds.bottomRight)
		
		self.boundingMapRect = MKMapRect(
			x: min(topLeft.x, bottomRight.x),
			y: min(topLeft.y, bottomRight.y),
			width: abs(topLeft.x - bottomRight.x),
			height: abs(topLeft.y - bottomRight.y)
		)
	}
}

// Custom renderer (keep this the same)
class ImageOverlayRenderer: MKOverlayRenderer {
	let image: UIImage
	
	init(overlay: ImageOverlay) {
		self.image = overlay.image
		super.init(overlay: overlay)
	}
	
	override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
		guard let imageRef = image.cgImage else { return }
		
		let rect = self.rect(for: overlay.boundingMapRect)
		
		context.saveGState()
		context.scaleBy(x: 1.0, y: -1.0)
		context.translateBy(x: 0, y: -rect.size.height)
		context.draw(imageRef, in: rect)
		context.restoreGState()
	}
}

// UPDATED: SwiftUI wrapper that takes multiple GeoTIFFs
struct GeoTIFFMapView: UIViewRepresentable {
	let geoTiffs: [ParsedGeoTIFF]
	let opacity: Double
	
	func makeUIView(context: Context) -> MKMapView {
		let mapView = MKMapView()
		mapView.delegate = context.coordinator
		return mapView
	}
	
	func updateUIView(_ mapView: MKMapView, context: Context) {
		mapView.removeOverlays(mapView.overlays)
		
		for geoTiff in geoTiffs {
			guard let image = geoTiff.rasterImage else { continue }
			let bounds = GeographicBounds(
				minLat: geoTiff.bounds.minLat,
				maxLat: geoTiff.bounds.maxLat,
				minLon: geoTiff.bounds.minLon,
				maxLon: geoTiff.bounds.maxLon
			)
			let overlay = ImageOverlay(image: image, bounds: bounds)
			mapView.addOverlay(overlay)
		}
		
		if let firstGeoTiff = geoTiffs.first {
			let region = MKCoordinateRegion(
				center: firstGeoTiff.coordinate,
				span: MKCoordinateSpan(
					latitudeDelta: abs(firstGeoTiff.bounds.maxLat - firstGeoTiff.bounds.minLat) * 1.2,
					longitudeDelta: abs(firstGeoTiff.bounds.maxLon - firstGeoTiff.bounds.minLon) * 1.2
				)
			)
			mapView.setRegion(region, animated: false)
		}
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(opacity: opacity)
	}
	
	class Coordinator: NSObject, MKMapViewDelegate {
		let opacity: Double
		
		init(opacity: Double) {
			self.opacity = opacity
		}
		
		func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
			if let imageOverlay = overlay as? ImageOverlay {
				let renderer = ImageOverlayRenderer(overlay: imageOverlay)
				renderer.alpha = CGFloat(opacity)
				return renderer
			}
			return MKOverlayRenderer(overlay: overlay)
		}
	}
}
