import ArgumentParser
import Foundation
import DozableKit
import DozableHost

// 591 settings — `doz config`: the settings file (`${XDG_CONFIG_HOME:-~/.config}/doz/doz.toml`),
// its effective values and where each came from. One closed schema (`DozableSettings.schema`); the
// file is regenerated from it on every write, atomically, 0600.

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config",
        abstract: "Settings: the doz.toml file, every value and where it came from (flag, env, file or default).",
        discussion: """
        Precedence: a command-line flag, then its environment variable (DOZ_STORE, DOZ_HOST_IDLE, \
        DOZ_SUBNET, DOZ_KERNEL, DOZ_KERNEL_CACHE), then the file, then the default. The file lists \
        every setting with its default commented out; set writes one value, unset puts the default back. \
        The UI's Settings page edits the same file. \
        --sandbox NAME (show, get, set, unset): that sandbox's own value of a per-sandbox setting \
        (\(DozableSettings.perSandbox.joined(separator: ", "))), which wins over the file's.
        """,
        subcommands: [ConfigShow.self, ConfigGet.self, ConfigSet.self, ConfigUnset.self, ConfigInit.self, ConfigPath.self],
        defaultSubcommand: ConfigShow.self)
}

/// `--store` is the one setting a flag of every command sets.
func configFlags(_ g: GlobalOptions) -> [String: TOMLValue] {
    g.store.map { [SettingKey.storePath: .string($0)] } ?? [:]
}

func settingsWarnings(_ s: DozableSettings, _ g: GlobalOptions) {
    guard !g.json, !g.quiet else { return }
    for w in s.warnings { Out.stderr("doz: \(s.url?.lastPathComponent ?? DozableSettings.fileName): \(w)\n") }
}

func settingDefinition(_ key: String, _ g: GlobalOptions) throws -> SettingDefinition {
    guard let d = DozableSettings.definition(key) else {
        throw fail(HostError(.invalid, "unknown setting \(key) — doz config show lists them (section.name, e.g. ui.boot_view_on_start)"), g)
    }
    // 669: a 0.37 name still works, and says the new one.
    if d.key != key, !g.json, !g.quiet { Out.stderr("note: \(key) is now \(d.key)\n") }
    return d
}

/// 669: the recipe `--agent` names (its id, an `AgentRef` like `opencode@2`, or `anthropic/claude-code`).
func settingsRecipe(_ name: String, _ g: GlobalOptions) throws -> AgentRecipe {
    guard let r = DozableSettings.recipe(named: name) else {
        throw fail(HostError(.invalid, "--agent: no recipe \(name) — its id (claude-code), a major (opencode@2) or its full name (anthropic/claude-code); doz recipe ls lists them"), g)
    }
    return r
}

/// 669: the setting a command names — `section.name` (or its 0.37 name), or with `--agent ID` one of that recipe's
/// options (`version`, `approvals`, `memory_mib`, `network`, its own).
func namedSetting(_ key: String, agent: String?, _ g: GlobalOptions) throws -> SettingDefinition {
    guard let agent else { return try settingDefinition(key, g) }
    let r = try settingsRecipe(agent, g)
    guard let k = DozableSettings.recipeKey(r, key), let d = DozableSettings.definition(k) else {
        let names = DozableSettings.recipeDefinitions(r.id).map(\.name).joined(separator: ", ")
        throw fail(HostError(.invalid, "\(key) is not a setting of \(r.qualifiedID) — it has \(names)"), g)
    }
    return d
}

/// 669: what the first write after the upgrade did (`doz.toml.0.37.bak`), said once.
func sayMigration(_ s: DozableSettings, _ g: GlobalOptions) {
    guard let n = s.migrationNotice, !g.json, !g.quiet else { return }
    Out.stderr("doz: \(n)\n")
}

/// 669: the SOURCE column's word — `env NAME`, else the source (`mac`, `recipe`, `default`, …).
func sourceWord(_ r: SettingRow) -> String { r.source == .env ? "env \(r.environment ?? "")" : r.source.rawValue }

// MARK: 599 — a sandbox's own values (`--sandbox NAME`)

