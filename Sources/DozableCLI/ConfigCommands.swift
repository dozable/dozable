import ArgumentParser
import Foundation
import DozableKit
import DozableHost

// 591 settings — `doz config`: the settings file (`${XDG_CONFIG_HOME:-~/.config}/doz/doz.toml`),
// its effective values and where each came from. One closed schema (`DozableSettings.schema`); the
// file is regenerated from it on every write, atomically, 0600.
// 669 (659 §7): one precedence and a layer per place — a command names the place it reads or writes: this Mac
// (doz.toml, the default), `--sandbox NAME` (that sandbox's own value) or `--project DIR` (its doz_project.yaml);
// `--agent ID` names one recipe's options.

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config",
        abstract: "Settings: doz.toml, every value and where it came from (flag, env, sandbox, project, mac, recipe or default).",
        discussion: """
        Precedence: a command-line flag, then its environment variable (DOZ_STORE, DOZ_HOST_IDLE, \
        DOZ_SUBNET, DOZ_KERNEL, DOZ_KERNEL_CACHE), then a sandbox's own value, then its project's \
        (doz_project.yaml), then this Mac's (the file), then the default — a recipe's own for its agent's \
        settings, Dozable's for the rest. The file lists Dozable's own settings with their defaults commented \
        out, and a recipe's block once one of its values is set; set writes one value, unset puts the default \
        back. The UI's Settings page edits the same file. \
        --agent ID (show, get, set, unset): one recipe's options (version, approvals, memory_mib, network, its own). \
        --sandbox NAME (show, get, set, unset): that sandbox's own value of a per-sandbox setting \
        (\(DozableSettings.sandboxKeys.joined(separator: ", "))), which wins over its project's and this Mac's. \
        --project DIR (set, unset): the project's doz_project.yaml, applied when its sandbox is made and at every doz up.
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

/// 669: the per-sandbox key a `--sandbox`/`--project` command names — Dozable's own (`sandbox.clipboard`, or the
/// project's word `clipboard`), or `approvals` (its recipe's: also by the recipe's full key, or `--agent ID approvals`).
func sandboxKey(_ key: String, agent: String?, _ g: GlobalOptions) throws -> String {
    if key == SettingKey.sandboxApprovals { return key }
    if let k = DozableProject.settingKeys.first(where: { $0.key == key })?.setting { return k }
    let d = try namedSetting(key, agent: agent, g)
    if d.agent != nil, d.name == RecipeSettings.approvals { return SettingKey.sandboxApprovals }
    guard DozableSettings.sandboxKeys.contains(d.key) else {
        throw fail(HostError(.invalid, "\(d.key) is not a per-sandbox setting — they are: \(DozableSettings.sandboxKeys.joined(separator: ", "))"
                             + (d.agent != nil ? " (a recipe's \(d.name) is set when a sandbox is made: doz reset moves it)" : "")), g)
    }
    return d.key
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
        guard DozableSettings.sandboxKeys.contains(change.key) else {
            throw fail(HostError(.invalid, "\(change.key) is not a per-sandbox setting — they are: \(DozableSettings.sandboxKeys.joined(separator: ", "))"), g)
        }
        r.setting = change.key
        if let v = change.value { r.settingValue = .string(v) } else { r.clearSetting = true }
        return try decode(try call(r, g), SandboxSettingsReport.self, g)
    }
    return try decode(try await query(r, g), SandboxSettingsReport.self, g)
}

/// 669 (659 §8): what the sandbox overrides first (its own and its project's), then what it follows; the recipe's
/// when-made values as recorded, with this Mac's value now beside each.
func printSandboxSettings(_ rep: SandboxSettingsReport) {
    var t = [["SETTING", "VALUE", "SOURCE", "MAC'S VALUE"]]
    let own = rep.settings.filter { $0.source == "sandbox" || $0.source == "project" }
    let follows = rep.settings.filter { !own.contains($0) && $0.recorded != true }
    let recorded = rep.settings.filter { $0.recorded == true }
    for r in own { t.append([r.key, ConfigShow.shown(r.value), r.source == "project" ? "project" : "sandbox", ConfigShow.shown(r.settingValue)]) }
    for r in follows { t.append([r.key, ConfigShow.shown(r.value), r.source, ""]) }
    for r in recorded {
        t.append([r.key, ConfigShow.shown(r.value), "recorded" + (r.source == "recorded" ? "" : " (\(r.source))"),
                  r.settingValue == r.value ? "" : ConfigShow.shown(r.settingValue) + " — this sandbox keeps its own"])
    }
    Out.stdout(Out.table(t))
}

struct ConfigShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show",
        abstract: "Dozable's own settings, each value and where it came from, and the recipes in use (--all: every recipe's too).")
    @OptionGroup var g: GlobalOptions
    @Option(name: .long, help: "A sandbox: its own and its project's values, what it follows, and its recipe's values as recorded when it was made.") var sandbox: String?
    @Option(name: .long, help: "One recipe (claude-code, opencode@2, anthropic/claude-code): each of its settings, its value, its source and the recipe's own default.") var agent: String?
    @Flag(name: .long, help: "Every setting, every recipe's included (--json always has every one).") var all = false

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
            // 669 (659 Q10): Dozable's own, and one line for the recipes; --all lists every recipe's keys too.
            let rows = all ? report.settings : report.settings.filter { $0.agent == nil }
            var t = [["SETTING", "VALUE", "SOURCE", "DEFAULT"]]
            for r in rows {
                t.append([r.key, Self.shown(r.value), sourceWord(r), r.value == r.defaultValue ? "" : Self.shown(r.defaultValue)])
            }
            Out.stdout(Out.table(t))
            if !all {
                Out.stdout("\n" + RecipeStates.line(RecipeStates.all(store: g.dozableStore, settings: s))
                           + " — doz config show --agent ID lists one, --all every one\n")
            }
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
    @Argument(help: "section.name, e.g. ui.boot_view_on_start (with --agent: the recipe's option, e.g. version; with --sandbox: approvals too)") var key: String
    @Option(name: .long, help: "A sandbox: its value of a per-sandbox setting (its own, else the setting's).") var sandbox: String?
    @Option(name: .long, help: "A recipe (claude-code, opencode@2, anthropic/claude-code): KEY is one of its options.") var agent: String?

    func run() async throws {
        if let sandbox {
            let key = try sandboxKey(self.key, agent: agent, g)
            guard let row = try await sandboxSettingsCall(sandbox, change: nil, g).settings.first(where: { $0.key == key }) else {
                throw fail(HostError(.invalid, "\(key) is not a setting of \(sandbox) — doz config show --sandbox \(sandbox) lists them"), g)
            }
            if g.json { Out.json(row) } else { Out.stdout(row.value.plain + "\n") }
            return
        }
        let key = try namedSetting(self.key, agent: agent, g).key
        let s = DozableSettings.load()
        let row = s.report(flags: configFlags(g)).settings.first { $0.key == key }!
        if g.json { Out.json(row); return }
        settingsWarnings(s, g)
        Out.stdout(row.value.plain + "\n")
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set",
        abstract: "Set one setting — on this Mac (doz.toml, the default), for one sandbox (--sandbox) or in a project (--project).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "section.name, e.g. ui.boot_view_on_start (with --agent: the recipe's option, e.g. version; with --sandbox or --project: approvals too)") var key: String
    @Argument(help: "The value: true/false, a number, or one of the setting's choices.") var value: String
    @Option(name: .long, help: "Set it for this sandbox only (a per-sandbox setting, or approvals; it wins over its project's and this Mac's).") var sandbox: String?
    @Option(name: .long, help: "Set it in the doz_project.yaml of this folder (a per-sandbox setting, or approvals): its sandbox gets it when made and at every doz up.") var project: String?
    @Option(name: .long, help: "A recipe (claude-code, opencode@2, anthropic/claude-code): KEY is one of its options.") var agent: String?

    func run() async throws {
        if sandbox != nil, project != nil { throw ValidationError("--sandbox or --project, not both") }
        if let sandbox {
            let key = try sandboxKey(self.key, agent: agent, g)
            let rep = try await sandboxSettingsCall(sandbox, change: (key, value), g)
            if g.json { Out.json(rep); return }
            let now = rep.settings.first { $0.key == key }
            Out.stdout("\(key) = \(now?.value.plain ?? value) for \(rep.sandbox) (its own) — \(DozableSettings.sandboxDefinition(key)?.applies.note ?? "")\n")
            return
        }
        if let project {
            try ConfigProject.change(folder: project, key: try sandboxKey(self.key, agent: agent, g), value: value, g)
            return
        }
        let d = try namedSetting(self.key, agent: agent, g)
        let key = d.key
        let v: TOMLValue
        do { v = try d.parse(value) } catch let e as SettingsError { throw fail(HostError(.invalid, e.message), g) }
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
    static let configuration = CommandConfiguration(commandName: "unset",
        abstract: "Put one setting back — this Mac's to its default (commented out), a sandbox's or a project's to follow the layer below.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "section.name (with --agent: the recipe's option, e.g. version; with --sandbox or --project: approvals too)") var key: String
    @Option(name: .long, help: "Clear this sandbox's own value: it follows its project's, else this Mac's, again.") var sandbox: String?
    @Option(name: .long, help: "Remove it from the doz_project.yaml of this folder.") var project: String?
    @Option(name: .long, help: "A recipe (claude-code, opencode@2, anthropic/claude-code): KEY is one of its options.") var agent: String?

    func run() async throws {
        if sandbox != nil, project != nil { throw ValidationError("--sandbox or --project, not both") }
        if let sandbox {
            let key = try sandboxKey(self.key, agent: agent, g)
            let rep = try await sandboxSettingsCall(sandbox, change: (key, nil), g)
            if g.json { Out.json(rep); return }
            let now = rep.settings.first { $0.key == key }
            Out.stdout("\(key) for \(rep.sandbox) follows the setting again (\(now?.value.plain ?? "?"), \(now?.source ?? "?")) — \(DozableSettings.sandboxDefinition(key)?.applies.note ?? "")\n")
            return
        }
        if let project {
            try ConfigProject.change(folder: project, key: try sandboxKey(self.key, agent: agent, g), value: nil, g)
            return
        }
        let d = try namedSetting(self.key, agent: agent, g)
        let key = d.key
        let now: DozableSettings
        do { now = try DozableSettings.load().writing(key, nil) } catch let e as SettingsError { throw fail(HostError(.failed, e.message), g) }
        sayMigration(now, g)
        if g.json { Out.json(now.report(flags: configFlags(g)).settings.first { $0.key == key }!); return }
        Out.stdout("\(key) is \(d.agent != nil ? "the recipe's default" : "the default") (\(d.defaultValue.plain)) in \(now.url?.path ?? "?") (this Mac)\n")
    }
}

/// 669 (659 §7): `--project DIR` — the project layer: its doz_project.yaml changed in place through the one renderer
/// (`DozableProject.render`, as doz init and New sandbox write it), the difference said line by line. A file that does
/// not parse is refused, never rewritten.
enum ConfigProject {
    static func change(folder: String, key: String, value: String?, _ g: GlobalOptions) throws {
        let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        let file: URL
        var p: DozableProject
        do {
            guard let f = try DozableProject.find(in: dir) else {
                throw fail(HostError(.notFound, "no \(DozableProject.fileName) in \(dir.path) — doz init writes one"), g)
            }
            file = f
            p = try DozableProject.load(f)
        } catch let e as DozableProject.Invalid {
            throw fail(HostError(.invalid, "\(e.message) — fix it first; it was not changed"), g)
        }
        guard let pk = DozableProject.settingKeys.first(where: { $0.setting == key }) else {
            throw fail(HostError(.invalid, "\(key) is not a project key (they are: \(DozableProject.settingKeys.map(\.key).joined(separator: ", ")))"), g)
        }
        if key == SettingKey.sandboxApprovals, DozableSettings.approvalsKey(image: p.image) == nil {
            throw fail(HostError(.invalid, "approvals: this project's agent (\(p.image)) has no approval prompts to skip or ask"), g)
        }
        let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if let value {
            guard let d = DozableSettings.sandboxDefinition(key, image: p.image) else { throw fail(HostError(.invalid, "\(pk.key): not for this project's image"), g) }
            do { p.settings[key] = try d.parse(value) } catch let e as SettingsError {
                throw fail(HostError(.invalid, "\(pk.key): \(e.message.replacingOccurrences(of: d.key, with: pk.key))"), g)
            }
        } else {
            p.settings[key] = nil
        }
        let text = p.render()
        // The new text must read back as the same project (the parser is the file's contract).
        guard (try? DozableProject.parse(text, file: file.lastPathComponent)) != nil else {
            throw fail(HostError(.failed, "the new \(file.lastPathComponent) would not read back — it was not changed"), g)
        }
        if text != old {
            do { try text.write(to: file, atomically: true, encoding: .utf8) } catch {
                throw fail(HostError(.failed, "could not write \(file.path): \(error.localizedDescription)"), g)
            }
        }
        if g.json { Out.json(["file": .string(file.path), "key": .string(pk.key), "value": value.map(JSONValue.string) ?? .null] as [String: JSONValue]); return }
        if !g.quiet {
            for l in DozableProject.lineDiff(old: old, new: text) where !l.hasPrefix("  ") { Out.stderr(l + "\n") }
        }
        Out.stdout(value.map { "\(pk.key): \($0) in \(file.path) (the project)" } ?? "\(pk.key) removed from \(file.path) (the project)")
        Out.stdout(" — its sandbox gets it when made and at every doz up\n")
    }
}

struct ConfigInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "init",
        abstract: "Write the settings file: every setting with its default commented out — a recipe's own once one of them is set (an existing file keeps its values and gains any new settings).")
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
