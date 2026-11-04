import Foundation
import DozableKit

/// 674: keeping an agent's conversations. Some agents delete their own history after a while (Claude Code: 30 days); the
/// recipe's `launch@1 history.keep` names the vendor's own file and keys that mean "keep". They are set ONCE per sandbox, in
/// the guest set-up (`Sandbox.applyAgentSettings`: a start, a wake's background steps — like the dotfiles), as the image's
/// user, and remembered by a marker in the guest — never at a session open (that races an agent rewriting its own file and
/// would bring back a key the person deleted). Never baked, so no image, bake key or launcher changes and an existing
/// sandbox gets it at its next start or wake.
///
/// The setting (Step 2): `agent.history` (`keep` | `agent-default`), each mapped recipe's `recipes.V.P.history` (`follow`
/// too), a project's or one sandbox's `history` — the most specific value that is not `follow` wins
/// (`DozableSettings.history(agent:own:from:)`). The value is part of the fingerprint, so a changed setting applies once
/// at the sandbox's next start or wake.
///
/// - `keep`: a key is set ONLY when it is absent (parent objects / tables made as needed); a value that is there, the
///   person's own, is left alone.
/// - `agent-default`: a key is removed only when it is there AND holds exactly Dozable's value (and a parent object or
///   table that this leaves empty goes too); any other value is the person's and stays.
///
/// Either way: a file that does not parse is never written (a note says so); a missing file is made 0600 with its folders
/// (keep only); the write is atomic (temp + rename); and nothing is rewritten when nothing changes (mtime stays).
///
/// JSON is read and written with python3's json. TOML (Codex's config.toml) has no writer on every base (tomllib is
/// read-only and only in 3.11+), so it is a minimal LINE-BASED edit: every line must be a blank, a comment, a `[table]` /
/// `[[array]]` header or a `key = value` (multi-line strings and arrays followed to their end), else the file is "not
/// understood" and left as it is. `keep` inserts `key = value` right under an existing `[table]` header, or appends a new
/// `[table]` when nothing defines that table yet (a table made by dotted keys, an array of tables or a value in the way:
/// left alone, with a note). `agent-default` removes the one line that holds exactly Dozable's value (and the table's
/// header when nothing but blank lines is left under it).
public enum AgentHistory {
    public static let keep = "keep"
    public static let agentDefault = "agent-default"
    public static let follow = "follow"
    /// `agent.history`'s values.
    public static let values = [keep, agentDefault]
    /// A recipe's (and a project's, a sandbox's) `history`: `follow` = the next layer's.
    public static let recipeChoices = [follow, keep, agentDefault]

