import Foundation

/// START for a worker (`doz worker add`) — pure (`WorkerKickoffTests`): who it is, its task in one line and its room (the
/// first lines keep the manager's shape: `You are NAME, …` / `Your room in chat: ROOM`), who directs it, how it talks
/// (dozchat with `CHAT_TOKEN_FILE`), its skills, a bot's instructions, what it can do where it runs, what to do first, and
/// the task in full. Never a token. Dozable posts nothing in the room: the worker says it is up itself.
public enum WorkerKickoff {
    /// Where it runs, as START tells it.
    public enum Where: Equatable, Sendable {
        case fenced, vm, unfenced
        /// In a sandbox another agent of the workspace runs in.
        case shared(String)
    }

    public static func startText(name: String, workspace: String, room: String, task: String, director: String?, place: Where,
                                 skills: [String], instructions: String?) -> String {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = WorkerLaunch.shortTask(t, limit: 200)
        var s = "You are \(name), a worker in the workspace \(workspace). Your task: \(firstLine)\n"
        s += "Your room in chat: \(room)\n\n"
        s += "A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is for, and any folders it works on (usually projects).\n\n"
        s += "## Who directs you\n\n"
        s += director.map { "\($0), the workspace's manager, in \(room). Report to them there; the person reads the room too.\n\n" }
            ?? "The person, in \(room). Report to them there.\n\n"
        s += "## How you talk\n\n"
        s += "Use `dozchat` (on your PATH): `dozchat send \(room) \"…\"` to post, `dozchat receive --wait 60 --ack` to collect what is said to you. "
        s += "Your token is in the file named by $\(ManagerLaunch.tokenFileVariable); never print it, never put it in a message or a file.\n\n"
        s += "## Skills\n\n"
        s += (["chat-worker", "chat-room-member"] + skills).map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        if let i = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !i.isEmpty {
            s += "## Your instructions\n\n" + i + "\n\n"
        }
        s += "## What you can do\n\n"
        switch place {
        case .fenced:
            s += "You run fenced on this Mac: you work in your folder, and reach only what your network permissions allow. You cannot start or stop agents: ask in the room.\n\n"
        case .vm:
            s += "You run in a micro VM of your own: your folder is shared at /workspace, and you reach only what its network permissions allow. You cannot start or stop agents: ask in the room.\n\n"
        case .shared(let x):
            s += "You run in the sandbox \(x), which other agents of the workspace share: they can read your files and placeholders there, and you theirs. You cannot start or stop agents: ask in the room.\n\n"
        case .unfenced:
            s += "You act as the person: what you do is done as them. Ask in the room before anything you are not sure of.\n\n"
        }
        s += "## First\n\n"
        s += "Say in \(room) that you are up, with your task in a few words. Then do the task.\n\n"
        s += "## Your task\n\n" + t + "\n"
        return s
    }
}
