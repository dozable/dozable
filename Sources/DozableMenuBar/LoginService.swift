import Foundation
import ServiceManagement
import DozableMenuBarCore

/// Start at Login through SMAppService — the ONE place this app (and this package) imports ServiceManagement (the audit
/// holds it). It is used only outside a test run (`MenuBarSeams.testRun`): every test gets `RecordingLoginItemService`,
/// which records what it would do and calls nothing. It registers only on the person's click (`MenuAction.loginOn`), and
/// unregisters on their click, or when doz removes the app (`--unregister`).
///
///   · the agent `com.dozable.app.daemon` (`Contents/Library/LaunchAgents/com.dozable.app.daemon.plist`, sealed by the
///     signature): launchd runs this app's executable with `--launch-daemon` at login and every 15 minutes;
///   · the app itself (`SMAppService.mainApp`): the menu comes back at login.
struct SystemLoginItemService: LoginItemService {
    private var agent: SMAppService { SMAppService.agent(plistName: AgentPlist.fileName) }

    static func map(_ s: SMAppService.Status) -> LoginServiceStatus {
        switch s {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func state() -> LoginServiceState {
        LoginServiceState(agent: Self.map(agent.status), mainApp: Self.map(SMAppService.mainApp.status))
    }

    func register() -> (lines: [String], error: String?) {
        // Never from the dev build — `loginService` never hands it this service, and it refuses even if reached.
        if MenuBarFlavour.current.isDev { return RefusingLoginItemService().register() }
        var lines: [String] = []
        for (name, service) in [("agent \(AgentPlist.label)", agent), ("mainApp", SMAppService.mainApp)] {
            // Registering what is registered already is an error to SMAppService; it is left as it is.
            if Self.map(service.status).registered { lines.append("\(name) was registered"); continue }
            do {
                try service.register()
                lines.append("registered \(name)")
            } catch {
                lines.append("could not register \(name): \(error.localizedDescription)")
                return (lines, error.localizedDescription)
            }
        }
        return (lines, nil)
    }

    func unregister() -> (lines: [String], error: String?) {
        if MenuBarFlavour.current.isDev { return RefusingLoginItemService().unregister() }
        var lines: [String] = []
        var failure: String?
        for (name, service) in [("agent \(AgentPlist.label)", agent), ("mainApp", SMAppService.mainApp)] {
            guard Self.map(service.status).registered else { lines.append("\(name) was not registered"); continue }
            do {
                try service.unregister()
                lines.append("unregistered \(name)")
            } catch {
                lines.append("could not unregister \(name): \(error.localizedDescription)")
                failure = failure ?? error.localizedDescription
            }
        }
        return (lines, failure)
    }

    func openSystemSettings() -> [String] {
        SMAppService.openSystemSettingsLoginItems()
        return ["opened System Settings › Login Items"]
    }
}

/// The login service for this run: the dev flavour's refusing one (in every run), else SMAppService's, or — in ANY
/// test run — the recording one.
func loginService(env: [String: String], flavour: MenuBarFlavour) -> LoginItemService {
    if flavour.isDev { return RefusingLoginItemService() }
    return MenuBarSeams.testRun(env) ? RecordingLoginItemService(env: env) : SystemLoginItemService()
}
