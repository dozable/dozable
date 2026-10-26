import AVFoundation
import Foundation

// 667: the Mac's microphone for sandboxes with sound — doz settles macOS's question ITSELF, before any VM records.
//
// What 604 measured: Virtualization asks macOS (TCC) the moment a guest opens a recording, on behalf of the host's
// RESPONSIBLE app (the app that started doz — Terminal, iTerm, an editor), and while that question is open (a) a
// recording opened before the answer stays stuck even after Allow, and (b) pausing or saving the VM stops it
// ("Internal Virtualization error"). So a sound sandbox's VM gets the real microphone ONLY when macOS has already said
// yes (`Sandbox.setMicrophone`, `AudioDevice`); otherwise its microphone is silent and Virtualization never asks.
// doz asks — once, while the answer is not yet given — when `sandbox.microphone_ask` says (`MicrophoneAsk`): at the
// first recording in a sandbox with the microphone (the default — that recording stays silent; the sandbox records from
// the Mac once it is shut down and started again), or at its first start (waiting for the answer before that VM is
// built). The question names the same responsible app.
//
// The ONE file that imports AVFoundation (Scripts/audit.sh). Tests and probes never reach macOS here: in a guarded
// run (`TestSafety.guarded`) the answer is the seam `DOZ_TEST_MICROPHONE` (allowed | denied | undecided | restricted,
// default undecided) and nothing is ever asked; `DOZ_TEST_MICROPHONE_ANSWER` is what a seamed question is answered.

/// macOS's answer about the microphone for the app this doz is charged to.
public enum MicrophonePermission: String, Codable, Sendable, CaseIterable {
    /// Allowed: a sandbox's VM gets the Mac's microphone.
    case allowed
    /// Denied in System Settings › Privacy & Security › Microphone.
    case denied
    /// Not asked yet (or the question is still open).
    case undecided
    /// Not changeable here (a device policy).
    case restricted

    /// A line for a person (`ask`: when doz asks — `sandbox.microphone_ask`).
    public func sentence(ask: MicrophoneAsk = .firstRecording) -> String {
        switch self {
        case .allowed: "allowed"
        case .denied: "denied — System Settings › Privacy & Security › Microphone"
        case .undecided: "not asked yet — doz asks when a sandbox with the microphone first \(ask == .firstStart ? "starts" : "records") (sandbox.microphone_ask = \(ask.rawValue))"
        case .restricted: "restricted on this Mac (a device policy) — sandboxes record silence"
        }
    }
}

/// 667 (owner, 2026-10-27: "make it configurable (default to when first records)"): WHEN doz asks macOS about the
/// microphone, while macOS has no answer for the app doz is charged to — the setting `sandbox.microphone_ask`.
///
/// - `first_recording` (the default): a sandbox starts with a SILENT microphone and nothing is asked; the host watches
///   for the first recording in it (`HostCore+Sound`, `DozSound.recordingWatchScript`: a capture stream of the guest's
///   sound card running), and only then asks. A VM's microphone is fixed when it starts (and is part of its saved
///   state — a restore with another one fails), so THAT recording stays silent: after Allow, doz says to Shut Down and
///   Start the sandbox, which then records from the Mac's microphone.
/// - `first_start`: a cold boot of a sandbox with the microphone asks and waits for the answer (at most
///   `microphoneQuestionWait`) before its VM is built — the first recording already has the Mac's microphone.
public enum MicrophoneAsk: String, CaseIterable, Codable, Sendable {
    case firstRecording = "first_recording"
    case firstStart = "first_start"

    /// The setting's value (anything unreadable is the default).
    public static func of(_ v: TOMLValue) -> MicrophoneAsk {
        if case .string(let s) = v, let a = MicrophoneAsk(rawValue: s) { return a }
        return .firstRecording
    }
}

/// How the host learns and asks macOS's answer — the real Mac, or the test seam. Pure values: the host holds one.
public struct MicrophoneAccess: Sendable {
    public var status: @Sendable () -> MicrophonePermission
    /// Ask macOS (shows its question when undecided); the answer, or nil when none came within `timeout`.
    public var request: @Sendable (_ timeout: Duration) async -> MicrophonePermission?
    /// Whether this is the seam (said by doctor and the host log).
    public var seamed: Bool

    public init(status: @escaping @Sendable () -> MicrophonePermission,
                request: @escaping @Sendable (_ timeout: Duration) async -> MicrophonePermission?, seamed: Bool) {
        self.status = status
        self.request = request
        self.seamed = seamed
    }

    /// This process's: the seam in a guarded run (or when `DOZ_TEST_MICROPHONE` is set), else the Mac.
    public static func current(_ env: [String: String] = ProcessInfo.processInfo.environment) -> MicrophoneAccess {
        if TestSafety.guarded(env) || env["DOZ_TEST_MICROPHONE"] != nil { return seam(env) }
        return mac
    }

