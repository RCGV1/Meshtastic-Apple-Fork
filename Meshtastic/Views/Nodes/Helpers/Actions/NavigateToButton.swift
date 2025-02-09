//
//  NavigateToButton.swift
//  Meshtastic
//
//  Created by Benjamin Faershtein on 2/8/25.
//

import SwiftUI
import CoreLocation
import CoreData

struct NavigateToButton: View {
	var node: NodeInfoEntity

	var body: some View {
		Button {
			guard let userNum = node.user?.num else {
				return
			}
			
			let fetchRequest: NSFetchRequest<NodeInfoEntity> = NSFetchRequest(entityName: "NodeInfoEntity")
			fetchRequest.predicate = NSPredicate(format: "num == %lld", Int64(userNum))
			
			do {
				let fetchedNodes = try PersistenceController.shared.container.viewContext.fetch(fetchRequest)
				
				guard let nodeInfo = fetchedNodes.first else {
					return
				}
				
				if let latitude = nodeInfo.latestPosition?.latitude,
				   let longitude = nodeInfo.latestPosition?.longitude,
				   let url = URL(string: "maps://?saddr=&daddr=\(latitude),\(longitude)") {
					UIApplication.shared.open(url, options: [:], completionHandler: nil)
				} else {
				}
			} catch {
			}
		} label: {
			Label {
				Text("Navigate to node")
			} icon: {
				Image(systemName: "map")
					.symbolRenderingMode(.hierarchical)
			}
		}
	}
}
