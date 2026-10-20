import Foundation
import DozableKit

// 594 — onboarding, the parts `doz onboard` and the UI's wizard share: which checks stop it (D5), the settings file
// written only when missing (D7) and the user's prompt template beside it (D16). 634: the store's ONE base (its disk
// need) and the key choices. The work itself — preparing the base — is the host's (`onboard`).

/// One check as onboarding presents it: the doctor's finding, and whether it stops onboarding.
public struct OnboardingCheck: Codable, Equatable, Sendable {
    public var check: String
    /// ok · warn · fail
    public var status: String
    public var detail: String
    /// A hard check stops onboarding when it is not ok (D5); a soft one only warns.
    public var hard: Bool

    public init(check: String, status: String, detail: String, hard: Bool) {
        self.check = check
        self.status = status
        self.detail = detail
        self.hard = hard
    }

    public var blocks: Bool { hard && status == "fail" }
}

public enum Onboarding {
    /// D5: the checks that stop onboarding when they fail. Everything else only warns (Claude Code
    /// missing or signed out: the claude-code image still works with an account added later; vmnet:
    /// only `--network nat` needs it).
    public static let hardChecks: Set<String> = ["macOS", "chip", "virtualization", "entitlement", "guest tools", "socket", "store", "disk"]

    /// What every first preparation needs besides the images: the kernel archive (downloaded, then
    /// only its kernel kept) and the guest init disk.
    public static let commonBytes: Int64 = 700 << 20
    /// Room left over after the images, so a first sandbox still fits.
    public static let headroomBytes: Int64 = 2 << 30

    // MARK: 634 — one base, and the keys by provider and gateway

    /// 634: the disk the store's one base needs (0 when it is prepared): the common parts (kernel, guest init), its
    /// download, its flattened disk (about two thirds of the 4 GiB capacity is never written; measured ~2 GB with the
    /// download), and room for a first sandbox.
    public static func baseNeed(_ base: CatalogueBase, prepared: Bool) -> Int64 {
        prepared ? 0 : commonBytes + base.downloadBytes * 3 + headroomBytes
    }

    /// 634: the checks with the base's disk line ("the base needs about …").
    public static func checks(doctor: [(check: String, status: String, detail: String)], store: DozableStore,
                              base: CatalogueBase, prepared: Bool) -> [OnboardingCheck] {
        var out: [OnboardingCheck] = doctor.filter { $0.check != "store" }
            .map { OnboardingCheck(check: $0.check, status: $0.status, detail: $0.detail, hard: hardChecks.contains($0.check)) }
        if let v = volume(of: store) {
            out.append(OnboardingCheck(check: "store", status: v.apfs ? "ok" : "fail",
                                       detail: "\(store.root.path) — \(v.format)" + (v.apfs ? "" : " — the store must be on APFS (disks are APFS clones); pick another with --store"),
                                       hard: true))
            let need = baseNeed(base, prepared: prepared)
            out.append(OnboardingCheck(check: "disk", status: v.free >= need ? "ok" : "fail",
                                       detail: "\(DozableImages.formatBytes(v.free)) free"
                                       + (need == 0 ? " (the \(base.title) base is ready)" : " — the \(base.title) base needs about \(DozableImages.formatBytes(need)) (with room for a first sandbox)")
                                       + (v.free >= need ? "" : " — free some space"),
                                       hard: true))
        }
        return out
    }

    /// 634: one way to give tools a model — a provider's or a gateway's key, or none (a key-less source) — and the
    /// published tools that can use it. The owner's "the Open Router key was not accepted": the setup knew only
    /// Claude's kinds; it now offers every published source, OpenRouter included, added as `doz account add` adds it.
    public struct KeyChoice: Codable, Equatable, Sendable {
        /// anthropic · openai · xai · google · openrouter · opencode-zen …
        public var id: String
        public var title: String
        public var gateway: Bool
        /// No key at all (OpenCode Zen's free models).
        public var keyless: Bool
        /// What a key of it is added as: `api-key` (Anthropic), `openai-key` (OpenAI), `key` (with the provider).
        public var accountKind: String
        public var keyHint: String?
        /// The published tools that can use it, by their (family's) name.
        public var tools: [String]
    }

