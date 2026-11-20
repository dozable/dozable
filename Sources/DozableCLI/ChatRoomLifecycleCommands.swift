import ArgumentParser
import Darwin
import Foundation
import DozableChat
import DozableHost

// `doz chat room archive R` and `doz chat room rm R`: check, then ask. Each looks first (`chat-room-plan`, answered from
// the store when no daemon runs), prints what it would do and every refusal; `--dry-run` stops there. Archive asks a plain
// yes; rm asks for the room's name typed on the terminal (`--yes` only with `--confirm R`). No terminal and no --yes: exit
// 5. A refusal exits 3. The daemon acts only on the plan you saw (its sha).

struct ChatRoomLifecycleArguments: ParsableArguments {
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The room.") var room: String
    @Flag(name: .customLong("dry-run"), help: "Show what it would do and every refusal; do nothing, start no daemon.") var dryRun = false
    @Flag(name: .shortAndLong, help: "Do not ask (rm: only with --confirm ROOM).") var yes = false
    @Flag(name: .customLong("loose"), help: "Take a loose room: one neither made nor linked by any of your workspaces (never a linked one).") var loose = false
}

func chatRoomPlanText(_ p: ChatRoomPlan) -> String {
    var s = "\(p.verb == "rm" ? "Remove" : "Archive") #\(p.room)? — \(p.state) now"
    if let id = p.id { s += " (\(id))" }
    s += "\n"
    s += "  owner: " + (p.owner.map { "the workspace \($0)" } ?? "none (a loose room)") + "\n"
    if !p.linkedBy.isEmpty { s += "  linked by: \(p.linkedBy.joined(separator: ", "))\n" }
    s += "  messages: " + (p.lastSeq.map { "up to \($0)" } ?? "not known") + "\n"
    if let a = p.archive {
        s += p.verb == "rm" ? "  its archived copy: the store's \(a)" + (p.run.map { " (run \($0))" } ?? "") + (p.archiveVerified == true ? ", verified now" : "") + "\n"
            : "  its whole history into the store's \(a), then it is archived as you (read-only)\n"
    }
    if !p.refusals.isEmpty { s += "It cannot be done:\n" + p.refusals.map { "  - \($0)\n" }.joined() }
    for n in p.notes { s += "note: \(n)\n" }
    s += "\nThe command:\n\(p.command)\n"
    return s
}

func runChatRoomLifecycle(_ verb: String, _ a: ChatRoomLifecycleArguments, confirmName: String?) async throws {
    let g = a.g
    guard chatIsRoomName(a.room) else { throw fail(HostError(.invalid, "\(a.room) is not a room name"), g) }
    var q = ChatRoomRequest(room: a.room, verb: verb)
    q.loose = a.loose ? true : nil
    var r = HostRequest(.chatRoomPlan)
    r.chatRoom = q
    let plan = try decode(try await query(r, g), ChatRoomPlan.self, g)
    let refusal = plan.refusals.first.map { HostError(HostError.Code(rawValue: plan.refusalCode ?? "") ?? .invalidPhase, $0) }
    if a.dryRun {
        if g.json { Out.json(plan) } else { Out.stdout(chatRoomPlanText(plan)) }
        if let refusal { throw ExitCode(DozableExit.code(for: refusal)) }
        return
    }
    if !g.json { Out.stdout(chatRoomPlanText(plan)) }
    if let refusal { throw fail(refusal, g) }
    if verb == "rm" {
        if a.yes {
            guard confirmName == a.room else {
                throw fail(HostError(.invalid, "rm with --yes needs --confirm \(a.room) (the room's name, typed)"), g, code: DozableExit.usage)
            }
            q.confirm = a.room
        } else {
            try confirmTypedName(a.room, verb: "remove", yes: false, g)
            q.confirm = a.room
        }
    } else {
        if g.json && !a.yes { throw fail(HostError(.failed, "archive \(a.room) asks first — --json asks nothing: pass --yes"), g, code: DozableExit.declined) }
        try confirm("Archive #\(a.room)? Its whole history is copied into the store, then it is read-only", yes: a.yes, g)
    }
    q.verb = nil
    q.ifPlan = plan.sha
    var act = HostRequest(verb == "rm" ? .chatRoomRm : .chatRoomArchive)
    act.chatRoom = q
    let c = try decode(try call(act, g), ChatRoomChanged.self, g)
    if g.json { Out.json(c); return }
    Out.stdout((verb == "rm" ? "#\(a.room) is removed for good" : "#\(a.room) is archived") + "\n" + c.notes.map { "note: \($0)\n" }.joined())
}

