//
//  PersistenceEntityExtenstion.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 11/28/21.
//

import CoreData
import CoreLocation
import MapKit
import SwiftUI

extension PositionEntity {
	
	static func allPositionsFetchRequest() -> NSFetchRequest<PositionEntity> {
		let request: NSFetchRequest<PositionEntity> = PositionEntity.fetchRequest()
		request.fetchLimit = 50
		//request.fetchBatchSize = 1
		//request.returnsObjectsAsFaults = true
		//request.includesSubentities = false
		request.returnsDistinctResults = true
		request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)]
		request.predicate = NSPredicate(format: "nodePosition != nil && latest == true && time >= %@", Calendar.current.date(byAdding: .day, value: -2, to: Date())! as NSDate)
		return request
	}

	var latitude: Double? {

		let d = Double(latitudeI)
		if d == 0 {
			return 0
		}
		return d / 1e7
	}

	var longitude: Double? {

		let d = Double(longitudeI)
		if d == 0 {
			return 0
		}
		return d / 1e7
	}

	var nodeCoordinate: CLLocationCoordinate2D? {
		if latitudeI != 0 && longitudeI != 0 {
			let coord = CLLocationCoordinate2D(latitude: latitude!, longitude: longitude!)
			return coord
		} else {
		   return nil
		}
	}

	var nodeLocation: CLLocation? {
		if latitudeI != 0 && longitudeI != 0 {
			let location = CLLocation(latitude: latitude!, longitude: longitude!)
			return location
		} else {
		   return nil
		}
	}

	var annotaton: MKPointAnnotation {
		let pointAnn = MKPointAnnotation()
		if nodeCoordinate != nil {
			pointAnn.coordinate = nodeCoordinate!
		}
		return pointAnn
	}
}

extension PositionEntity: MKAnnotation {
	public var coordinate: CLLocationCoordinate2D { nodeCoordinate ?? LocationHelper.DefaultLocation }
	public var title: String? {  nodePosition?.user?.shortName ?? "unknown".localized }
	public var subtitle: String? {  time?.formatted() }
}
