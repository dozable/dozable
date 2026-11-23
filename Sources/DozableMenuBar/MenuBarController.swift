import AppKit
import DozableMenuBarCore

/// Start the menu: an accessory app (no Dock icon, no main window) with one status item. Never returns.
@MainActor
func runMenuBarApp(source: SnapshotSource, flavour: MenuBarFlavour) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController(source: source, flavour: flavour)
    withExtendedLifetime(controller) { app.run() }
    exit(0)
}

/// The status item and its menu — AppKit's `NSStatusItem` + `NSMenu`, drawn from `MenuModel.items(for:)` (pure, in
/// DozableMenuBarCore). This layer only draws the model and runs the chosen action.
///
/// Refresh: with the menu closed, every 60 s, at wake, and after every action; while it is open, at once and then every
/// 2 s (a timer in the common run-loop modes, so it ticks while the menu tracks). ONE doz command at a time, on a serial
/// queue: a tick that comes while one runs is skipped.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let source: SnapshotSource
    private let flavour: MenuBarFlavour
    private let queue = DispatchQueue(label: "com.dozable.app.doz")
    private var inFlight = false
    private var snapshot: Snapshot
    private var busy: Snapshot.Busy?
    private var lastError: String?
    private var closedTimer: Timer?
    private var openTimer: Timer?

    static let closedInterval: TimeInterval = 60
    static let openInterval: TimeInterval = 2

    init(source: SnapshotSource, flavour: MenuBarFlavour) {
        self.source = source
        self.flavour = flavour
        // The dev flavour's item is wider: its icon and the "DEV" badge beside it.
        statusItem = NSStatusBar.system.statusItem(withLength: flavour.badge == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength)
        snapshot = Snapshot(doz: .missing, appVersion: source.appVersion, flavour: flavour)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        draw()
        refresh()
        let t = Timer(timeInterval: Self.closedInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        closedTimer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: refresh

    private func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let source = self.source
        queue.async {
            let s = source.snapshot()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight = false
                    self.snapshot = s
                    self.draw()
                }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        openTimer?.invalidate()
        let t = Timer(timeInterval: Self.openInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        openTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        openTimer?.invalidate()
        openTimer = nil
    }

    // MARK: drawing

    private var current: Snapshot {
        var s = snapshot
        s.busy = busy
        s.lastError = lastError
        return s
    }

    private func draw() {
        let s = current
        let symbol = MenuModel.icon(for: s)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: flavour.name)
        image?.isTemplate = true
        statusItem.button?.image = image
        if let badge = flavour.badge {
            // A title beside the template icon: the status bar draws both in its own label colour, so the badge reads
            // in a light and a dark menu bar alike (and when the item is highlighted).
            statusItem.button?.imagePosition = .imageLeading
            statusItem.button?.attributedTitle = NSAttributedString(string: image == nil ? "D " + badge : badge, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .heavy), .kern: 0.5, .baselineOffset: 0.5])
            statusItem.button?.toolTip = flavour.name + " — " + MenuModel.header(for: s)
        } else {
            statusItem.button?.title = image == nil ? "D" : ""
            statusItem.button?.toolTip = MenuModel.header(for: s)
        }

        let model = MenuModel.items(for: s)
        // In place when the shape is the same (an open menu updates without flicker); rebuilt otherwise.
        let sameShape = menu.items.count == model.count
            && zip(menu.items, model).allSatisfy { $0.isSeparatorItem == ($1.kind == .separator) }
        if !sameShape {
            menu.removeAllItems()
            for m in model { menu.addItem(m.kind == .separator ? .separator() : NSMenuItem()) }
        }
        for (item, m) in zip(menu.items, model) where m.kind != .separator {
            item.title = m.title
            item.isEnabled = m.enabled
            item.state = m.checked ? .on : .off
            item.representedObject = m.action?.rawValue
            item.target = m.action == nil ? nil : self
            item.action = m.action == nil ? nil : #selector(choose(_:))
        }
    }

    // MARK: actions

    @objc private func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MenuAction(rawValue: raw) else { return }
        switch action {
        case .quit:
            // This app only — the daemon keeps running.
            NSApp.terminate(nil)
        case .installHelp:
            if let url = URL(string: MenuBarApp.installHelpURL(appVersion: source.appVersion)) { NSWorkspace.shared.open(url) }
        case .restartApp:
            // The copy on disk is newer: open it as a new instance, then quit this one (the daemon keeps running).
            let c = NSWorkspace.OpenConfiguration()
            c.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { _, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let error {
                            self.lastError = "Could not restart the menu bar app: \(error.localizedDescription)"
                            self.draw()
                        } else {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        case .loginSettings:
            // macOS waits for the person: System Settings › Login Items, where they switch Dozable on.
            _ = source.performLogin(.loginSettings)
            refresh()
        default:
            if let c = MenuModel.items(for: current).first(where: { $0.action == action })?.confirm, !ask(c) { return }
            run(action)
        }
    }

    private func ask(_ c: Confirmation) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = c.title
        alert.informativeText = c.message
        alert.addButton(withTitle: c.button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func run(_ action: MenuAction) {
        guard !inFlight else { return }
        inFlight = true
        busy = action.busy
        lastError = nil
        draw()
        let source = self.source
        queue.async {
            let error = source.perform(action)
            if action == .updateApp { source.invalidate() }
            let s = source.snapshot()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight = false
                    self.busy = nil
                    self.lastError = error
                    self.snapshot = s
                    self.draw()
                }
            }
        }
    }
}
