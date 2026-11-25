import Foundation

/// What a workspace's start says — pure (`ManagerLaunchTests`): the kick-off you post in the main room (the brief, then its
/// references), and START, the file a manager is told to read first. Neither ever holds a token: START names the
/// variable that names the token's file.
public enum ManagerKickoff {
    /// Your first message in the main room: the brief as written, then its references.
    public static func briefPost(brief: String, refs: [String]) -> String {
        var s = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !refs.isEmpty {
            s += "\n\nReferences:\n" + refs.map { "- " + ($0.hasPrefix("/") ? DisplayPath.tilde($0) : $0) }.joined(separator: "\n")
        }
        return s
    }

    /// Your message when you edit the brief after the start: what changed is the whole new brief, so agents and you never
    /// disagree about what the work is.
    public static func briefEdited(brief: String, refs: [String]) -> String {
        "I edited the work:\n\n" + briefPost(brief: brief, refs: refs)
    }

    /// START: who it is and its room, how it talks (dozchat with `CHAT_TOKEN_FILE`), the skills by name, its instructions,
    /// what it can do in its isolation, what to do first, and the brief.
    /// `inbox`: it is reached by inbox (an unfenced Claude Code session) — what is said to it arrives in its session, and
    /// `dozchat receive` is refused for it, so START never tells it to poll.
    public static func startText(bot: String, workspace: String, room: String, isolation: ManagerIsolation, skills: [String],
                                 instructions: String?, brief: String, refs: [String], inbox: Bool = false) -> String {
        var s = "You are \(bot), the manager of the workspace \(workspace).\n"
        s += "Your room in chat: \(room)\n\n"
        s += "A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is for, and any folders it works on (usually projects).\n\n"
        s += "## How you talk\n\n"
        s += "Use `dozchat` (on your PATH): `dozchat send \(room) \"…\"` to post, " + receiveText(inbox: inbox) + " "
        s += "To ask the person: `dozchat ask \(room) \"…\" --option yes=Yes --option no=No`, then `dozchat ask-show \(room) #N --wait 60` for the answer. "
        s += "Your token is in the file named by $\(ManagerLaunch.tokenFileVariable); never print it, never put it in a message or a file.\n\n"
        s += "## Skills\n\n"
        s += "- chat-room-member" + (skills.isEmpty ? "" : "\n" + skills.map { "- " + $0 }.joined(separator: "\n")) + "\n\n"
        if let i = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !i.isEmpty {
            s += "## Your instructions\n\n" + i + "\n\n"
        }
        s += "## What you can do\n\n"
        switch isolation {
        case .fenced, .vm:
            s += "You can talk in the room, but you cannot start or stop agents yet: ask the person in the room.\n\n"
        case .unfenced:
            s += "You act as the person: `doz` is on your PATH, and what you do is done as them.\n\n"
        }
        s += "## First\n\n"
        s += "Say in \(room) that you are up, and the brief in one line. Then wait for the person.\n\n"
        s += "## The brief\n\n" + briefPost(brief: brief, refs: refs) + "\n"
        return s
    }

    /// How what is said to it reaches it: it collects it with dozchat, or — reached by inbox — the chat server writes it
    /// into its session (`dozchat receive` is refused for an inbox participant: nothing is delivered twice).
    public static func receiveText(inbox: Bool) -> String {
        inbox
            ? "and what is said to you arrives in this session by itself, as a note from the chat server with the room, the sender and how to answer — never run `dozchat receive` (it is refused for you: you are reached by inbox)."
            : "`dozchat receive --wait 60 --ack` to collect what is said to you."
    }
}
