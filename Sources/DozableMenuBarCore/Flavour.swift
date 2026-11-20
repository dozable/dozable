import Foundation

/// Which menu bar app this copy is — chosen when the bundle is ASSEMBLED, never at run time from anything a person types:
/// `Scripts/assemble-app.sh` (release, `com.dozable.app`) or `Scripts/assemble-app.sh --dev` (`make app-dev`: "Dozable
/// Dev.app", `com.dozable.app.dev`), read from the bundle's Info.plist.
///
/// The dev flavour runs BESIDE the installed release app and talks only to the workspace's dev doz install (doz-dev): its
/// ONE doz is the absolute path in `DozableDevDoz` (never a standard place, never a PATH search — a missing dev doz is
/// "doz is not installed"), run with `XDG_CONFIG_HOME = DozableDevConfigHome` and `DOZ_STORE = DozableDevStore` so its
/// settings, store and daemon are the dev install's (the dev install keeps its store by `DOZ_STORE`, not in its settings:
/// without it the dev doz would use the default store — the release app's daemon). Missing either → no doz at all. It registers NOTHING with the system: no Start at Login (SMAppService, the agent), no `doz app install`
/// (docs/engineering/menu-bar-app.md, "The dev flavour").
public enum MenuBarFlavour: Equatable, Sendable {
    case release
    /// `doz`: the dev doz's absolute path; `configHome`: the dev install's XDG_CONFIG_HOME; `store`: its DOZ_STORE. Each
    /// nil when its key is missing or not absolute — and then there is no doz at all, never a fallback.
    case dev(doz: String?, configHome: String?, store: String? = nil)

    public static let flavourKey = "DozableFlavour"
    public static let devDozKey = "DozableDevDoz"
    public static let devConfigHomeKey = "DozableDevConfigHome"
    public static let devStoreKey = "DozableDevStore"
    public static let devCommitKey = "DozableDevCommit"
    public static let devBundleIdentifier = "com.dozable.app.dev"
    public static let devName = "Dozable Dev"
    /// What a disabled item says in the dev flavour.
    public static let notInDev = "not in the dev build"
    /// The seam a guarded test run gives the dev flavour's child environment (never the real dev settings in a test).
    public static let configHomeSeam = "DOZ_MENUBAR_CONFIG_HOME"
    /// The seam a guarded test run gives the dev flavour's DOZ_STORE (never the real dev store in a test).
    public static let storeSeam = "DOZ_MENUBAR_STORE"

    /// The flavour an Info.plist dictionary names (`Bundle.main.infoDictionary`). Anything but `DozableFlavour = dev` is
    /// the release app.
    public static func from(info: [String: Any]?) -> MenuBarFlavour {
        guard let info, info[flavourKey] as? String == "dev" else { return .release }
        func absolute(_ key: String) -> String? { (info[key] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } }
        return .dev(doz: absolute(devDozKey), configHome: absolute(devConfigHomeKey), store: absolute(devStoreKey))
    }

    public static var current: MenuBarFlavour { from(info: Bundle.main.infoDictionary) }

    public var isDev: Bool { if case .dev = self { return true }; return false }
    public var name: String { isDev ? Self.devName : "Dozable" }
    public var rawName: String { isDev ? "dev" : "release" }
    /// The text drawn beside the status item's icon (nil: the icon alone).
    public var badge: String? { isDev ? "DEV" : nil }

    /// The doz candidates for this flavour. A guarded test run uses only the seam, whatever the flavour (a test never
    /// runs a real doz); the dev flavour's only candidate is `DozableDevDoz`, and none unless its settings and store are
    /// named too (a dev doz on the default store would be the release app's daemon); the release flavour the standard
    /// places.
    public func dozCandidates(env: [String: String], home: String = NSHomeDirectory()) -> [String] {
        if MenuBarSeams.guarded(env) { return DozLocator.standardCandidates(env: env, home: home) }
        switch self {
        case .release: return DozLocator.standardCandidates(env: env, home: home)
        case .dev(let doz, let configHome, let store):
            guard let doz, configHome != nil, store != nil else { return [] }
            return [doz]
        }
    }

    /// The variables added to every doz child's environment (the rest is inherited). Release: none. Dev: the dev
    /// install's `XDG_CONFIG_HOME` and `DOZ_STORE` — in a guarded test run only the seams', never the real ones — and
    /// `DO_NOT_TRACK=1`, as the dev install's own command sets.
    public func childEnvironment(env: [String: String]) -> [String: String] {
        guard case .dev(_, let configHome, let store) = self else { return [:] }
        func seam(_ name: String) -> String? { env[name].flatMap { $0.hasPrefix("/") ? $0 : nil } }
        let guarded = MenuBarSeams.guarded(env)
        var out = ["DO_NOT_TRACK": "1"]
        if let v = guarded ? seam(Self.configHomeSeam) : configHome { out["XDG_CONFIG_HOME"] = v }
        if let v = guarded ? seam(Self.storeSeam) : store { out["DOZ_STORE"] = v }
        return out
    }
}

extension DozLocator {
    /// The locator the app uses for its menu: `flavour`'s candidates, each an executable regular file (a link is
    /// followed to its file).
    public static func standard(flavour: MenuBarFlavour, env: [String: String] = ProcessInfo.processInfo.environment,
                                home: String = NSHomeDirectory()) -> DozLocator {
        DozLocator(candidates: flavour.dozCandidates(env: env, home: home))
    }
}

/// The login service of the dev flavour: it registers nothing, ever — every call refuses (and says so), and the state
/// is "not registered". Used for the dev flavour in every run, a test run included, so the refusal is what a test sees.
public struct RefusingLoginItemService: LoginItemService {
    public init() {}
    public static let refusal = "Start at Login is \(MenuBarFlavour.notInDev)"
    public func state() -> LoginServiceState { .none }
    public func register() -> (lines: [String], error: String?) { (["refused: \(Self.refusal)"], Self.refusal) }
    public func unregister() -> (lines: [String], error: String?) { (["nothing to unregister: \(Self.refusal)"], nil) }
    public func openSystemSettings() -> [String] { ["refused: \(Self.refusal)"] }
}
