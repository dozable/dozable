import DozableChat
import Foundation

// The workspace drawn (docs/engineering/web.md, "The workspace drawn"): the vendored renderer (`space-render.js`, the peer's
// at its pin) reads a space file with its OWN reader, which knows space/3.1 and only the `x-dozable` keys of its pin. The
// space editor's page never meets that reader's verdict — it hands the editor Dozable's plan (`workspace-space-plan`), so
// its problems are Dozable's — but `render()` takes no plan: a file that uses Dozable's newer keys (`x-dozable.places` with
// `where: PLACE`, `x-dozable.feeds`) read as "not a place" / "unknown key" there, and the Home picture showed the problem
// marker for a file `plan` and the editor accept.
//
// So the picture is given the SAME document in the words the renderer knows — only what it draws, nothing it would act on:
// - a vm place (owned or external) is a sandbox under `sandboxes:` of the place's name (its image, cpus and memory), and an
//   agent `where: PLACE` in it is `where: sandbox:PLACE` — the VM drawn as the sandbox it is;
// - a fenced or unfenced place is this Mac: its agents `where: mac` with the place's `isolation` — a fenced place's agents
//   drawn fenced (each in its own fence, as each is);
// - `x-dozable.places` and `x-dozable.feeds` are left out (the renderer draws neither); the rest is the file as written.
// A file that uses none of these is drawn from its own text (nil here). Never sent to the daemon, never saved, never planned.

public enum SpacePicture {
    /// The top-level `x-dozable` keys the renderer at its pin does not read (Dozable's own, newer than it).
    public static let unreadTopKeys = ["places", "feeds"]

    /// `doc` in the renderer's words, or nil when it already is (no place, no feed).
    public static func document(_ doc: JValue) -> JValue? {
        guard case .object(var top) = doc, let xi = top.lastIndex(where: { $0.key == SpaceDozable.key }),
              case .object(var x) = top[xi].value, x.contains(where: { unreadTopKeys.contains($0.key) }) else { return nil }
        // The places by name: (isolation, the place's map). An external place is a vm one (an existing sandbox).
        var places: [String: (isolation: String, map: JValue)] = [:]
        for m in SpaceDoc.members(SpaceDoc.member(top[xi].value, "places")) {
            let iso = SpaceDoc.member(m.value, "external") != nil ? "vm" : SpaceDoc.string(SpaceDoc.member(m.value, "isolation")) ?? ""
            if WorkspacePlace.isolations.contains(iso) { places[m.key] = (iso, m.value) }
        }
        x.removeAll { unreadTopKeys.contains($0.key) }
        if x.isEmpty { top.remove(at: xi) } else { top[xi].value = .object(x) }

        /// One agent's (or agent_defaults') map with its `where: PLACE` in the renderer's words.
        func placed(_ v: JValue) -> JValue {
            guard case .object(var a) = v, let wi = a.lastIndex(where: { $0.key == "where" }),
                  let w = SpaceDoc.string(a[wi].value), let p = places[w] else { return v }
            if p.isolation == "vm" {
                a[wi].value = .string("sandbox:" + w)
            } else {
                a[wi].value = .string("mac")
                if !a.contains(where: { $0.key == "isolation" }) { a.insert(JMember("isolation", .string(p.isolation)), at: wi + 1) }
            }
            return .object(a)
        }
        for i in top.indices {
            switch top[i].key {
            case "agents": top[i].value = .object(SpaceDoc.members(top[i].value).map { JMember($0.key, placed($0.value)) })
            case "agent_defaults": top[i].value = placed(top[i].value)
            default: break
            }
        }
        // Each vm place as a sandbox of its name (unless the file names one so already), in the places' order.
        let vms = SpaceDoc.members(SpaceDoc.member(doc, SpaceDozable.key).flatMap { SpaceDoc.member($0, "places") })
            .filter { places[$0.key]?.isolation == "vm" }
        if !vms.isEmpty {
            let si = top.lastIndex { $0.key == "sandboxes" }
            var sandboxes = si.map { SpaceDoc.members(top[$0].value) } ?? []
            for m in vms where !sandboxes.contains(where: { $0.key == m.key }) {
                var s: [JMember] = []
                if let e = SpaceDoc.member(m.value, "external") {
                    s.append(JMember("external", .string(SpaceDoc.string(SpaceDoc.member(e, "sandbox")) ?? m.key)))
                } else {
                    for k in WorkspacePlace.vmKeys { if let v = SpaceDoc.member(m.value, k) { s.append(JMember(k, v)) } }
                }
                sandboxes.append(JMember(m.key, .object(s)))
            }
            if let si { top[si].value = .object(sandboxes) } else { top.append(JMember("sandboxes", .object(sandboxes))) }
        }
        return .object(top)
    }

