//
//  EncryptionStatusView.swift
//  Meshtastic
//
//  Created by Benjamin Faershtein on 10/27/25.
//

import SwiftUI

struct EncryptionStatusView: View {
	var node: NodeInfoEntity
	@Environment(\.managedObjectContext) private var context
	@EnvironmentObject var accessoryManager: AccessoryManager

	// Helper to get connected node
	private var connectedNode: NodeInfoEntity? {
		getNodeInfo(id: accessoryManager.activeDeviceNum ?? 0, context: context)
	}
	
	// Computed public key
	private var publicKeyString: String {
		guard let user = node.user, user.keyMatch else { return "" }
		return node.num == connectedNode?.num
			? node.securityConfig?.publicKey?.base64EncodedString() ?? ""
			: user.publicKey?.base64EncodedString() ?? ""
	}
	
	var body: some View {
		List {
			// MARK: - Status Card
			Section {
				VStack(alignment: .leading, spacing: 12) {
					Image(systemName: iconName)
						.font(.system(size: 32))
						.foregroundColor(iconColor)
					
					Text(statusTitle)
						.font(.title2)
						.fontWeight(.bold)
					
					Text(statusDescription)
						.font(.subheadline)
						.foregroundColor(.secondary)
					if showRequires {
						Text("Requires firmware version 2.5 or greater.")
							.font(.subheadline)
							.foregroundColor(.secondary)
					}
					if accessoryManager.activeDeviceNum != node.num {
						if node.user?.isKeyManuallyVerified == true {
							Text("The public key has been mannually verified and this node can be trusted")
						} else {
							Text("The public key has not been manually verified and direct messages cannot be trusted. Please do not send sensitive information to a node without verifying the public key you are sending to over a trusted channel (physically, over the internet, or with a messages app).")
						}
					}
					Link("Learn more", destination: URL(string: "https://meshtastic.org/docs/overview/encryption/")!)
						.font(.subheadline)
						.foregroundColor(.blue)
				}
				.padding(.vertical, 8)
			}
			
			// MARK: - Public Key Copy (Only if encrypted and keyMatch)
			if let user = node.user, user.keyMatch, !publicKeyString.isEmpty {
				Section("Public Key") {
					HStack {
						Image(systemName: "key.horizontal.fill")
							.foregroundColor(.green)
						Text("Copy Public Key")
						
						Spacer()
						
						Button(action: copyPublicKey) {
							HStack(spacing: 4) {
								Image(systemName: "doc.on.doc")
								Text("Copy")
							}
							.font(.caption)
							.foregroundColor(.blue)
						}
						.buttonStyle(.plain)
					}
				}
			}
		}
		.navigationTitle("Encryption")
		.navigationBarTitleDisplayMode(.inline)
	}
	
	// MARK: - Computed Properties
	private var iconName: String {
		if let user = node.user {
			return user.keyMatch ? "lock.fill" : "key.slash.fill"
		}
		return "lock.open"
	}
	
	private var iconColor: Color {
		if let user = node.user {
			return user.keyMatch ? .green : .red
		}
		return .yellow
	}
	
	private var statusTitle: String {
		if let user = node.user {
			return user.keyMatch ? "Encrypted" : "Public Key Mismatch"
		}
		return "Unencrypted"
	}
	
	private var statusDescription: String {
		if let user = node.user {
			if user.keyMatch {
				return "Direct messages are using the new public key infrastructure for encryption."
			} else {
				return "Verify who you are messaging with by comparing public keys in person or over the phone. The most recent public key for this node does not match the previously recorded key. You can delete the node and let it exchange keys again if the key change was due to a factory reset or other intentional action but this also may indicate a more serious security problem."
			}
		}
		return "Direct messages are not using encryption."
	}
	
	private var showRequires: Bool {
		node.user?.keyMatch == true
	}
	
	// MARK: - Actions
	private func copyPublicKey() {
		UIPasteboard.general.string = publicKeyString
		// Optional: Add haptic feedback
		let generator = UINotificationFeedbackGenerator()
		generator.notificationOccurred(.success)
	}
}