    /// The guest script for a recipe's `keep` entries at `value` (nil: the recipe maps nothing to write). python3 — every
    /// base has it. Prints one `note: …` line per thing it left alone; always exits 0 (best effort).
    public static func script(_ history: AgentRecipe.Launch.History?, value: String = AgentHistory.keep) -> String? {
        guard let keep = history?.keep, !keep.isEmpty, values.contains(value) else { return nil }
        let entries = keep.map { ["file": $0.file, "set": $0.set.mapValues(\.plain)] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8), !json.contains("'"), !json.contains("\\") else { return nil }
        return #"""
        import os, re, tempfile
        from json import loads, dumps
        MODE = '\#(value)'
        ENTRIES = loads('\#(json)')
        DQ3 = '"' * 3
        SQ3 = "'" * 3
        def note(text):
            print('note: ' + text)
        class Unknown(Exception):
            pass
        def same(a, b):
            return type(a) == type(b) and a == b
        # JSON
        def keep_in(doc, dotted, value):
            parts = dotted.split('.')
            node = doc
            for p in parts[:-1]:
                if p not in node:
                    node[p] = {}
                node = node[p]
                if not isinstance(node, dict):
                    return None
            if parts[-1] in node:
                return False
            node[parts[-1]] = value
            return True
        def drop_in(doc, dotted, value):
            parts = dotted.split('.')
            chain = [doc]
            node = doc
            for p in parts[:-1]:
                if not isinstance(node, dict) or p not in node:
                    return False
                node = node[p]
                chain.append(node)
            if not isinstance(node, dict) or parts[-1] not in node or not same(node[parts[-1]], value):
                return False
            del node[parts[-1]]
            for i in range(len(parts) - 1, 0, -1):
                if chain[i] == {}:
                    del chain[i - 1][parts[i - 1]]
                else:
                    break
            return True
        def json_edit(text, keys):
            doc = {}
            if text.strip():
                doc = loads(text)
            if not isinstance(doc, dict):
                raise ValueError('not a JSON object')
            changed = False
            for dotted, value in keys:
                if MODE == 'keep':
                    r = keep_in(doc, dotted, value)
                    if r is None:
                        note(entry['file'] + ': ' + dotted + ' is inside something that is not an object - left as it is')
                    elif r:
                        changed = True
                elif drop_in(doc, dotted, value):
                    changed = True
            if not changed:
                return None
            return dumps(doc, indent=2, ensure_ascii=False) + '\n'
        # TOML: a minimal line-based reading; anything else is not understood and the file is left as it is.
        KEY = r'(?:[A-Za-z0-9_-]+|"(?:[^"\\]|\\.)*"|' + "'[^']*')"
        KEYSEG = re.compile(r'\s*(?:([A-Za-z0-9_-]+)|"((?:[^"\\]|\\.)*)"|' + "'([^']*)')" + r'\s*')
        HEADER = re.compile(r'^\s*\[\s*([^\[\]]+?)\s*\]\s*(#.*)?$')
        AHEADER = re.compile(r'^\s*\[\[\s*([^\[\]]+?)\s*\]\]\s*(#.*)?$')
        ASSIGN = re.compile(r'^\s*(' + KEY + r'(?:\s*\.\s*' + KEY + r')*)\s*=\s*(.*)$')
        STRINGS = re.compile(r'"(?:[^"\\]|\\.)*"|' + "'[^']*'")
        SCALAR = re.compile(r'^("(?:[^"\\]|\\.)*"|' + "'[^']*'" + r'|[^\s#]+)\s*(#.*)?$')
        def toml_path(text):
            parts = []
            pos = 0
            while True:
                m = KEYSEG.match(text, pos)
                if not m or m.end() == pos:
                    return None
                parts.append([g for g in m.groups() if g is not None][0] if any(g is not None for g in m.groups()) else '')
                pos = m.end()
                if pos == len(text):
                    return parts
                if text[pos] != '.':
                    return None
                pos += 1
        def brackets(text):
            t = STRINGS.sub('', text).split('#')[0]
            return t.count('[') - t.count(']')
        def toml_scan(lines):
            roles = []
            table = []
            ml = None
            depth = 0
            for line in lines:
                if ml is not None:
                    if line.count(ml) % 2 == 1:
                        ml = None
                    roles.append(('cont', None, None))
                    continue
                if depth > 0:
                    depth += brackets(line)
                    roles.append(('cont', None, None))
                    continue
                s = line.strip()
                if not s:
                    roles.append(('blank', None, None))
                    continue
                if s.startswith('#'):
                    roles.append(('comment', None, None))
                    continue
                m = AHEADER.match(line) or HEADER.match(line)
                if m:
                    p = toml_path(m.group(1))
                    if p is None:
                        raise Unknown('a table name it does not read')
                    kind = 'aheader' if s.startswith('[[') else 'header'
                    table = ([None] + p) if kind == 'aheader' else p
                    roles.append((kind, p, None))
                    continue
                m = ASSIGN.match(line)
                if not m:
                    raise Unknown('a line it does not read')
                k = toml_path(m.group(1))
                if k is None:
                    raise Unknown('a key it does not read')
                value = m.group(2).strip()
                if value.startswith(DQ3) or value.startswith(SQ3):
                    if value.count(value[:3]) == 1:
                        ml = value[:3]
                elif value.startswith('['):
                    depth = brackets(value)
                    if depth < 0:
                        raise Unknown('an array it does not read')
                roles.append(('assign', table + k, value))
            if ml is not None or depth > 0:
                raise Unknown('a string or an array that does not end')
            return roles
        def render(v):
            if isinstance(v, bool):
                return 'true' if v else 'false'
            if isinstance(v, (int, float)):
                return repr(v)
            return '"' + v + '"'
        def toml_keep(text, lines, roles, dotted, value):
            P = dotted.split('.')
            T = P[:-1]
            line = P[-1] + ' = ' + render(value)
            assigns = [r[1] for r in roles if r[0] == 'assign']
            if P in assigns:
                return None
            for a in assigns:
                if len(a) < len(P) and P[:len(a)] == a:
                    raise Unknown(dotted + ' is inside a value that is not a table')
            for r in roles:
                if r[0] == 'aheader' and (P[:len(r[1])] == r[1] or r[1][:len(P)] == P):
                    raise Unknown(dotted + ' is inside an array of tables')
            if not T:
                lines.insert(0, line)
                return lines
            for i, r in enumerate(roles):
                if r[0] == 'header' and r[1] == T:
                    lines.insert(i + 1, line)
                    return lines
            for r in roles:
                if r[0] in ('header', 'assign') and r[1][:len(T)] == T:
                    raise Unknown('[' + '.'.join(T) + '] is made in a way it does not edit')
            while lines and lines[-1] == '':
                lines.pop()
            if lines:
                lines.append('')
            return lines + ['[' + '.'.join(T) + ']', line, '']
        def toml_drop(text, lines, roles, dotted, value):
            P = dotted.split('.')
            T = P[:-1]
            hits = [i for i, r in enumerate(roles) if r[0] == 'assign' and r[1] == P]
            if len(hits) != 1:
                return None
            i = hits[0]
            m = SCALAR.match(roles[i][2])
            want = render(value)
            if not m or not (m.group(1) == want or (isinstance(value, str) and m.group(1) == "'" + value + "'")):
                return None
            h = None
            for j in range(i - 1, -1, -1):
                if roles[j][0] in ('header', 'aheader'):
                    h = j if roles[j][0] == 'header' and roles[j][1] == T else None
                    break
            del lines[i]
            del roles[i]
            if T and h is not None:
                j = h + 1
                while j < len(roles) and roles[j][0] == 'blank':
                    j += 1
                if j == len(roles) or roles[j][0] in ('header', 'aheader'):
                    del lines[h:j]
                    if j == len(roles) and lines and lines[-1] != '':
                        lines.append('')
            return lines
        def toml_edit(text, keys):
            if '\r' in text:
                raise Unknown('Windows line ends')
            lines = text.split('\n')
            changed = False
            for dotted, value in keys:
                roles = toml_scan(lines)
                try:
                    new = (toml_keep if MODE == 'keep' else toml_drop)(text, lines, roles, dotted, value)
                except Unknown as e:
                    note(entry['file'] + ': ' + str(e) + ' - ' + dotted + ' left as it is')
                    continue
                if new is not None:
                    lines = new
                    changed = True
            if not changed:
                return None
            return '\n'.join(lines)
        for entry in ENTRIES:
            path = os.path.join(os.path.expanduser('~'), entry['file'][2:])
            try:
                exists = os.path.exists(path)
                if not exists and MODE != 'keep':
                    continue
                text = ''
                if exists:
                    with open(path, 'r', encoding='utf-8') as f:
                        text = f.read()
                keys = sorted(entry['set'].items())
                if path.endswith('.toml'):
                    try:
                        toml_scan(text.split('\n'))
                    except Unknown as e:
                        raise ValueError(str(e))
                    out = toml_edit(text, keys)
                else:
                    out = json_edit(text, keys)
                if out is None:
                    continue
                folder = os.path.dirname(path)
                if not os.path.isdir(folder):
                    os.makedirs(folder, mode=0o700)
                mode = (os.stat(path).st_mode & 0o777) if exists else 0o600
                fd, tmp = tempfile.mkstemp(dir=folder, prefix='.doz-tmp-')
                try:
                    with os.fdopen(fd, 'w', encoding='utf-8') as w:
                        w.write(out)
                    os.chmod(tmp, mode)
                    os.replace(tmp, path)
                except BaseException:
                    if os.path.exists(tmp):
                        os.remove(tmp)
                    raise
            except ValueError as e:
                note(entry['file'] + ' does not parse (' + str(e) + ') - left as it is')
            except Exception as e:
                note(entry['file'] + ': ' + str(e))
        """#
    }
}

private extension RecipeValue {
    /// The plain JSON value (a scalar: the recipe's validation allows nothing else).
    var plain: Any {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return Int64(n) }
            return n
        default: return NSNull()
        }
    }

    /// As a person reads it in the mapping (`36500`, `"save-all"`, `false`).
    var shown: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .bool(let b): return b ? "true" : "false"
        case .number: return "\(plain)"
        default: return "?"
        }
    }
}

extension AgentHistory {
    /// What names the mapping: every entry's file and its keys with their values (sorted), and the value. A changed mapping
    /// or value is a different fingerprint, so it applies once more.
    public static func fingerprint(_ history: AgentRecipe.Launch.History, value: String = AgentHistory.keep) -> String {
        var parts = (history.keep ?? []).map { k in
            k.file + "|" + k.set.keys.sorted().map { "\($0)=\(k.set[$0]!.plain)" }.joined(separator: ",")
        }
        parts.append("value=" + value)
        return AgentSettingsInputs.fingerprint(of: parts)
    }

    /// What a sandbox of this recipe is handed at `value` (nil: the recipe maps nothing to write — none, or `native: keeps`).
    public static func inputs(for recipe: AgentRecipe, value: String = AgentHistory.keep) -> AgentSettingsInputs? {
        guard let history = recipe.launch.history, let script = script(history, value: value) else { return nil }
        return AgentSettingsInputs(title: recipe.title, script: script, fingerprint: fingerprint(history, value: value))
    }
}

// MARK: what each value does in each agent — the Settings page's and the recipe page's table, `doz config show --agent`

/// One agent's conversation-history mapping, in words: what Dozable does in that agent at each value of the setting.
public struct HistoryMapping: Codable, Equatable, Sendable {
    /// One key Dozable writes for `keep`.
    public struct Write: Codable, Equatable, Sendable {
        public var file: String
        public var key: String
        public var value: String
    }
    public var agent: String
    public var title: String
    /// `writes` (Dozable writes the vendor's keys), `keeps` (it keeps its conversations by itself — nothing written),
    /// `unknown` (no mapping researched: the setting does not apply to it).
    public var kind: String
    /// What Dozable does at `keep`, and at `agent-default`.
    public var keep: String
    public var agentDefault: String
    public var writes: [Write]?
    /// The vendor's own words (`agent_default` or the `note`).
    public var note: String?
    public var source: String?
    public var checked: String?
    /// The value a sandbox of this agent gets on this Mac (no sandbox's or project's own) and the setting that decided it.
    public var effective: String
    public var effectiveKey: String
    public var effectiveSource: SettingSource
}

extension AgentHistory {
    static let nothingKeeps = "nothing — it keeps conversations by itself"
    static let notKnown = "not known — the setting does not apply"

    /// One recipe's mapping (its effective value from `settings`).
    public static func mapping(_ r: AgentRecipe, settings: DozableSettings) -> HistoryMapping {
        let e = settings.history(agent: r.id)
        var m = HistoryMapping(agent: r.id, title: r.title, kind: "unknown", keep: notKnown, agentDefault: notKnown,
                               effective: e.value, effectiveKey: e.key, effectiveSource: e.source)
        guard let h = r.launch.history else { return m }
        m.source = h.source
        m.checked = h.checked
        if h.native == "keeps" {
            m.kind = "keeps"
            m.keep = nothingKeeps
            m.agentDefault = nothingKeeps
            m.note = h.note
            return m
        }
        let writes = (h.keep ?? []).flatMap { k in k.set.keys.sorted().map { HistoryMapping.Write(file: k.file, key: $0, value: k.set[$0]!.shown) } }
        let what = writes.map { "\($0.key) = \($0.value) in \($0.file)" }.joined(separator: "; ")
        let keys = writes.map(\.key).joined(separator: ", ")
        m.kind = "writes"
        m.writes = writes
        m.keep = "sets \(what) — only where it is not set (your own value is kept)"
        m.agentDefault = "takes back \(keys) where it still holds Dozable's value — \(h.agentDefault ?? "the agent follows its own rule")"
        m.note = h.agentDefault
        return m
    }

    /// The agents the Dozable-wide setting is shown for: every published coding agent, and any other recipe that maps it.
    public static func mappings(settings: DozableSettings) -> [HistoryMapping] {
        AgentRecipes.all
            .filter { $0.launch.history != nil || ($0.isPublished && $0.catalogKind == "coding-agent") }
            .sorted { ($0.launch.history == nil ? 1 : 0, $0.title) < ($1.launch.history == nil ? 1 : 0, $1.title) }
            .map { mapping($0, settings: settings) }
    }

    /// `agent.history`'s description.
    static let agentSummary = "Conversation history in sandboxes. keep: Dozable asks each agent to keep its conversations — an agent that deletes old ones by itself (Claude Code after 30 days) is told not to, by a key in its own settings file, set only where you have not set one. agent-default: each agent follows its own rule (Dozable takes back only a key that still holds its own value). A value you set in the agent's own settings file is always kept. Each agent's recipe can choose its own (Recipes), and so can a project (history: in doz_project.yaml) or one sandbox (doz config set --sandbox NAME history VALUE). Set once in each sandbox when it next starts or wakes; doz config show --agent ID shows what each value does in that agent."

    /// A recipe's `history` description, with what its mapping writes.
    static func recipeSummary(_ r: AgentRecipe, _ h: AgentRecipe.Launch.History) -> String {
        let lead = "\(r.title)'s conversation history: follow (agent.history, Dozable's choice), keep, or agent-default."
        if h.native == "keeps" {
            return lead + " \(r.title) keeps its conversations by itself, so Dozable writes nothing at any value. \(h.note ?? "")"
        }
        let what = (h.keep ?? []).flatMap { k in k.set.keys.sorted().map { "\($0) = \(k.set[$0]!.shown) in \(k.file)" } }.joined(separator: "; ")
        return lead + " keep: \(what), only where it is not set. agent-default: that key is taken back where it still holds Dozable's value — \(h.agentDefault ?? "the agent follows its own rule")."
    }
}

extension HostCore {
    /// Give the sandbox the agent's settings to set once in its guest set-up (a start, a wake's background steps) — like
    /// the dotfiles. Called when it is loaded and before every request about it (a changed setting is followed: its value
    /// is in the fingerprint). A sandbox with no agent recipe mapping gets none.
    func applyAgentSettingsInput(_ m: Managed, settings: DozableSettings = .load()) {
        guard !readOnly else { return }
        guard m.config.spec.imageSpec != nil, let recipe = m.config.imageChoice?.agent.recipe else { m.sandbox.setAgentSettings(nil); return }
        let value = settings.history(agent: recipe.id, own: m.config.settings?[SettingKey.sandboxHistory],
                                     from: m.config.settingsFrom?[SettingKey.sandboxHistory]).value
        m.sandbox.setAgentSettings(AgentHistory.inputs(for: recipe, value: value))
    }
}
