import AppKit

/// Subscribe before acquiring the lock, so ownership is never visible without a forwarding inbox.
/// Events received during startup wait until the primary has initialized its app services.
@MainActor
final class InstanceLaunchInbox {
    private enum Event { case reopen, url(URL) }
    private var observers: [NSObjectProtocol] = []
    private var pending: [Event] = []
    private var ready = false
    private var stopped = false
    private let onReopen: @MainActor () -> Void
    private let onURL: @MainActor (URL) -> Void

    init(namespace: String = AppIdentity.bundleIdentifier,
         onReopen: @escaping @MainActor () -> Void = { SettingsWindowController.shared.show() },
         onURL: @escaping @MainActor (URL) -> Void = { MaskActions.handle($0) }) {
        self.onReopen = onReopen
        self.onURL = onURL
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name(namespace + ".reopen"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enqueueReopen() }
        })
        observers.append(center.addObserver(forName: Notification.Name(namespace + ".forwardURL"), object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.object as? String, let url = URL(string: raw) else { return }
            Task { @MainActor in self?.enqueue(url) }
        })
    }

    func enqueueReopen() { receive(.reopen) }
    func enqueue(_ url: URL) {
        guard MaskCommand.parse(url) != nil else { return }
        receive(.url(url))
    }

    func start() {
        guard !stopped else { return }
        ready = true
        let events = pending
        pending.removeAll()
        for event in events { receive(event) }
    }

    func stop() {
        stopped = true
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
        pending.removeAll()
    }

    private func receive(_ event: Event) {
        guard !stopped else { return }
        guard ready else { pending.append(event); return }
        switch event {
        case .reopen: onReopen()
        case .url(let url): onURL(url)
        }
    }
}
