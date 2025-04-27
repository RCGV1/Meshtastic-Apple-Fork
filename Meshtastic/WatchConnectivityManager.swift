import WatchConnectivity
import CoreData

class WatchCommunicationManager: NSObject, WCSessionDelegate {
	private let session: WCSession
	private let context: NSManagedObjectContext

	init(context: NSManagedObjectContext) {
		self.session = WCSession.default
		self.context = context
		super.init()
		session.delegate = self
		session.activate()
		
		// Observe Core Data saves
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(contextDidSave),
			name: NSNotification.Name.NSManagedObjectContextDidSave,
			object: context
		)
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

	// MARK: - WCSessionDelegate Methods
	func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
		if let error = error {
			print("iOS: Session activation failed: \(error.localizedDescription)")
		} else {
			print("iOS: Session activated with state: \(activationState.rawValue)")
		}
	}

	func sessionDidBecomeInactive(_ session: WCSession) {}
	func sessionDidDeactivate(_ session: WCSession) {}

	func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
		print("iOS: Received context from watchOS: \(applicationContext)")
		processContext(applicationContext)
	}

	// MARK: - Context Sending
	@objc func contextDidSave(_ notification: NSNotification) {
		let contextData = buildContext()
		sendContext(contextData)
	}

	private func buildContext() -> [String: Any] {
		// Customize this to include your Core Data state
		var contextData: [String: Any] = [:]
		
		// Placeholder: Add your data here (must be property-list-compliant)
		contextData["appState"] = "updated"
		// Example: Serialize Core Data entities
		// let channelRequest: NSFetchRequest<ChannelEntity> = ChannelEntity.fetchRequest()
		// if let channels = try? context.fetch(channelRequest) {
		//     contextData["channels"] = channels.map { ["index": Int($0.index), "name": $0.name ?? ""] }
		// }
		
		return contextData
	}

	private func sendContext(_ context: [String: Any]) {
		guard session.activationState == .activated else {
			print("iOS: Session not activated, cannot send context")
			return
		}

		do {
			try session.updateApplicationContext(context)
			print("iOS: Sent context: \(context)")
		} catch {
			print("iOS: Failed to send context: \(error.localizedDescription)")
		}
	}

	// MARK: - Context Receiving
	private func processContext(_ context: [String: Any]) {
		// Handle incoming context from watchOS
		if let requestUpdate = context["requestUpdate"] as? Bool, requestUpdate {
			let contextData = buildContext()
			sendContext(contextData)
		}
	}

	// MARK: - Public Method to Manually Trigger Context Update
	func triggerContextUpdate() {
		let contextData = buildContext()
		sendContext(contextData)
	}
}
