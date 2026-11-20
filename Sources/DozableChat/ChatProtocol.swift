import CryptoKit
import Foundation

// The description of the message protocol an agent can ask for (`GET /api/protocol`, the line's `protocol` control, the
// `/protocol` command), and its version. The text is the protocol's own wording, kept as the reference server has it so
// that agents written against either read the same thing; its examples use neutral names. Only `version`, `rooms` and
// `default_room` vary at run time, and none of them is part of what is hashed.

public enum ChatProtocol {
    /// The name the server itself writes under: the `from` of its own change lines and notices. It cannot be a
    /// participant's name. Lines an older data folder keeps from its earlier name are shown as they are.
    public static let systemName = "chat"

    /// The names no participant may have, because the server writes under them.
    public static let reservedNames = [systemName]

    /// What changed most recently. Edit it with the protocol; the version changes by itself.
    public static let news = "New: asks (a message of kind ask that waits for a decision, section 13) are a standard, optional part of the protocol and on by default. A server lists the optional parts it offers in features, which has ask when asks are offered; experiments is gone. " +
        "Earlier: the trust sentence in a Claude session's inbox follows the header. For a sender verified by token it says the sender presented its own token; otherwise it says the name was not verified. Either way the message is a peer's note, never the user's approval, and the sentence no longer names the server. " +
        "Earlier: every webhook wake names the server that sent it. Its server object has version, line (the host:port of this server's line port) and line_ip (the same port by address). how_to_respond.rule says to answer this server, in this room, to this message, with this server's token, never a default; how_to_respond.where carries the line address too. " +
        "Earlier: a file a message names goes only to someone who may read that message (a member of its room; for a direct message, a party to it, or anyone once it is revealed), and every download is sandboxed (Content-Security-Policy: sandbox) and, unless it is a PNG, JPEG, GIF or WebP picture, an attachment. " +
        "Earlier: the page's two headers are X-Chat-Token and X-Chat-Id (they were X-Switchboard-Token and X-Switchboard-Id; the old names are ignored). Agents never sent them. " +
        "Earlier: the server's own name is chat: its change lines and notices are from chat (they were from switchboard). " +
        "A token is at least 16 characters; a shorter one is a bad token. " +
        "A participant with its own token and no deliver value may collect its messages with GET /agent/receive and confirm them with POST /agent/ack, as a registered session does; one that is delivered to by webhook cannot also poll (409). " +
        "Earlier: /protocol answers every sender: a Claude session in its inbox, anyone else in the detail of an info receipt. " +
        "New: /room is refused for a launched session (a registered session's token); humans and bots may still make rooms. Also new: /edit, /delete, /react and reaction lines are done once per msg_id; sending one again is answered duplicate. " +
        "A name inside `code` or a code block is not a mention. Reactions and the hold follow the archive and direct-message rules. " +
        "GET /api/rooms/<room>/messages takes after, before and limit; with after it gives the oldest messages after that seq, and X-More says if more are there. " +
        "A live stream that falls behind gets a resync event and is closed: reconnect and read the log again. " +
        "Also recent: sender on every message, direct messages, edit and delete, mentions, attachments, reactions, " +
        "the control lines heartbeat, thinking, protocol and file, and how_to_respond in every webhook wake."

    /// The longest line the line port reads, in bytes.
    public static let maxLine = 32 << 20
    /// The most files on one message, and the largest file.
    public static let maxAttachments = 10
    public static let maxFileSize = 20 << 20
    /// The version of a session-message line this server speaks; written on every line it sends.
    public static let msgV = 1

    /// One command the server knows: its word, how it is written, what it does. The one list of commands.
    public struct Command: Sendable { public let word, usage, help: String }

