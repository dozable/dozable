import CryptoKit
import DozableChat
import DozableHost
import Foundation
import Yams

/// Reading a space file (`NAME.space.yaml`, space/3) the way the CLI must: the `extends:` chain of defaults files (each
/// after the files it extends; a loop is an error naming the chain), the file, `NAME.space.override.yaml` beside it,
/// `${VAR}` from the environment and the `.env` beside it (values only, never keys, never under `secrets:`), merged —
/// maps merge, lists replace, `null` removes. Every place keeps where it was set (`SpaceOrigin`), so a message and a risky
/// setting can name its file and line. Yams stays here (the audit holds it); the daemon receives the merged document,
/// never a file. The words of each refusal are the reference's (`SpaceValidationTableTests`).
struct SpaceResolver {
    static let maximumFileBytes = 256 << 10

    /// One file read: its source, its document and its own lines.
    struct Layer {
        var source: SpaceSource
        var doc: JValue
        var lines: [String: SpaceOrigin]
        var text: String
    }

    struct Resolved {
        var sources: [SpaceSource] = []
        var layers: [Layer] = []
        /// The merged document as written (`{space}` and `{run}` unfilled, `extends:` resolved away).
        var merged: JValue = .object([])
        var origins: [String: SpaceOrigin] = [:]
        /// The resolver's own problems and each defaults file's.
        var problems: [SpaceProblem] = []
        /// A file could not be read or parsed, or `extends:` failed: nothing was merged.
        var broken = false
        var file: String = ""

        var locator: SpaceLocator { SpaceLocator(sources: sources, origins: origins) }
        var spaceName: String { SpaceDoc.string(SpaceDoc.member(merged, "space")) ?? "" }
        /// What the daemon receives: `{space}` filled (`{run}` stays).
        var filled: JValue { SpaceDoc.fillSpace(merged, space: spaceName) }

        /// Every problem: the resolver's, each source's and the merged document's (the CLI's look before it sends anything).
        func check(profiles: [String] = []) -> (problems: [SpaceProblem], model: SpaceModel?) {
            if broken { return (problems, nil) }
            let m = SpaceValidator.checkMerged(filled, locator, profiles: profiles)
            return (SpaceValidator.report(sourceProblems: problems, merged: m.problems), m.model)
        }

        func request(profiles: [String], brief: SpaceBriefLook?) -> SpaceRequest {
            SpaceRequest(spec: SpaceDoc.text(filled), sources: sources, origins: origins, specPath: file, brief: brief,
                         profiles: profiles.isEmpty ? nil : profiles)
        }
    }