struct ChatRoomArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "Archive a room: its whole history copied into Dozable's store and verified, then it is read-only.",
        discussion: """
        Only a room a workspace made (or, with --loose, a loose room: neither made nor linked by any workspace); never a linked room, \
        never while its workspace's run is open. The copy — its messages and their attachments, swept for secrets — is in \
        the store's archives folder; then the room is archived as you. Asks first (--yes skips).
        """)
    @OptionGroup var a: ChatRoomLifecycleArguments
    func run() async throws { try await runChatRoomLifecycle("archive", a, confirmName: nil) }
}

struct ChatRoomRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove an archived room for good, once its archived copy is checked: a tombstone stays.",
        discussion: """
        The same rooms as archive. Refused unless the room is archived and an archived copy that holds every message \
        verifies now (its own, or its workspace's last run's); refused when anyone wrote in it since. The chat server \
        removes it — its members, its history and its files no other room names — and keeps running; the tombstone (doz \
        chat rooms --gone) says where its archive is. A new room of the same name is a new room. Asks for the name typed on \
        the terminal; --yes only with --confirm ROOM.
        """)
    @OptionGroup var a: ChatRoomLifecycleArguments
    @Option(name: .customLong("confirm"), help: "With --yes: the room's name, typed.") var confirmName: String?
    func run() async throws { try await runChatRoomLifecycle("rm", a, confirmName: confirmName) }
}

/// `doz chat room close R --loose` / `open R --loose`: a loose room closed to new messages (still readable), or opened again.
func runChatRoomCloseOpen(close: Bool, room: String, loose: Bool, _ g: GlobalOptions) throws {
    guard chatIsRoomName(room) else { throw fail(HostError(.invalid, "\(room) is not a room name"), g) }
    var q = ChatRoomRequest(room: room)
    q.loose = loose ? true : nil
    var r = HostRequest(close ? .chatRoomClose : .chatRoomOpen)
    r.chatRoom = q
    let c = try decode(try call(r, g), ChatRoomChanged.self, g)
    if g.json { Out.json(c); return }
    Out.stdout(c.notes.map { $0 + "\n" }.joined())
}

struct ChatRoomCloseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close", abstract: "Close a loose room to new messages; it can still be read.",
        discussion: """
        Only a loose room (--loose: neither made nor linked by any of your workspaces); a workspace's own rooms are closed by \
        its finish and opened by its reopen. A post, edit or reaction in a closed room is refused; reading it is not. \
        doz chat room open R --loose opens it again.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The room.") var room: String
    @Flag(name: .customLong("loose"), help: "Take a loose room: one neither made nor linked by any of your workspaces.") var loose = false
    func run() async throws { try runChatRoomCloseOpen(close: true, room: room, loose: loose, g) }
}

struct ChatRoomOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a loose room you closed again.",
        discussion: "Only a loose room (--loose); a workspace's own rooms are opened by its reopen.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The room.") var room: String
    @Flag(name: .customLong("loose"), help: "Take a loose room: one neither made nor linked by any of your workspaces.") var loose = false
    func run() async throws { try runChatRoomCloseOpen(close: false, room: room, loose: loose, g) }
}