    /// The test seam: never reaches macOS. Like macOS it remembers an answer given to its question (in this process):
    /// after `DOZ_TEST_MICROPHONE_ANSWER` answered, the status is that answer.
    public static func seam(_ env: [String: String]) -> MicrophoneAccess {
        let now = AnswerBox(MicrophonePermission(rawValue: env["DOZ_TEST_MICROPHONE"] ?? "") ?? .undecided)
        let answer = MicrophonePermission(rawValue: env["DOZ_TEST_MICROPHONE_ANSWER"] ?? "")
        return MicrophoneAccess(status: { now.value }, request: { _ in
            guard now.value == .undecided else { return now.value }
            if let answer { now.value = answer }
            return answer
        }, seamed: true)
    }

    /// macOS (AVFoundation): the status is a preflight (never shows anything); the request shows macOS's question
    /// for the responsible app when undecided.
    public static let mac = MicrophoneAccess(
        status: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .allowed
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .undecided
            @unknown default: .undecided
            }
        },
        request: { timeout in
            // Whichever comes first: macOS's answer, or the end of the wait. A late answer is dropped here and read by
            // the next status check (macOS keeps it).
            await withCheckedContinuation { (c: CheckedContinuation<MicrophonePermission?, Never>) in
                let box = AnswerBox(false)
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    if box.first() { c.resume(returning: ok ? .allowed : .denied) }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    if box.first() { c.resume(returning: nil) }
                }
            }
        },
        seamed: false)

    /// A value behind a lock: one answer only (the request's completion may outlive the wait); the seam's answer.
    private final class AnswerBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get { lock.withLock { v } }
            set { lock.withLock { v = newValue } }
        }
        /// True the first time only.
        func first() -> Bool where T == Bool { lock.withLock { defer { v = true }; return !v } }
    }
}

/// What a sound sandbox's VM gets for its microphone at a boot — pure, so the rules are unit tests.
public enum MicrophoneDecision: Equatable, Sendable {
    /// The Mac's microphone.
    case mac
    /// Silent, and why (said once per boot).
    case silent(String)

    public var isMac: Bool { self == .mac }

    /// `wanted`: the sandbox's sound includes the microphone (`sandbox.audio = on`). `permission`: macOS's answer
    /// (after doz asked, when it did). `app`: the app macOS asks about. `ask`: when doz asks (`sandbox.microphone_ask`).
    public static func decide(wanted: Bool, permission: MicrophonePermission, app: String?,
                              ask: MicrophoneAsk = .firstStart) -> MicrophoneDecision {
        guard wanted else { return .silent("this sandbox's sound is speakers only (sandbox.audio = speakers)") }
        let who = app ?? "the app that started doz"
        switch permission {
        case .allowed: return .mac
        case .denied: return .silent("the Mac's microphone is denied for \(who) — System Settings › Privacy & Security › Microphone, then Shut Down and Start the sandbox")
        case .restricted: return .silent("the Mac's microphone is restricted on this Mac (a device policy)")
        case .undecided where ask == .firstRecording:
            return .silent("macOS has not been asked about the microphone for \(who) yet — doz asks when a program here first records; that recording stays silent, and once you allow it, Shut Down and Start the sandbox to record from the Mac's microphone")
        case .undecided: return .silent("macOS has not answered about the microphone for \(who) — answer its question (or allow \(who) in System Settings › Privacy & Security › Microphone), then Shut Down and Start the sandbox")
        }
    }

    /// 667: what doz says when it asked at a sandbox's FIRST RECORDING and macOS answered (nil: no answer came). The
    /// recording that made doz ask keeps the silent microphone the sandbox started with (a VM's microphone is fixed
    /// for its run, and in its saved state).
    public static func answeredAtRecording(_ answer: MicrophonePermission?, sandbox: String, app: String?) -> String {
        let who = app ?? "the app that started doz"
        switch answer {
        case .allowed?:
            return "macOS now allows the microphone for \(who). \(sandbox) started with a silent microphone and keeps it while it runs (a sleep or a wake too), so this recording is silent — Shut Down and Start \(sandbox) to record from the Mac's microphone"
        case .denied?:
            return "macOS denied the microphone for \(who): \(sandbox) records silence — to change it, allow \(who) in System Settings › Privacy & Security › Microphone, then Shut Down and Start \(sandbox)"
        case .restricted?:
            return "the Mac's microphone is restricted on this Mac (a device policy): \(sandbox) records silence"
        case .undecided?, nil:
            return "macOS did not answer about the microphone for \(who): \(sandbox) records silence — answer its question (or allow \(who) in System Settings › Privacy & Security › Microphone), then Shut Down and Start \(sandbox)"
        }
    }
}
