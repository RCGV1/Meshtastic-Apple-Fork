//
//  NodeHardwareView.swift
//  Meshtastic
//
//  Created by Benjamin Faershtein on 10/27/25.
//

import SwiftUI

struct NodeHardwareView: View {
	@ObservedObject var node: NodeInfoEntity
	@State private var deviceHardware: DeviceHardware?
	
	var body: some View {
		List {
			Section {
				VStack(alignment: .center, spacing: 16) {
					// Hardware Image
					if let hwImage = node.user?.hardwareImage, hwImage != "UNSET" {
						Image(hwImage)
							.resizable()
							.aspectRatio(contentMode: .fit)
							.frame(maxHeight: 200)
							.cornerRadius(8)
					} else {
						Image(systemName: "flipphone")
							.font(.system(size: 80))
							.foregroundColor(.secondary)
							.frame(height: 150)
					}
					
					// Hardware Name
					Text(node.user?.hwDisplayName ?? node.user?.hwModel ?? "Unknown Hardware")
						.font(.title2)
						.fontWeight(.semibold)
						.multilineTextAlignment(.center)
					
					// Support Status
					if let device = deviceHardware {
						HStack {
							Image(systemName: device.activelySupported ? "checkmark.seal.fill" : "seal.fill")
								.foregroundColor(device.activelySupported ? .green : .orange)
							Text(device.activelySupported ? "Full Support" : "Community Support")
								.font(.subheadline)
								.foregroundColor(.secondary)
						}
					}
				}
				.frame(maxWidth: .infinity)
				.padding()
			}
			.listRowInsets(.init())
			.listRowBackground(Color.clear)
			
			// Hardware Details
			if let user = node.user {
				Section("Details") {
					if user.hwModel != "UNSET" {
						LabeledContent("Model") {
							Text(user.hwModel ?? "Unknown")
								.textSelection(.enabled)
						}
					}
					if let metadata = node.metadata {
						LabeledContent("Firmware") {
							Text(metadata.firmwareVersion ?? "Unknown")
						}
					}
					if let channelUtil = node.latestDeviceMetrics?.channelUtilization {
						LabeledContent("Channel Utilization") {
							Text("\(String(format: "%.1f", channelUtil))%")
						}
					}
					if let airtime = node.latestDeviceMetrics?.airUtilTx {
						LabeledContent("Airtime TX") {
							Text("\(String(format: "%.1f", airtime))%")
						}
					}
				}
			}
		}
		.navigationTitle("Hardware")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear {
			loadHardwareInfo()
		}
	}
	
	private func loadHardwareInfo() {
		guard deviceHardware == nil, let hwModel = node.user?.hwModel, hwModel != "UNSET" else { return }
		
		Api().loadDeviceHardwareData { devices in
			let normalizedModel = hwModel.replacingOccurrences(of: "_", with: "").uppercased()
			deviceHardware = devices.first { device in
				let slug = device.hwModelSlug.replacingOccurrences(of: "_", with: "").uppercased()
				return slug == normalizedModel
			}
		}
	}
}
