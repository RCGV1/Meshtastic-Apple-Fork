//
//  ContentView.swift
//  MeshtasticWatch Watch App
//
//  Created by Benjamin Faershtein on 4/26/25.
//

import SwiftUI
import WatchConnectivity
import MapKit

struct ContentView: View {
	
	var body: some View {
		VStack {
			Map {
				UserAnnotation()

			}
			.mapControls {
						MapCompass()
					}
		}
	}
}

#Preview {
	ContentView()
}