/// The per-sandbox settings of `sandbox`, after `change` (a key and its value, or nil to clear it).
func sandboxSettingsCall(_ sandbox: String, change: (key: String, value: String?)?, _ g: GlobalOptions) async throws -> SandboxSettingsReport {
    var r = HostRequest(.sandboxSettings, name: sandbox)
    if let change {
        guard DozableSettings.perSandbox.contains(change.key) else {
            throw fail(HostError(.invalid, "\(change.key) is not a per-sandbox setting — they are: \(DozableSettings.perSandbox.joined(separator: ", "))"), g)
        }
        r.setting = change.key
        if let v = change.value { r.settingValue = .string(v) } else { r.clearSetting = true }
        return try decode(try call(r, g), SandboxSettingsReport.self, g)
    }
    return try decode(try await query(r, g), SandboxSettingsReport.self, g)
}

func printSandboxSettings(_ rep: SandboxSettingsReport) {
    var t = [["SETTING", "VALUE", "SOURCE"]]
    for r in rep.settings { t.append([r.key, ConfigShow.shown(r.value), r.source == "sandbox" ? "\(rep.sandbox)'s own" : "the setting (\(r.source))"]) }
    Out.stdout(Out.table(t))
}

struct ConfigShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Every setting: its effective value and its source (the default).")
    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "A sandbox: its per-sandbox settings and whose value each is.") var sandbox: String?
    @Option(name: .long, help: "One agent or tool (a recipe's id, e.g. grok): only its own settings — the ones doz.toml lists only once one is set.") var agent: String?

    func run() async throws {
        if let sandbox {
            let rep = try await sandboxSettingsCall(sandbox, change: nil, g)
            if g.json { Out.json(rep) } else { printSandboxSettings(rep) }
            return
        }
        let s = DozableSettings.load()
        var report = s.report(flags: configFlags(g))
        var recipe: AgentRecipe?
        if let agent {
            let r = try settingsRecipe(agent, g)
            recipe = r
            let keys = Set(DozableSettings.recipeDefinitions(r.id).map(\.key))
            report.settings = report.settings.filter { keys.contains($0.key) }
        }
        if g.json { Out.json(report); return }
        settingsWarnings(s, g)
        if let r = recipe {
            // 669: one recipe — each option by its name, its value, its source and the recipe's own default.
            Out.stdout("\(r.title) — \(r.qualifiedID) (\(r.subjectWords)) · doz.toml [\(r.settingsSection)]\n\n")
            var t = [["SETTING", "VALUE", "SOURCE", "RECIPE DEFAULT"]]
            for row in report.settings { t.append([row.name, Self.shown(row.value), sourceWord(row), Self.shown(row.defaultValue)]) }
            Out.stdout(Out.table(t))
        } else {
            var t = [["SETTING", "VALUE", "SOURCE", "DEFAULT"]]
            for r in report.settings {
                t.append([r.key, Self.shown(r.value), sourceWord(r), r.value == r.defaultValue ? "" : Self.shown(r.defaultValue)])
            }
            Out.stdout(Out.table(t))
        }
        for n in report.notes ?? [] where report.settings.contains(where: { n.contains(" is now \($0.key) ") }) { Out.stdout("note: \(n)\n") }
        Out.stdout("\nfile: \(report.path ?? "none (neither XDG_CONFIG_HOME nor HOME is set)")\(report.exists ? "" : " (not created yet — doz config init)")\n")
    }

    static func shown(_ v: TOMLValue) -> String {
        if case .string(let s) = v { return s.isEmpty ? "\"\"" : s }
        return v.plain
    }
}

