import DozableKit
import Foundation

// 667: sound in the host — a sandbox's sound mode (`sandbox.audio`, per sandbox) and its microphone at each boot.

extension HostCore {
    /// A sandbox's sound now: off without the device, else speakers or on (its own value, else the setting's).
    func soundMode(_ m: Managed) -> SoundMode {
        SoundMode.of(hasDevice: m.config.spec.audio == true, value: Self.sandboxValue(m.config, SettingKey.audio))
    }

    /// Before a sound sandbox's VM is built (a cold boot, a wake, a restore after a crash): decide its microphone. The
    /// Mac's only when macOS has ALREADY allowed it — so Virtualization never opens the microphone while macOS's
    /// question is open (604: a recording stuck before Allow; a VM stopped by a pause with the question pending). When
    /// the sandbox wants the microphone and macOS has not answered, a COLD boot (`ask`) asks now and waits for the
    /// answer — at most `microphoneQuestionWait`, then the VM is built with a silent microphone (said; the next start
    /// asks again only if macOS still has no answer). The decision takes effect at a cold boot only: a restore keeps the
    /// source the VM slept with (`PersistedSandbox.microphoneSource` — VZ refuses another). Nothing without sound.
    func settleMicrophone(_ m: Managed, ask: Bool, emit: @escaping @Sendable (HostEvent) -> Void = { _ in }) async {
        guard m.config.spec.audio == true, !readOnly else { return }
        let mode = soundMode(m)
        let app = Self.microphoneApp?.name
        var permission = microphoneAccess.status()
        if ask, mode.wantsMicrophone, permission == .undecided {
            let wait = microphoneQuestionWait.components.seconds
            let text = "asking macOS about the microphone for \(app ?? "the app that started doz") (\(m.name) has sound with the microphone) — "
                + "answer its question; \(m.name) starts when you do, or in \(wait) s with a silent microphone"
            note(m.name, text)
            emit(HostEvent(kind: .note, sandbox: m.name, text: text))
            permission = await microphoneAccess.request(microphoneQuestionWait) ?? microphoneAccess.status()
            note(m.name, "macOS's answer about the microphone: \(permission.rawValue)")
        }
        let decision = MicrophoneDecision.decide(wanted: mode.wantsMicrophone, permission: permission, app: app)
        if mode.wantsMicrophone, decision != m.microphone {
            let text: String
            switch decision {
            case .mac: text = "the microphone: the Mac's (macOS allows it)"
            case .silent(let why): text = "the microphone is silent: \(why)"
            }
            note(m.name, text)
            emit(HostEvent(kind: .note, sandbox: m.name, text: text))
        }
        m.microphone = decision
        m.sandbox.setMicrophone(decision.isMac)
        applyToolInputs(m)          // doz-sound says why a recording is silent
    }

    /// The microphone's state for the tools layer and the Home: "mac", or why it is silent (nil before a boot decided
    /// it). A restore keeps the source the VM slept with (VZ refuses another), so "allowed now" is not yet "the Mac's".
    func microphoneNote(_ m: Managed) -> String? {
        switch (m.microphone, m.sandbox.microphoneBuilt) {
        case (.mac?, false?):
            "macOS allows it now, but this sandbox slept with a silent microphone — Shut Down and Start it to get the Mac's"
        case (.mac?, _): "mac"
        case (.silent(let why)?, _): why
        case (nil, _): nil
        }
    }

    /// 667: the sound a new sandbox gets — `--audio` (on) or `--sound MODE` (its own value), else the setting — written
    /// back into the options: `audio` (the device) and its own `sandbox.audio`. A build without the sound kernel (a
    /// public build) refuses a sandbox that asked for sound, and creates one that only follows the setting without it.
    func resolveSound(_ o: inout CreateOptions, name: String, emit: @escaping @Sendable (HostEvent) -> Void) throws {
        let flag: SoundMode? = o.audio == true ? .on : nil
        let own = o.settings?[SettingKey.audio]
        let mode = SoundMode.atCreate(flag: flag, own: own, setting: DozableSettings.load().resolve(SettingKey.audio).value)
        guard mode.hasDevice else {
            o.audio = nil
            if own != nil { o.settings?[SettingKey.audio] = nil }
            return
        }
        if buildFlavor.isPublic {
            if flag != nil || own != nil { throw HostError(.invalid, BuildFlavor.audioMissing) }   // 611
            emit(HostEvent(kind: .note, sandbox: name, text: "sandbox.audio is \(mode.rawValue), but this doz has no sound — created without sound"))
            o.audio = nil
            return
        }
        o.audio = true
        o.settings = (o.settings ?? [:]).merging([SettingKey.audio: .string(mode.rawValue)]) { _, n in n }
    }
}