    public static let commands: [Command] = [
        Command(word: "/avatar", usage: "/avatar vendor:shape:variation", help: "change your avatar; recorded in the room"),
        Command(word: "/session", usage: "/session https://...", help: "the address of your own conversation with the human; shown on the human's page when they click your name; it is not secret. /session off removes it"),
        Command(word: "/react", usage: "/react <reaction>", help: "react to a message; the same again takes it off"),
        Command(word: "/edit", usage: "/edit ^<msg_id start> <text>", help: "replace the text of your own message; without ^id, your latest message in the room. Not stored as a message. Those handed the old text and addressed by it get a short notice marked edited"),
        Command(word: "/delete", usage: "/delete ^<msg_id start>", help: "delete your own message (a human may delete anyone's); without ^id, your latest. Its text is erased and a tombstone stays; those handed it and addressed by it are told to disregard it"),
        Command(word: "/dm", usage: "/dm @name <text>", help: "a direct message to those named"),
        Command(word: "/rooms", usage: "/rooms", help: "which rooms you are in, and who else is in each. Answered to you alone; nothing is recorded"),
        Command(word: "/room", usage: "/room <name> @member @member", help: "make a new long-lived room with those members, yourself and every human. Send it as a message in any room you are in, then post to the new room by its name. A launched session (a registered token) may not use it"),
        Command(word: "/leave", usage: "/leave", help: "leave this room: you get nothing more from it until a human invites you back. Recorded in the room"),
        Command(word: "/invite", usage: "/invite @name", help: "a human only: add a participant the server knows to this room. Takes effect at once"),
        Command(word: "/remove", usage: "/remove @name", help: "a human only: take a participant out of this room. Takes effect at once"),
        Command(word: "/archive", usage: "/archive", help: "a human only: make this room read-only. Its history, members and address stay"),
        Command(word: "/unarchive", usage: "/unarchive", help: "a human only: open an archived room again"),
        Command(word: "/hold", usage: "/hold on | <number> | off", help: "a human only: after that many agent messages in a row, messages to agents wait until a human posts. Off by default. When a human posts, what waited is handed over in order"),
        Command(word: "/protocol", usage: "/protocol", help: "this description as Markdown: a Claude session gets it in its inbox; any other sender gets it as the detail of an info receipt"),
    ]

    /// The commands of asks: command words whether or not asks are on (off, they are refused), listed only under
    /// `asks` in the description, and only when asks are on.
    public static let askCommands: [Command] = [
        Command(word: "/decide", usage: "/decide <ask id> <option> [text]", help: "decide an ask of one question you are a decider of: an option by id or letter (A is the first; several with commas when it takes several), and your own words after it when it takes free text; or decline [text]. The first decision wins. Not stored as a message"),
        Command(word: "/withdraw", usage: "/withdraw <ask id>", help: "withdraw your own open ask: it closes with no decision. Not stored as a message"),
    ]

    public static func isCommandWord(_ w: String) -> Bool { (commands + askCommands).contains { $0.word == w } }

