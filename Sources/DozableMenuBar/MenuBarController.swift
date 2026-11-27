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
    private var busyWorkspace: String?
    private var menuOpen = false
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

    /// `workspaces`: also `doz workspace ls` — while the menu is open (and after an action); a closed-menu refresh keeps
    /// the last list (nothing shows it then).
    private func refresh(workspaces: Bool? = nil) {
        guard !inFlight else { return }
        inFlight = true
        let source = self.source
        let want = workspaces ?? menuOpen
        queue.async {
            let s = source.snapshot(workspaces: want)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight = false
                    self.adopt(s, workspaces: want)
                    self.draw()
                }
            }
        }
    }

    private func adopt(_ new: Snapshot, workspaces: Bool) {
        var s = new
        if !workspaces, MenuBarApp.supportsWorkspaces(s.dozVersion) { s.workspaces = snapshot.workspaces }
        snapshot = s
    }

    func menuWillOpen(_ menu: NSMenu) {
        // A workspace's submenu opening is not the menu opening.
        guard menu === self.menu else { return }
        menuOpen = true
        refresh(workspaces: true)
        openTimer?.invalidate()
        let t = Timer(timeInterval: Self.openInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        openTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
        openTimer?.invalidate()
        openTimer = nil
    }

    // MARK: drawing

    private var current: Snapshot {
        var s = snapshot
        s.busy = busy
        s.busyWorkspace = busyWorkspace
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

        fill(menu, MenuModel.items(for: s))
    }

    /// Same shape: the same separators, and a submenu where the model has one, of the same shape.
    private static func sameShape(_ items: [NSMenuItem], _ model: [MenuItem]) -> Bool {
        items.count == model.count && zip(items, model).allSatisfy { item, m in
            guard item.isSeparatorItem == (m.kind == .separator) else { return false }
            switch (item.submenu, m.submenu) {
            case (nil, nil): return true
            case let (sub?, under?): return sameShape(sub.items, under)
            default: return false
            }
        }
    }

    /// Draw `model` into `menu` — in place when the shape is the same (an open menu updates without flicker); rebuilt otherwise.
    private func fill(_ menu: NSMenu, _ model: [MenuItem]) {
        if !Self.sameShape(menu.items, model) {
            menu.removeAllItems()
            for m in model {
                let item = m.kind == .separator ? NSMenuItem.separator() : NSMenuItem()
                if m.submenu != nil {
                    let sub = NSMenu()
                    sub.autoenablesItems = false
                    item.submenu = sub
                }
                menu.addItem(item)
            }
        }
        for (item, m) in zip(menu.items, model) where m.kind != .separator {
            item.title = m.title
            item.isEnabled = m.enabled
            item.state = m.checked ? .on : .off
            item.representedObject = m.action.map { [$0.rawValue, m.workspace ?? ""] as [String] }
            item.target = m.action == nil ? nil : self
            item.action = m.action == nil ? nil : #selector(choose(_:))
            if let sub = item.submenu, let under = m.submenu { fill(sub, under) }
        }
    }

    // MARK: actions

    @objc private func choose(_ sender: NSMenuItem) {
        guard let chosen = sender.representedObject as? [String], chosen.count == 2, let action = MenuAction(rawValue: chosen[0]) else { return }
        let workspace = chosen[1].isEmpty ? nil : chosen[1]
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
            run(action, workspace: workspace)
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

    private func run(_ action: MenuAction, workspace: String? = nil) {
        guard !inFlight else { return }
        inFlight = true
        busy = action.busy
        busyWorkspace = workspace
        lastError = nil
        draw()
        let source = self.source
        queue.async {
            let error = source.perform(action, workspace: workspace)
            if action == .updateApp { source.invalidate() }
            let s = source.snapshot(workspaces: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight = false
                    self.busy = nil
                    self.busyWorkspace = nil
                    self.lastError = error
                    self.adopt(s, workspaces: true)
                    self.draw()
                }
            }
        }
    }
}