    // 781: a workspace made with no space file is drawn too — from its document (`RecordDocument.generate`, the one `doz
    // workspace doc` writes). Two of the generated document's shapes do not read at the renderer's pin, so the picture says
    // them in words it draws (only what it draws; never sent anywhere, never saved, never planned):
    // - a linked room (`external: doz://HOST/OWNER/room/ROOM`): "unknown node" there — drawn as a room of its key;
    // - a worker on this Mac (`isolation:` and no `where:`) beside a vm `agent_defaults` (the workspace's new workers run in
    //   VMs): "an agent in a sandbox is never unfenced" — it is on this Mac, said with `where: mac`.
    // `hiding`: the keys of agents the viewer may not see (another computer while serve.mac_sessions is off) — left out.

    /// A record's document in the renderer's words, as the text it reads (Dozable's places and feeds too, as `document`).
    public static func recordDocument(_ doc: JValue, hiding: Set<String> = []) -> String {
        guard case .object(var top) = doc else { return text(doc) }
        for i in top.indices {
            switch top[i].key {
            case "agents":
                var agents: [JMember] = []
                for m in SpaceDoc.members(top[i].value) where !hiding.contains(m.key) {
                    guard case .object(var a) = m.value, !a.contains(where: { $0.key == "where" }),
                          let iso = a.firstIndex(where: { $0.key == "isolation" }) else { agents.append(m); continue }
                    a.insert(JMember("where", .string("mac")), at: iso)
                    agents.append(JMember(m.key, .object(a)))
                }
                top[i].value = .object(agents)
            case "chat":
                guard case .object(var chat) = top[i].value, let ri = chat.firstIndex(where: { $0.key == "rooms" }) else { continue }
                chat[ri].value = .object(SpaceDoc.members(chat[ri].value).map { m in
                    guard case .object(let r) = m.value, r.contains(where: { $0.key == "external" }) else { return m }
                    return JMember(m.key, .object(r.filter { $0.key != "external" }))
                })
                top[i].value = .object(chat)
            default: break
            }
        }
        let out = JValue.object(top)
        return text(document(out) ?? out)
    }

    /// A document as a space file's text the renderer reads: its version line first, as written (the renderer looks for
    /// `doz: space/3…` on it), then each top-level key with its value in JSON's flow form (YAML reads JSON).
    public static func text(_ doc: JValue) -> String {
        let members = SpaceDoc.members(doc)
        var lines: [String] = []
        if let v = SpaceDoc.string(SpaceDoc.member(doc, "doz")), v.allSatisfy({ $0.isLetter || $0.isNumber || "/.-_".contains($0) }) {
            lines.append("doz: " + v)
        } else if let v = SpaceDoc.member(doc, "doz") {
            lines.append("doz: " + SpaceDoc.text(v))
        }
        for m in members where m.key != "doz" { lines.append(SpaceDoc.text(.string(m.key)) + ": " + SpaceDoc.text(m.value)) }
        return lines.joined(separator: "\n") + "\n"
    }
}
