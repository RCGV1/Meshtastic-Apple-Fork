//
//  ChannelMessageList.swift
//  Meshtastic
//
//  Created by Garth Vander Houwen on 12/24/21.
//

import CoreData
import MeshtasticProtobufs
import OSLog
import SwiftUI

struct ChannelMessageList: View {
	@EnvironmentObject var appState: AppState
	@EnvironmentObject var router: Router
	@Environment(\.managedObjectContext) var context
	@EnvironmentObject var accessoryManager: AccessoryManager
	@FocusState var messageFieldFocused: Bool
	
	@ObservedObject var myInfo: MyInfoEntity
	@ObservedObject var channel: ChannelEntity
	
	@State private var replyMessageId: Int64 = 0
	@State private var messageToHighlight: Int64 = 0
	@AppStorage("preferredPeripheralNum") private var preferredPeripheralNum = -1
	
	@FetchRequest private var allPrivateMessages: FetchedResults<MessageEntity>
	
	init(myInfo: MyInfoEntity, channel: ChannelEntity) {
		self.myInfo = myInfo
		self.channel = channel
		
		// Fetch request with batching and sorting
		let request: NSFetchRequest<MessageEntity> = MessageEntity.fetchRequest()
		request.sortDescriptors = [
			NSSortDescriptor(keyPath: \MessageEntity.messageTimestamp, ascending: true)
		]
		request.predicate = NSPredicate(
			format: "channel == %ld AND toUser == nil AND isEmoji == false",
			channel.index
		)
		request.fetchBatchSize = 10
		request.returnsObjectsAsFaults = false
		
		_allPrivateMessages = FetchRequest(fetchRequest: request)
	}
	
	// MARK: - Read Messages
	
	private func markAllUnreadAsRead() {
		context.perform {
			let unreadMessages = allPrivateMessages.filter { !$0.read }
			guard !unreadMessages.isEmpty else { return }
			
			unreadMessages.forEach { $0.read = true }
			
			do {
				try context.save()
				DispatchQueue.main.async {
					self.appState.unreadChannelMessages = self.myInfo.unreadMessages
					self.context.refresh(self.myInfo, mergeChanges: true)
					Logger.data.info("📖 [App] Marked all unread messages as read.")
				}
			} catch {
				Logger.data.error("Failed to mark messages read: \(error.localizedDescription, privacy: .public)")
			}
		}
	}
	
	// Helper to get the previous message for display grouping
	private func previousMessage(for message: MessageEntity) -> MessageEntity? {
		guard let index = allPrivateMessages.firstIndex(of: message), index > 0 else { return nil }
		return allPrivateMessages[index - 1]
	}
	
	var body: some View {
		ScrollViewReader { scrollView in
			VStack(spacing: 0) {
				ScrollView {
					LazyVStack {
						ForEach(allPrivateMessages, id: \.messageId) { message in
							ChannelMessageRow(
								message: message,
								allMessages: allPrivateMessages,
								previousMessage: previousMessage(for: message),
								preferredPeripheralNum: preferredPeripheralNum,
								channel: channel,
								replyMessageId: $replyMessageId,
								messageFieldFocused: $messageFieldFocused,
								messageToHighlight: $messageToHighlight,
								scrollView: scrollView,
								onInteractionComplete: {
									// Ensure we stay at the bottom after interactions (e.g., reply, link tap)
									DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
										scrollView.scrollTo("bottomAnchor", anchor: .bottom)
									}
								}
							)
						}
						Color.clear
							.frame(height: 1)
							.id("bottomAnchor")
					}
				}
				.defaultScrollAnchor(.bottom)
				.defaultScrollAnchorTopAlignment()
				.defaultScrollAnchorBottomSizeChanges()
				.scrollDismissesKeyboard(.immediately)
				.onAppear {
					// Mark unread messages once when view appears
					markAllUnreadAsRead()
					scrollView.scrollTo("bottomAnchor", anchor: .bottom)
				}
				.onChange(of: messageFieldFocused, initial: false) { newValue, _ in
					if newValue {
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
							scrollView.scrollTo("bottomAnchor", anchor: .bottom)
						}
					}
				}
				
				TextMessageField(
					destination: .channel(channel),
					replyMessageId: $replyMessageId,
					isFocused: $messageFieldFocused
				)
			}
		}
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .principal) {
				HStack {
					CircleText(text: String(channel.index), color: .accentColor, circleSize: 44).fixedSize()
					Text(String(channel.name ?? "Unknown").camelCaseToWords()).font(.headline)
				}
			}
			ToolbarItem(placement: .navigationBarTrailing) {
				ConnectedDevice(
					deviceConnected: accessoryManager.isConnected,
					name: accessoryManager.activeConnection?.device.shortName ?? "?",
					mqttProxyConnected: accessoryManager.mqttProxyConnected && (channel.uplinkEnabled || channel.downlinkEnabled),
					mqttUplinkEnabled: channel.uplinkEnabled,
					mqttDownlinkEnabled: channel.downlinkEnabled,
					mqttTopic: accessoryManager.mqttManager.topic
				)
			}
		}
	}
}

