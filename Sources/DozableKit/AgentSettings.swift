import Foundation
import CryptoKit

/// 674: an agent's own settings that Dozable sets ONCE in a sandbox's guest — today the keys that keep an agent's
/// conversations (the recipe's `launch@1 history`). Applied like the person's dotfiles: in the guest set-up (a start, and a
/// wake's background steps), as the image's user, remembered in the guest by a marker, recorded on the Mac. Never at a
/// session open: that would race an agent rewriting its own file and bring back a key the person deleted.
///
/// The host hands a `Sandbox` an `AgentSettingsInputs` (the script and a fingerprint of what it maps — the Kit knows no
/// recipe); a preparation VM, a bake and a helper get none and never run it.
public struct AgentSettingsInputs: Sendable, Equatable {
    /// What a person reads in a note: the agent's title.
    public var title: String
    /// The guest script (python3, run as the image's user, always exits 0, prints `note: …` lines).
    public var script: String
    /// Names what the script maps — a changed mapping (or value) applies once more.
    public var fingerprint: String

    public init(title: String, script: String, fingerprint: String) {
        self.title = title
        self.script = script
        self.fingerprint = fingerprint
    }

    /// sha256 (hex) of the parts, in order.
    public static func fingerprint(of parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the last apply did — `<sandbox>/agent-history-run.json`.
public struct AgentSettingsRun: Codable, Equatable, Sendable {
    public var at: Date
    public var fingerprint: String
    /// `applied` or `failed`. A failed run is not retried at every wake (the marker is written either way).
    public var state: String
    public var notes: [String]

    public init(at: Date, fingerprint: String, state: String, notes: [String]) {
        self.at = at
        self.fingerprint = fingerprint
        self.state = state
        self.notes = notes
    }
}

public enum AgentSettingsLayer {
    /// The marker in the guest, under the image user's home: the fingerprint last applied.
    public static let markerRelative = ".local/share/doz/history.applied"

    public static func checkScript(home: String) -> String {
        "cat \"$HOME/\(markerRelative)\" 2>/dev/null; true"
    }

    public static func markerScript(fingerprint: String) -> String {
        "mkdir -p \"$HOME/.local/share/doz\" && printf '%s\\n' '\(fingerprint)' > \"$HOME/\(markerRelative)\""
    }

    /// One guest command's result (a closure so the rules run without a VM: the sandbox's is a real exec).
    public typealias Exec = @Sendable (_ argv: [String]) async throws -> (exitCode: Int32, output: String, error: String)

    /// Apply when the guest's marker is not the wanted fingerprint; nil when it is (nothing run, nothing written) or when
    /// the guest could not be looked at (next start or wake). Otherwise runs the script and writes the marker either way.
    public static func apply(_ input: AgentSettingsInputs, home: String, exec: Exec) async -> AgentSettingsRun? {
        do {
            let r = try await exec(["sh", "-c", checkScript(home: home)])
            if r.output.trimmingCharacters(in: .whitespacesAndNewlines) == input.fingerprint { return nil }
        } catch {
            return nil
        }
        var notes: [String] = []
        var ok = true
        do {
            let r = try await exec(["python3", "-c", input.script])
            if r.exitCode != 0 {
                ok = false
                notes.append("\(input.title)'s conversation history: the script exited \(r.exitCode): \(String(r.error.prefix(200)))")
            } else {
                for line in r.output.split(separator: "\n") where line.hasPrefix("note: ") {
                    notes.append("\(input.title)'s conversation history: \(line.dropFirst(6))")
                }
            }
        } catch {
            ok = false
            notes.append("\(input.title)'s conversation history: \(error.localizedDescription)")
        }
        // Remembered either way — a failing run is not retried at every wake.
        do {
            let r = try await exec(["sh", "-c", markerScript(fingerprint: input.fingerprint)])
            if r.exitCode != 0 { notes.append("could not record that \(input.title)'s conversation history was set (exit \(r.exitCode))") }
        } catch {
            notes.append("could not record that \(input.title)'s conversation history was set: \(error.localizedDescription)")
        }
        return AgentSettingsRun(at: Date(), fingerprint: input.fingerprint, state: ok ? "applied" : "failed", notes: notes)
    }
}