struct ConfigGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "One setting's effective value (--json adds its source and default).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "section.name, e.g. ui.boot_view_on_start (with --agent: the recipe's option, e.g. version)") var key: String
    @Option(name: .long, help: "A sandbox: its value of a per-sandbox setting (its own, else the setting's).") var sandbox: String?
    @Option(name: .long, help: "A recipe (claude-code, opencode@2, anthropic/claude-code): KEY is one of its options.") var agent: String?

    func run() async throws {
        let key = try namedSetting(self.key, agent: agent, g).key
        if let sandbox {
            guard let row = try await sandboxSettingsCall(sandbox, change: nil, g).settings.first(where: { $0.key == key }) else {
                throw fail(HostError(.invalid, "\(key) is not a per-sandbox setting — they are: \(DozableSettings.perSandbox.joined(separator: ", "))"), g)
            }
            if g.json { Out.json(row) } else { Out.stdout(row.value.plain + "\n") }
            return
        }
        let s = DozableSettings.load()
        let row = s.report(flags: configFlags(g)).settings.first { $0.key == key }!
        if g.json { Out.json(row); return }
        settingsWarnings(s, g)
        Out.stdout(row.value.plain + "\n")
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Set one setting in the file (checked against its type and range).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "section.name, e.g. ui.boot_view_on_start (with --agent: the recipe's option, e.g. version)") var key: String
    @Argument(help: "The value: true/false, a number, or one of the setting's choices.") var value: String
    @Option(name: .long, help: "Set it for this sandbox only (a per-sandbox setting; it wins over the file's).") var sandbox: String?
    @Option(name: .long, help: "A recipe (claude-code, opencode@2, anthropic/claude-code): KEY is one of its options.") var agent: String?

    func run() async throws {
        let d = try namedSetting(self.key, agent: agent, g)
        let key = d.key
        let v: TOMLValue
        do { v = try d.parse(value) } catch let e as SettingsError { throw fail(HostError(.invalid, e.message), g) }
        if let sandbox {
            let rep = try await sandboxSettingsCall(sandbox, change: (key, value), g)
            if g.json { Out.json(rep); return }
            Out.stdout("\(key) = \(v.plain) for \(rep.sandbox) — \(d.applies.note)\n")
            return
        }
        let now: DozableSettings
        do { now = try DozableSettings.load().writing(key, v) } catch let e as SettingsError { throw fail(HostError(.failed, e.message), g) }
        let r = now.resolve(key, flag: configFlags(g)[key])
        sayMigration(now, g)
        if g.json { Out.json(now.report(flags: configFlags(g)).settings.first { $0.key == key }!); return }
        Out.stdout("\(key) = \(TOML.render(v)) in \(now.url?.path ?? "?") (this Mac) — \(d.applies.note)\n")
        if r.source == .env || r.source == .flag, !g.quiet {
            Out.stderr("note: \(r.source == .env ? "$\(d.environment ?? "")" : d.flag ?? "a flag") overrides it here: the effective value is \(r.value.plain)\n")
        }
    }
}

struct ConfigUnset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unset", abstract: "Put one setting back to its default (comment it out in the file).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "section.name (with --agent: the recipe's option, e.g. version)") var key: String
    @Option(name: .long, help: "Clear this sandbox's own value: it follows the setting again.") var sandbox: String?
    @Option(name: .long, help: "A recipe (claude-code, opencode@2, anthropic/claude-code): KEY is one of its options.") var agent: String?

    func run() async throws {
        let d = try namedSetting(self.key, agent: agent, g)
        let key = d.key
        if let sandbox {
            let rep = try await sandboxSettingsCall(sandbox, change: (key, nil), g)
            if g.json { Out.json(rep); return }
            let now = rep.settings.first { $0.key == key }
            Out.stdout("\(key) for \(rep.sandbox) follows the setting again (\(now?.value.plain ?? "?")) — \(d.applies.note)\n")
            return
        }
        let now: DozableSettings
        do { now = try DozableSettings.load().writing(key, nil) } catch let e as SettingsError { throw fail(HostError(.failed, e.message), g) }
        sayMigration(now, g)
        if g.json { Out.json(now.report(flags: configFlags(g)).settings.first { $0.key == key }!); return }
        Out.stdout("\(key) is \(d.agent != nil ? "the recipe's default" : "the default") (\(d.defaultValue.plain)) in \(now.url?.path ?? "?") (this Mac)\n")
    }
}

struct ConfigInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init",
        abstract: "Write the settings file: every setting with its default commented out — an agent's own once one of them is set (an existing file keeps its values and gains any new settings).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        let s = DozableSettings.load()
        let now: DozableSettings
        do { now = try s.writingAll(s.fileValues) } catch let e as SettingsError { throw fail(HostError(.failed, e.message), g) }
        sayMigration(now, g)
        if g.json { Out.json(now.report(flags: configFlags(g))); return }
        settingsWarnings(now, g)
        // 669: what the file lists — Dozable's own, and the recipes that have a value set.
        let listed = DozableSettings.listedCount(values: now.fileValues)
        Out.stdout("\(s.fileExists ? "rewrote" : "wrote") \(now.url?.path ?? "?") — \(listed) settings, \(now.fileValues.count) set\n")
    }
}

struct ConfigPath: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Where the settings file is (${XDG_CONFIG_HOME:-~/.config}/doz/doz.toml).")
    @OptionGroup var g: GlobalOptions

    func run() async throws {
        guard let url = DozableSettings.fileURL() else {
            throw fail(HostError(.unavailable, "no settings file: neither XDG_CONFIG_HOME nor HOME is set"), g)
        }
        if g.json { Out.json(["path": url.path, "exists": FileManager.default.fileExists(atPath: url.path) ? "true" : "false"]) }
        else { Out.stdout(url.path + "\n") }
    }
}
