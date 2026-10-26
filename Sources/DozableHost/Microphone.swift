import AVFoundation
import Foundation

// 667: the Mac's microphone for sandboxes with sound — doz settles macOS's question ITSELF, before any VM records.
//
// What 604 measured: Virtualization asks macOS (TCC) the moment a guest opens a recording, on behalf of the host's
// RESPONSIBLE app (the app that started doz — Terminal, iTerm, an editor), and while that question is open (a) a
// recording opened before the answer stays stuck even after Allow, and (b) pausing or saving the VM stops it
// ("Internal Virtualization error"). So a sound sandbox's VM gets the real microphone ONLY when macOS has already said
// yes (`Sandbox.setMicrophone`, `AudioDevice`); otherwise its microphone is silent and Virtualization never asks.
// doz asks — once, when a sandbox whose sound includes the microphone starts and the answer is not yet given — and
// waits for the answer before that VM is built. The question names the same responsible app.
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

    /// A line for a person.
    public var sentence: String {
        switch self {
        case .allowed: "allowed"
        case .denied: "denied — System Settings › Privacy & Security › Microphone"
        case .undecided: "not asked yet — doz asks when a sandbox with sound and the microphone first starts"
        case .restricted: "restricted on this Mac (a device policy) — sandboxes record silence"
        }
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

    /// The test seam: never reaches macOS.
    public static func seam(_ env: [String: String]) -> MicrophoneAccess {
        let now = MicrophonePermission(rawValue: env["DOZ_TEST_MICROPHONE"] ?? "") ?? .undecided
        let answer = MicrophonePermission(rawValue: env["DOZ_TEST_MICROPHONE_ANSWER"] ?? "")
        return MicrophoneAccess(status: { now }, request: { _ in now == .undecided ? answer : now }, seamed: true)
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
                let box = AnswerBox()
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

    /// One answer only (the request's completion may outlive the wait).
    private final class AnswerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func first() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
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
    /// (after doz asked, when it did). `app`: the app macOS asks about.
    public static func decide(wanted: Bool, permission: MicrophonePermission, app: String?) -> MicrophoneDecision {
        guard wanted else { return .silent("this sandbox's sound is speakers only (sandbox.audio = speakers)") }
        let who = app ?? "the app that started doz"
        switch permission {
        case .allowed: return .mac
        case .denied: return .silent("the Mac's microphone is denied for \(who) — System Settings › Privacy & Security › Microphone, then Shut Down and Start the sandbox")
        case .restricted: return .silent("the Mac's microphone is restricted on this Mac (a device policy)")
        case .undecided: return .silent("macOS has not answered about the microphone for \(who) — answer its question (or allow \(who) in System Settings › Privacy & Security › Microphone), then Shut Down and Start the sandbox")
        }
    }
}