    /// The sources the published tools can use, providers first, then gateways, then the key-less ones.
    public static func keyChoices() -> [KeyChoice] {
        let recipes = AgentRecipes.published
        func sources(_ r: AgentRecipe) -> [String] { r.models != nil ? r.publishedSources : [r.provider].compactMap { $0 } }
        func name(_ r: AgentRecipe) -> String { r.family.flatMap { AgentRecipes.recipe($0.family)?.title } ?? r.title }
        var ids: [String] = []
        for r in recipes { for s in sources(r) where !ids.contains(s) { ids.append(s) } }
        let choices = ids.map { id -> KeyChoice in
            var tools: [String] = []
            for r in recipes where sources(r).contains(id) && !tools.contains(name(r)) { tools.append(name(r)) }
            return KeyChoice(id: id, title: ModelSources.title(id), gateway: ModelSources.isGateway(id), keyless: ModelSources.isKeyless(id),
                             accountKind: ModelSources.accountKind(id), keyHint: KeyProviders.provider(id)?.keyHint, tools: tools)
        }
        return choices.filter { !$0.gateway && !$0.keyless } + choices.filter(\.gateway) + choices.filter(\.keyless)
    }

    /// The volume a store is (or will be) on: its nearest existing directory's format and free space.
    public static func volume(of store: DozableStore) -> (apfs: Bool, free: Int64, format: String)? {
        var url = store.root
        let fm = FileManager.default
        while !fm.fileExists(atPath: url.path), url.path != "/" { url = url.deletingLastPathComponent() }
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey]) else { return nil }
        let format = v.volumeLocalizedFormatDescription ?? "?"
        return (format.contains("APFS"), v.volumeAvailableCapacityForImportantUsage ?? 0, format)
    }


    // MARK: D7 — the settings file, only when missing

    public enum ConfigOutcome: String, Codable, Sendable {
        /// Written now, with the onboarding's answers as its only set values.
        case written
        /// There already was one: left exactly as it is.
        case kept
        /// Neither XDG_CONFIG_HOME nor HOME: there is no place for it.
        case unavailable
    }

    /// Write doz.toml (every setting listed with its default, commented) with `defaults.image` and
    /// `defaults.account` set — only when there is no file. An existing one is never touched.
    public static func writeSettingsIfMissing(defaultImage: String?, account: String?, base: String? = nil,
                                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (ConfigOutcome, String?) {
        guard let url = DozableSettings.fileURL(environment: environment) else { return (.unavailable, nil) }
        var st = stat()
        if lstat(url.path, &st) == 0 { return (.kept, url.path) }
        var values: [String: TOMLValue] = [:]
        if let defaultImage, let d = DozableSettings.definition(SettingKey.defaultImage) { values[d.key] = try d.validate(.string(defaultImage)) }
        if let account, let d = DozableSettings.definition(SettingKey.defaultAccount) { values[d.key] = try d.validate(.string(account)) }
        // 634: the store's base, only when it is not the default (node).
        if let base, base != "node", let d = DozableSettings.definition(SettingKey.defaultBase) { values[d.key] = try d.validate(.string(base)) }
        try DozableSettings.writeAtomically(DozableSettings.render(values: values), to: url)
        return (.written, url.path)
    }

    /// 634: the store's base into a settings file that was KEPT (as the Access choices are) — only when it is not
    /// what the file already says. Returns the lines set (empty: nothing changed).
    public static func writeBase(_ base: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String] {
        let s = DozableSettings.load(environment: environment)
        if (s.string(SettingKey.defaultBase) ?? "node") == base { return [] }
        try s.writing(SettingKey.defaultBase, .string(base))
        return ["\(SettingKey.defaultBase) = \(base)"]
    }

    /// Write the user's prompt template starter (all of it inside a comment: it changes nothing until
    /// edited) — only when there is none.
    public static func writePromptTemplateIfMissing(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (ConfigOutcome, String?) {
        guard let url = AgentPrompt.userTemplateURL(environment: environment) else { return (.unavailable, nil) }
        var st = stat()
        if lstat(url.path, &st) == 0 { return (.kept, url.path) }
        try DozableSettings.writeAtomically(AgentPrompt.userTemplateStarter, to: url)
        return (.written, url.path)
    }
}