    /// What `~` stands for (`TestSafety.spaceHome`: the real home; a guarded run's `DOZ_TEST_HOME`).
    var home = TestSafety.spaceHome()
    var environment = ProcessInfo.processInfo.environment
    var read: (String) -> String? = { p in
        guard let d = FileManager.default.contents(atPath: p), d.count <= SpaceResolver.maximumFileBytes else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: finding the file

    /// Without `-f`: the one `*.space.yaml` in `dir` (none, or two or more, is refused, listing them).
    static func find(in dir: String) throws -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".space.yaml") && !$0.hasSuffix(".space.override.yaml") }.sorted()
        guard !names.isEmpty else { throw HostError(.notFound, "no *.space.yaml in \(DisplayPath.tilde(dir)) — name one with -f FILE") }
        guard names.count == 1 else {
            throw HostError(.unclearRequest, "\(names.count) space files in \(DisplayPath.tilde(dir)): \(names.joined(separator: ", ")) — name one with -f FILE")
        }
        return (dir as NSString).appendingPathComponent(names[0])
    }

    /// `NAME.space.yaml` → `NAME.space.override.yaml` beside it.
    static func overridePath(_ file: String) -> String {
        file.hasSuffix(".yaml") ? String(file.dropLast(5)) + ".override.yaml" : file + ".override.yaml"
    }

    static func sha256(_ s: String) -> String { SpaceDoc.sha256(s) }

    // MARK: resolving

    func resolve(_ file0: String) -> Resolved {
        let file = URL(fileURLWithPath: file0).standardizedFileURL.path
        var r = Resolved()
        r.file = file
        let name = (file as NSString).lastPathComponent
        guard let text = read(file) else {
            r.problems.append(SpaceProblem(pointer: "", message: "cannot read \(DisplayPath.tilde(file)) (a UTF-8 file of at most 256 KiB)", file: name, line: 1))
            r.broken = true
            return r
        }

        // extends: the defaults files, lowest first.
        var defaults: [(path: String, text: String)] = []
        var seen: Set<String> = []
        func visit(_ path: String, _ text: String, _ stack: [String]) {
            let (doc, lines, _) = Self.parse(text, name: (path as NSString).lastPathComponent)
            guard let doc else { return }
            let ext = SpaceDoc.member(doc, "extends")
            let list: [JValue] = ext == nil ? [] : SpaceDoc.array(ext) ?? [ext!]
            let isList = SpaceDoc.array(ext) != nil
            for (i, e) in list.enumerated() {
                let ptr = isList ? "/extends/\(i)" : "/extends"
                let here = (path as NSString).lastPathComponent
                let line = lines[ptr]?.l ?? 1
                guard let rel = SpaceDoc.string(e), !rel.trimmingCharacters(in: .whitespaces).isEmpty else {
                    r.problems.append(SpaceProblem(pointer: ptr, message: "extends: names a file (or a list of files)", file: here, line: line)); continue
                }
                let expanded = rel == "~" ? home : rel.hasPrefix("~/") ? home + String(rel.dropFirst(1)) : rel
                let target = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true))
                    .standardizedFileURL.path
                if stack.contains(target) {
                    let chain = (stack[stack.firstIndex(of: target)!...] + [target]).map { ($0 as NSString).lastPathComponent }.joined(separator: " → ")
                    r.problems.append(SpaceProblem(pointer: ptr, message: "extends goes round in a loop: \(chain)",
                                                   hint: "a defaults file can't extend, directly or not, a file that extends it", file: here, line: line))
                    continue
                }
                guard let t = read(target) else {
                    r.problems.append(SpaceProblem(pointer: ptr, message: "extends: no file \(rel)",
                                                   hint: "looked for \(target)" + (rel.hasPrefix("/") ? "" : " (relative to \(here))"), file: here, line: line))
                    continue
                }
                visit(target, t, stack + [target])
                if seen.insert(target).inserted { defaults.append((target, t)) }
            }
        }
        visit(file, text, [file])
        if r.problems.contains(where: \.isError) { r.broken = true; return r }

        // The layers, lowest first: the defaults, the file, the override; the .env.
        var files: [(path: String, text: String, kind: String)] = defaults.map { ($0.path, $0.text, "defaults") }
        files.append((file, text, "space"))
        let over = Self.overridePath(file)
        if FileManager.default.fileExists(atPath: over) {
            guard let t = read(over) else {
                r.problems.append(SpaceProblem(pointer: "", message: "cannot read \(DisplayPath.tilde(over))", file: (over as NSString).lastPathComponent, line: 1))
                r.broken = true
                return r
            }
            files.append((over, t, "override"))
        }
        for f in files {
            let n = (f.path as NSString).lastPathComponent
            let (doc, lines, problems) = Self.parse(f.text, name: n, override: f.kind == "override")
            r.problems += problems
            let src = SpaceSource(path: f.path, name: n, kind: f.kind, sha256: Self.sha256(f.text))
            r.sources.append(src)
            r.layers.append(Layer(source: src, doc: doc ?? .object([]), lines: lines, text: f.text))
        }
        let envPath = ((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".env")
        var env: [String: String] = [:]
        if let t = read(envPath) {
            env = Self.parseEnvFile(t)
            r.sources.append(SpaceSource(path: envPath, name: ".env", kind: "env", sha256: Self.sha256(t)))
        }
        for (k, v) in environment { env[k] = v }
        if r.problems.contains(where: \.isError) { r.broken = true; return r }

        // Each defaults file on its own.
        let spaceV31 = r.layers.first { $0.source.kind == "space" }.map { SpaceDozable.isV31($0.doc) }
        for l in r.layers where l.source.kind == "defaults" {
            r.problems += SpaceValidator.checkSource(l.doc, name: l.source.name, lines: l.lines, spaceV31: spaceV31)
        }

        // The merge, each place's origin, then ${VAR}.
        var merged: JValue? = .object([])
        for l in r.layers {
            var d = l.doc
            if l.source.kind == "defaults", case .object(let m) = d { d = .object(m.filter { $0.key != "doz" && $0.key != "extends" }) }
            merged = SpaceDoc.merge(merged, d)
        }
        if case .object(let m)? = merged { merged = .object(m.filter { $0.key != "extends" }) }
        var doc = merged ?? .object([])
        for p in SpaceDoc.pointers(doc) {
            if p.isEmpty, let i = r.layers.firstIndex(where: { $0.source.kind == "space" }) {
                r.origins[""] = SpaceOrigin(s: i, l: r.layers[i].lines[""]?.l ?? 1, k: r.layers[i].lines[""]?.k ?? 1)
                continue
            }
            for (i, l) in r.layers.enumerated().reversed() {
                if let o = l.lines[p] { r.origins[p] = SpaceOrigin(s: i, l: o.l, k: o.k); break }
            }
        }
        var missing: [(String, String)] = []
        doc = Self.substitute(doc, env, "", &missing)
        r.merged = doc
        let loc = r.locator
        for (p, name) in missing {
            let place = loc.place(p, key: false)
            var message = "${\(name)} is not set"
            switch loc.sources.indices.contains(r.origins[p]?.s ?? -1) ? loc.sources[r.origins[p]!.s].kind : "space" {
            case "override": message += " (in the override file)"
            case "defaults": message += " (from \(place.file))"
            default: break
            }
            r.problems.append(SpaceProblem(pointer: p, message: message,
                                           hint: "set \(name) in the .env file beside the space file, or in the environment; or give a default: ${\(name):-value}",
                                           file: place.file, line: place.line))
        }
        return r
    }

    // MARK: YAML → the ordered document and its lines

    /// The document (nil: it does not parse) and every pointer's lines. Plain scalars follow YAML 1.2's core schema (so
    /// `off` and `yes` stay text); quoted, literal and folded scalars are text. Anchors and aliases are refused.
    static func parse(_ text: String, name: String, override: Bool = false) -> (JValue?, [String: SpaceOrigin], [SpaceProblem]) {
        var lines: [String: SpaceOrigin] = [:]
        let suffix = override ? " (in the override file)" : ""
        func problem(_ m: String, _ line: Int, hint: String? = nil) -> SpaceProblem {
            SpaceProblem(pointer: "", message: "YAML: " + m + suffix, hint: hint, file: name, line: line)
        }
        let parser: Parser
        let root: Node?
        do {
            parser = try Parser(yaml: text)
            root = try parser.singleRoot()
        } catch YamlError.duplicatedKeysInMapping(let keys, let context) {
            return (nil, [:], [problem("Map keys must be unique (\(keys.joined(separator: ", ")))", context.mark.line,
                                       hint: "a key is written twice in the same map")])
        } catch {
            var line = 1, first = String(describing: error).split(separator: "\n").first.map(String.init) ?? "\(error)"
            switch error as? YamlError {
            case .scanner(_, let problem, let mark, _)?, .parser(_, let problem, let mark, _)?, .composer(_, let problem, let mark, _)?:
                line = mark.line; first = problem
            default: break
            }
            let lineText = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(max(0, line - 1)).first.map(String.init) ?? ""
            let hint = lineText.contains("${") ? "a ${VAR} inside [ ] or { } must be in quotes, e.g. ports: [\"${PORT}\"] (a value that is one ${VAR} alone still becomes a number)"
                : first.contains("mapping values") ? "text that contains \": \" (a colon and a space) must be in quotes, e.g. command: 'send \"a: b\"'" : nil
            return (nil, [:], [problem(first.contains("expected a single document") ? "one YAML document only" : first, line, hint: hint)])
        }
        defer { withExtendedLifetime(parser) {} }
        guard let root else { return (.object([]), ["": SpaceOrigin(s: 0, l: 1, k: 1)], []) }
        var problems: [SpaceProblem] = []
        func line(_ n: Node) -> Int { n.mark?.line ?? 1 }
        func convert(_ n: Node, _ p: String, keyLine: Int) -> JValue {
            lines[p] = SpaceOrigin(s: 0, l: line(n), k: keyLine)
            switch n {
            case .alias:
                problems.append(problem("anchors and aliases are not allowed", line(n)))
                return .null
            case .scalar(let s):
                if s.anchor != nil { problems.append(problem("anchors and aliases are not allowed", line(n))) }
                return scalar(s)
            case .sequence(let q):
                if q.anchor != nil { problems.append(problem("anchors and aliases are not allowed", line(n))) }
                return .array(q.enumerated().map { convert($0.element, p + "/\($0.offset)", keyLine: line($0.element)) })
            case .mapping(let m):
                if m.anchor != nil { problems.append(problem("anchors and aliases are not allowed", line(n))) }
                var out: [JMember] = []
                for (k, v) in m {
                    guard case .scalar(let ks) = k else { problems.append(problem("a key is a plain name", line(k))); continue }
                    let key = ks.string
                    out.append(JMember(key, convert(v, SpaceDoc.join(p, key), keyLine: line(k))))
                }
                return .object(out)
            }
        }
        let doc = convert(root, "", keyLine: line(root))
        return (doc, lines, problems)
    }

    static func scalar(_ s: Node.Scalar) -> JValue {
        guard s.style == .plain || s.style == .any else { return .string(s.string) }
        let t = s.string
        if ["", "~", "null", "Null", "NULL"].contains(t) { return .null }
        if ["true", "True", "TRUE"].contains(t) { return .bool(true) }
        if ["false", "False", "FALSE"].contains(t) { return .bool(false) }
        if t.range(of: "^[-+]?[0-9]+$", options: .regularExpression) != nil, let n = Int64(t.hasPrefix("+") ? String(t.dropFirst()) : t) { return .int(n) }
        if t.hasPrefix("0o"), let n = Int64(t.dropFirst(2), radix: 8) { return .int(n) }
        if t.hasPrefix("0x"), let n = Int64(t.dropFirst(2), radix: 16) { return .int(n) }
        if t.range(of: "^[-+]?(\\.[0-9]+|[0-9]+(\\.[0-9]*)?)([eE][-+]?[0-9]+)?$", options: .regularExpression) != nil, let d = Double(t) { return .double(d) }
        return .string(t)
    }

    // MARK: ${VAR}

    /// KEY=VALUE lines; # comments; optional quotes; `export ` allowed.
    static func parseEnvFile(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var l = Substring(line)
            if l.hasPrefix("export ") { l = l.dropFirst(7).drop { $0 == " " } }
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = l[..<eq].trimmingCharacters(in: .whitespaces)
            guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            var v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
                v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
            } else if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
                v = String(v.dropFirst().dropLast())
            } else if let r = v.range(of: "\\s+#.*$", options: .regularExpression) {
                v.removeSubrange(r)
            }
            out[k] = v
        }
        return out
    }

    /// `${VAR}`, `${VAR:-default}` and `$$` in every text but under `/secrets`. A value that is one `${VAR}` alone takes
    /// the type of what it becomes (`ports: ["${PORT}"]` is a number).
    static func substitute(_ v: JValue, _ env: [String: String], _ p: String, _ missing: inout [(String, String)]) -> JValue {
        if p == "/secrets" { return v }
        switch v {
        case .string(let s):
            let whole = s.range(of: "^\\$\\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\\}$", options: .regularExpression) != nil
            let out = substituteText(s, env, p, &missing)
            if whole && out != s {
                if out.range(of: "^-?[0-9]+$", options: .regularExpression) != nil, let n = Int64(out) { return .int(n) }
                if out.range(of: "^-?[0-9]+\\.[0-9]+$", options: .regularExpression) != nil, let d = Double(out) { return .double(d) }
                if out == "true" || out == "false" { return .bool(out == "true") }
            }
            return .string(out)
        case .array(let a): return .array(a.enumerated().map { substitute($0.element, env, p + "/\($0.offset)", &missing) })
        case .object(let m): return .object(m.map { JMember($0.key, substitute($0.value, env, SpaceDoc.join(p, $0.key), &missing)) })
        default: return v
        }
    }

    static func substituteText(_ s: String, _ env: [String: String], _ p: String, _ missing: inout [(String, String)]) -> String {
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "$", s.index(after: i) < s.endIndex {
                let j = s.index(after: i)
                if s[j] == "$" { out.append("$"); i = s.index(after: j); continue }
                if s[j] == "{", let close = s[j...].firstIndex(of: "}") {
                    let body = String(s[s.index(after: j)..<close])
                    let parts = body.components(separatedBy: ":-")
                    let name = parts[0]
                    if name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
                        let def: String? = parts.count > 1 ? parts.dropFirst().joined(separator: ":-") : nil
                        if let v = env[name], !v.isEmpty { out += v }
                        else if let def { out += def }
                        else { missing.append((p, name)); out += String(s[i...close]) }
                        i = s.index(after: close)
                        continue
                    }
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