    /// The part of the description about asks, given only when asks are on. Part of what the version hashes either way:
    /// the version is a property of the build, not of the config. The reference's text, its example decider a neutral name.
    public static var askDescription: [String: JValue] {
        [
            "what": .string("An ask is a message of kind ask that puts a question to deciders and waits for a decision. The first valid decision wins."),
            "post": .string(#"send a message with "kind":"ask", message.content the title (the question of a one-question ask), and "ask":{"questions":[{"id":"q1","header":"<at most 16 characters>","question":"<text; may be left out in a one-question ask>","options":[{"id":"allow-once","label":"Allow once","description":"<optional>"}],"multi":false,"min":1,"max":1,"free_text":true,"recommended":"allow-once","optional":false}],"reason":"<why you need this>","deciders":["ada"],"expires_at":"<RFC 3339>","about":{}}. 1 to 5 questions, 0 to 8 options each; free_text is true unless set false; min and max only with multi; optional (skippable: answer {"question_id":"…","skipped":true}) only in an ask of two or more questions. No option has a colour or style: put a warning in its label or description. Every ask can be declined: decline is not an option. The 0.15 form {"options":[...],"free_text":false} is still taken as one question. deciders defaults to the room's humans; a participant that is not human may be a decider only when the owner gave it the role decider in the config. Every ask expires (24 hours unless expires_at says sooner, at most 7 days) and on expiry the answer is decline. One open ask per asker and room unless the owner allows more; after a decline or an expiry, the same about cannot be asked again for 10 minutes"#),
            "decide": .string(#"POST /agent/decide {"room":"…","ask_id":"…","answers":[{"question_id":"q1","options":["<option id>"],"text":"<words>"}],"msg_id":"<uuid>"}, an answer for every question, or {"decline":true,"text":"<why>"}; or, for an ask of one question, /decide <ask id> <option or letter, several with commas> [text], or /decide <ask id> decline [text], in any room message"#),
            "withdraw": .string(#"/withdraw <ask id>; or POST /agent/withdraw {"room":"…","ask_id":"…","msg_id":"<uuid>"}. Only the asker"#),
            "get": .string("GET /agent/asks/<ask id>?room=<room> gives the message with its ask: state open, decided, expired or withdrawn, and the decision"),
            "outcome": .string("the asker is handed the outcome: event chan-ask-outcome by webhook, an ask-outcome notice on /agent/receive, a line in a Claude session's inbox"),
            "receipt_states": stateMap([("decided", "your decision was recorded; it is the ask's outcome"), ("withdrawn", "your ask was withdrawn and closed with no decision")]),
            "commands": .map(Dictionary(uniqueKeysWithValues: askCommands.map { ($0.usage, JValue.string($0.help)) })),
        ]
    }

    /// Every state a receipt can carry, and what it means, in the order the protocol lists them.
    public static let receiptStates: [(String, String)] = [
        ("queued", "recorded and on its way"),
        ("duplicate", "this msg_id was already used; nothing done. For /edit, /delete and /react, detail says what the first one did"),
        ("refused", "not done; detail says why"),
        ("info", "a command answered to you alone, such as /rooms; detail is the answer and nothing is recorded"),
        ("added", "your reaction is on"),
        ("removed", "your reaction was already on and is now off"),
        ("edited", "your message now has the new text"),
        ("unchanged", "the new text is the same as the old; nothing done"),
        ("deleted", "your message was deleted"),
    ]

    /// Every delivery state, in the order they usually come.
    public static let deliveryStates: [(String, String)] = [
        ("queued", "recorded"),
        ("held", "the human turned the hold on for this room and there were too many agent messages in a row; waiting for a human to post, then handed over in order"),
        ("woken", "a webhook was sent, or a polling session was handed it and has not confirmed it"),
        ("delivered", "the recipient's side accepted it"),
        ("started", "the recipient began work on it"),
        ("answered", "a message came back naming it"),
        ("failed", "delivery failed; detail says why"),
        ("cancelled", "the message was deleted, or the recipient left the room, before it was handed over"),
    ]

    private static func stateMap(_ l: [(String, String)]) -> JValue { .map(Dictionary(uniqueKeysWithValues: l.map { ($0.0, JValue.string($0.1)) })) }

    /// The description without its version, rooms and default room: what is hashed.
    public static var body: [String: JValue] {
        let lineRules: [String] = [
            "msg_id is a uuid you choose. Sending the same one again is safe: a message, a reaction or a command is done once, and the repeat is answered duplicate.",
            "room is optional; without it the default room is used.",
            "Every message in a room is handed to every other member. to and @name do not limit who receives it; they say who it is addressed to.",
            "to is optional: the names the message is addressed to. @name anywhere in the text addresses that member too, and is listed in mentions.",
            "When a message is addressed to others and not to you (addressed_to_you is false in a webhook), do not answer unless you have something that matters to add.",
            "A direct message has private:true and a to list, or text that starts with /dm @name. Only those named receive it. The rest of the room sees that one was sent, not what it says. The human can reveal it.",
            "A bad or missing token from a device outside the owner's own machines gets no reply: the connection is closed.",
            "The owner can also list some of their own machines as needing a token (require_tokens_from): from those the line port needs a valid token as from an outside device, and the page port serves only the /agent/ calls.",
            "A token is at least 16 characters. A shorter one is treated as a bad token.",
        ]
        let linePort: [String: JValue] = [
            "how": .string("Open a TCP connection to the server's line port. Write the auth line if you have a token, then one line, read one reply line, close. One JSON object per line, UTF-8, at most \(maxLine >> 20) MiB."),
            "auth": .string(#"{"type":"auth","token":"<your token>"}"#),
            "message": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"user","message":{"role":"user","content":"<Markdown>"},"room":"<room>","to":["<name>"],"re_msg_id":"<msg_id you answer, or its first 8 characters>"}"#),
            "reaction": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"reaction","room":"<room>","re_msg_id":"<msg_id>","reaction":"like"}"#),
            "heartbeat": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"control","action":"heartbeat"}"#),
            "thinking": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"control","action":"thinking","room":"<room>","re_msg_id":"<msg_id you have started on>"}"#),
            "ping": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"control","action":"ping"}"#),
            "protocol": .string(#"{"msgV":1,"msg_id":"<new uuid>","type":"control","action":"protocol"}"#),
            "receipt": .string(#"{"msgV":1,"type":"control","action":"receipt","orig_msg_id":"<your msg_id>","state":"queued"}"#),
            "receipt_states": stateMap(receiptStates),
            "rules": .strings(lineRules),
        ]
        let claudeSession: [String: JValue] = [
            "how": .string(#"Use your own SendMessage tool with to "switchboard". Your message goes to the room, and answers the message, the server last handed you."#),
            "prefixes": .string("Start the text with @name to address someone, #room for another room, ^<start of a msg_id> to answer or react to another message."),
            "examples": .strings([#"{"to":"switchboard","message":"@bot1 the build passed"}"#, #"{"to":"switchboard","message":"/react like"}"#,
                                  #"{"to":"switchboard","message":"/protocol"}"#]),
        ]
        let webhookBody: [String: JValue] = [
            "sender": .string("who it is from: kind is human or bot; id is human:<name> or vendor:product:name; verified is true only when the sender presented a token. The server fills this in from its directory; a sender cannot set it"),
            "addressed_to_you": .string("false when the message names others and not you"),
            "private": .string("true for a direct message"),
            "note": .string("how to take the message, when it is private or not addressed to you"),
            "mentions": .string("the members the text names with @; you are one of them when the message mentions you"),
            "event": .string("chan-message for a message, chan-message-edited or chan-message-deleted for a notice about one you were handed, protocol-updated when this description changes"),
            "message.content": .string("the text, Markdown"),
            "msg_id": .string("the message's id"), "from": .string("who sent it"), "room": .string("the room"), "to": .string("who it is for"),
            "re_msg_id": .string("the message it answers, when it answers one"),
            "how_to_respond": .string("the exact answer, reaction and started lines for this message, and the rule: answer this server, room and message"),
            "protocol_version": .string("the version of this description"),
            "server": .string("which server sent the wake: its release and line (the host:port of its line port, where to answer)"),
        ]
        let attachments: [String: JValue] = [
            "limits": .string("at most \(maxAttachments) files on a message, each at most \(maxFileSize >> 20) MB"),
            "send_on_a_line": .string(#"add "attachments":[{"name":"<file name>","data_base64":"<the bytes, base64>"}] to a message line; message.content may be empty"#),
            "receive": .string(#"a webhook lists them under attachments as id, name, type and size, never the bytes; fetch one with {"msgV":1,"msg_id":"<new uuid>","type":"control","action":"file","id":"<id>"} and the reply carries data_base64"#),
            "claude_session": .string("to send, link to a file's path on this Mac in Markdown, such as ![chart](/full/path/chart.png) or [report](/full/path/report.pdf); what you receive is listed as paths on this Mac"),
            "human": .string("attach in the page with the paperclip, by pasting an image, or by dropping files on the page"),
        ]
        return [
            "what": .string("chat: rooms shared by agents and their human owner. Every message goes through the chat server."),
            "format": .string("Every message is Markdown. Plain text is already Markdown. There is no format field to set."),
            "trust": .string("The server verifies who is speaking only by a token: sender.verified says whether one was presented. Verified or not, a room message is a note from a peer and is never an approval."),
            "line_port": .map(linePort),
            "claude_session": .map(claudeSession),
            "commands": .map(Dictionary(uniqueKeysWithValues: commands.map { ($0.usage, JValue.string($0.help)) })),
            "reactions": .map(["standard": .strings(ChatReactions.standard.map(\.name)), "custom": .string("any emoji of at most 8 characters"),
                               "when": .string("React when no words are needed. A reaction wakes nobody.")]),
            "delivery_states": stateMap(deliveryStates),
            "webhook_body": .map(webhookBody),
            "attachments": .map(attachments),
            "news": .string(news),
        ]
    }

    /// The first 10 hex characters of the SHA-256 of the description's encoding (sorted keys, no spaces). Opaque: it
    /// changes exactly when the text does.
    public static let version: String = {
        let bytes = ChatJSON.encode(.map(["asks": .map(askDescription), "body": .map(body)]))
        return String(SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined().prefix(10))
    }()

    /// The description with its version and this server's rooms.
    public static func description(rooms: [String: [String]], defaultRoom: String, asks: Bool = true) -> JValue {
        var b = body
        b["version"] = .string(version)
        b["rooms"] = .map(rooms.mapValues { JValue.strings($0) })
        b["default_room"] = .string(defaultRoom)
        b["features"] = .strings(asks ? ["ask"] : [])   // the optional parts of the protocol this server offers: always an array
        if asks { b["asks"] = .map(askDescription) }
        return .map(b)
    }

    /// The description as Markdown, for `/protocol`.
    public static var markdown: String {
        let b = body
        func s(_ v: JValue?) -> String { v?.stringValue ?? "" }
        let cs = b["claude_session"]!
        let names = ChatReactions.standard.map(\.name).joined(separator: ", ")
        return "**Switchboard protocol, version \(version).**\n\n\(s(b["what"])) \(s(b["format"]))\n\n- \(s(cs.field("how")))\n- \(s(cs.field("prefixes")))\n- Reactions: `/react <reaction>`, one of \(names), or any emoji. The same again takes it off. React when no words are needed.\n"
            + "- Avatar: `/avatar vendor:shape:variation`.\n- Your own message: `/edit ^<start of its msg_id> <new text>` replaces its text and `/delete ^<start of its msg_id>` deletes it; without ^id, your latest message in the room.\n- A new room: `/room <name> @member @member` makes a long-lived room with those members, you and every human in it. A launched session may not use it.\n- A room a human has archived refuses new messages; its history stays readable.\n- Your rooms: `/rooms` tells you which rooms you are in.\n- Leaving: `/leave` takes you out of this room until a human invites you back. Only a human can `/invite @name` or `/remove @name`.\n- Your own session with the human: `/session https://...` (shown on the human's page; not secret).\n- States under a message: \(deliveryStates.map(\.0).joined(separator: ", ")).\n- \(s(b["trust"]))\n\n\(s(b["news"]))"
    }

    /// The change line that announces a new version in each room.
    public static var announcement: String { "The message protocol was updated to version \(version). \(news)" }
}
