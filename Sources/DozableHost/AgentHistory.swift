import Foundation
import DozableKit

/// 674: keeping an agent's conversations. Some agents delete their own history after a while (Claude Code: 30 days); the
/// recipe's `launch@1 history.keep` names the vendor's own file and keys that mean "keep", and the HOST writes them at every
/// session open, as the image's user — never baked, so no image, bake key or launcher changes and an existing sandbox gets
/// it at its next session.
///
/// `keep` semantics only: a key is set ONLY when it is absent (parent objects made as needed); a value that is there, the
/// person's own, is left alone; a file that does not parse is never written (a note says so); a missing file is made 0600
/// with its folders; the write is atomic (temp + rename); and nothing is rewritten when nothing changes (mtime stays).
public enum AgentHistory {
    /// The guest script for a recipe's `keep` entries (nil: the recipe maps nothing to write). python3 — every base has it.
    /// Prints one `note: …` line per thing it left alone; always exits 0 (best effort).
    public static func script(_ history: AgentRecipe.Launch.History?) -> String? {
        guard let keep = history?.keep, !keep.isEmpty else { return nil }
        let entries = keep.map { ["file": $0.file, "set": $0.set.mapValues(\.plain)] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8), !json.contains("'"), !json.contains("\\") else { return nil }
        return """
        import os, tempfile
        from json import loads, dump
        ENTRIES = loads('\(json)')
        def note(text):
            print('note: ' + text)
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
        for entry in ENTRIES:
            path = os.path.join(os.path.expanduser('~'), entry['file'][2:])
            try:
                doc = {}
                exists = os.path.exists(path)
                if exists:
                    with open(path, 'r', encoding='utf-8') as f:
                        text = f.read()
                    if text.strip():
                        doc = loads(text)
                    if not isinstance(doc, dict):
                        raise ValueError('not a JSON object')
                changed = False
                for dotted, value in entry['set'].items():
                    r = keep_in(doc, dotted, value)
                    if r is None:
                        note(entry['file'] + ': ' + dotted + ' is inside something that is not an object - left as it is')
                    elif r:
                        changed = True
                if not changed:
                    continue
                folder = os.path.dirname(path)
                if not os.path.isdir(folder):
                    os.makedirs(folder, mode=0o700)
                mode = (os.stat(path).st_mode & 0o777) if exists else 0o600
                fd, tmp = tempfile.mkstemp(dir=folder, prefix='.doz-tmp-')
                try:
                    with os.fdopen(fd, 'w', encoding='utf-8') as out:
                        dump(doc, out, indent=2, ensure_ascii=False)
                        out.write('\\n')
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
        """
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
}

extension HostCore {
    /// Write the recipe's history keys into the guest — a utility exec as the image's user, right after the agent prompt.
    /// Best effort: a failure is a note, the session still starts.
    func deliverAgentHistory(_ m: Managed) async {
        guard m.config.spec.imageSpec != nil, let recipe = m.config.imageChoice?.agent.recipe,
              let script = AgentHistory.script(recipe.launch.history) else { return }
        let ctx = Self.execContext(config: m.config, environment: [:], workdir: nil, user: nil)
        do {
            let r = try await m.sandbox.exec(["python3", "-c", script], environment: ctx.environment, workingDirectory: ctx.workdir,
                                             user: ctx.user, timeoutSeconds: 20)
            if r.exitCode != 0 {
                note(m.name, "could not keep \(recipe.title)'s conversation history (exit \(r.exitCode)): \(String(decoding: r.stderr.prefix(200), as: UTF8.self))")
            } else {
                for line in String(decoding: r.stdout, as: UTF8.self).split(separator: "\n") where line.hasPrefix("note: ") {
                    note(m.name, "\(recipe.title)'s conversation history: \(line.dropFirst(6))")
                }
            }
        } catch {
            note(m.name, "could not keep \(recipe.title)'s conversation history: \(error.localizedDescription)")
        }
    }
}
