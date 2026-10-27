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
    /// 667: `sandbox.microphone_ask` — with `first_recording` (the default) a cold boot never asks: the host asks when a
    /// program in the sandbox first records (`watchForRecording`).
    func settleMicrophone(_ m: Managed, ask: Bool, emit: @escaping @Sendable (HostEvent) -> Void = { _ in }) async {
        guard m.config.spec.audio == true, !readOnly else { return }
        let mode = soundMode(m)
        let app = Self.microphoneApp?.name
        let when = microphoneAsk()
        var permission = microphoneAccess.status()
        if ask, when == .firstStart, mode.wantsMicrophone, permission == .undecided {
            let wait = microphoneQuestionWait.components.seconds
            let text = "asking macOS about the microphone for \(app ?? "the app that started doz") (\(m.name) has sound with the microphone) — "
                + "answer its question; \(m.name) starts when you do, or in \(wait) s with a silent microphone"
            note(m.name, text)
            emit(HostEvent(kind: .note, sandbox: m.name, text: text))
            permission = await microphoneAccess.request(microphoneQuestionWait) ?? microphoneAccess.status()
            note(m.name, "macOS's answer about the microphone: \(permission.rawValue)")
        }
        let decision = MicrophoneDecision.decide(wanted: mode.wantsMicrophone, permission: permission, app: app, ask: when)
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
            "macOS allows it now, but this sandbox started with a silent microphone and keeps it while it runs — Shut Down and Start it to record from the Mac's"
        case (.mac?, _): "mac"
        case (.silent(let why)?, _): why
        case (nil, _): nil
        }
    }

    /// 667: `sandbox.microphone_ask`, read now.
    func microphoneAsk() -> MicrophoneAsk {
        MicrophoneAsk.of(DozableSettings.load().resolve(SettingKey.microphoneAsk).value)
    }

    /// 667: whether a RUNNING sound sandbox's first recording should make doz ask macOS — its sound includes the
    /// microphone, doz asks at a first recording, macOS has no answer, and its VM was not built with the Mac's
    /// microphone. Pure.
    nonisolated static func watchesForRecording(mode: SoundMode, ask: MicrophoneAsk, permission: MicrophonePermission,
                                                builtWithMac: Bool?) -> Bool {
        mode.wantsMicrophone && ask == .firstRecording && permission == .undecided && builtWithMac != true
    }

    /// 667: a sound sandbox came to run — watch for its first recording when that is when doz asks
    /// (`DozSound.recordingWatchScript`, one guest stream; ended by `stopRecordingWatch` before a pause, sleep,
    /// hibernate, stop or quit, and when the sandbox leaves running).
    func watchForRecording(_ name: String) async {
        guard !readOnly, let m = managed[name], m.config.spec.audio == true, m.recordingWatch == nil else { return }
        guard Self.watchesForRecording(mode: soundMode(m), ask: microphoneAsk(), permission: microphoneAccess.status(),
                                       builtWithMac: m.sandbox.microphoneBuilt) else { return }
        // The phase event may come a moment before the sandbox says it runs (as bindPorts).
        for _ in 0..<40 {
            if await effectivePhase(m) == .running { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard await effectivePhase(m) == .running, managed[name] === m, m.recordingWatch == nil else { return }
        let stream: GuestStream
        do { stream = try await m.sandbox.openGuestStream(["sh", "-c", DozSound.recordingWatchScript]) } catch {
            note(name, "could not watch for the first recording (doz asks macOS about the microphone then): \(error.localizedDescription)")
            return
        }
        guard m.recordingWatch == nil else { stream.finishInput(); return }
        m.recordingWatch = stream
        HostLog.line("\(name): watching for the first recording (sandbox.microphone_ask = first_recording; macOS has not been asked)")
        Task.detached { [weak self] in
            var tail = ""
            var recorded = false
            for await d in stream.output {
                tail = String((tail + String(decoding: d, as: UTF8.self)).suffix(64))
                if tail.contains(DozSound.recordingMarker) { recorded = true; break }
            }
            stream.finishInput()
            await self?.recordingWatchEnded(name, stream, recorded: recorded)
        }
    }

    /// End a sandbox's watch (its guest half ends when its stdin closes). The next run starts it again when it applies.
    func stopRecordingWatch(_ name: String) {
        guard let m = managed[name], let w = m.recordingWatch else { return }
        m.recordingWatch = nil
        w.finishInput()
    }

    private func recordingWatchEnded(_ name: String, _ stream: GuestStream, recorded: Bool) async {
        guard let m = managed[name], m.recordingWatch === stream else { return }     // stopped: nothing to do
        m.recordingWatch = nil
        guard recorded else { return }                                              // it ended with the VM
        await askAtFirstRecording(m)
    }

    /// 667: a program in `m` records and macOS has no answer: ask it now — once at a time for every sandbox — and say
    /// what happens next, in the sandbox's terminals (a notice to its viewers), on the dashboard and in host.log (a
    /// note), in `doz-sound` and on its Home (`microphoneNote`). The recording itself stays silent: the VM keeps the
    /// microphone it started with until it is shut down (measured: VZ refuses a restore with another source).
    func askAtFirstRecording(_ m: Managed) async {
        let app = Self.microphoneApp?.name
        let who = app ?? "the app that started doz"
        guard !microphoneAsking else { return }          // the open question's answer is said to every sandbox
        microphoneAsking = true
        defer { microphoneAsking = false }
        var now: MicrophonePermission? = microphoneAccess.status()
        if now == .undecided {
            say(m.name, "a program in \(m.name) is recording: asking macOS about the microphone for \(who) — answer its question. "
                + "This recording is silent (\(m.name) started with a silent microphone)")
            let answer = await microphoneAccess.request(microphoneQuestionWait)
            now = answer ?? { let s = microphoneAccess.status(); return s == .undecided ? nil : s }()
            HostLog.line("\(m.name): macOS's answer about the microphone (asked at the first recording): \(now?.rawValue ?? "none in \(microphoneQuestionWait.components.seconds) s")")
        }
        say(m.name, MicrophoneDecision.answeredAtRecording(now, sandbox: m.name, app: app))
        // What the next cold boot of each sandbox with the microphone gets — its Home and doz-sound say it.
        for other in managed.values where other.config.spec.audio == true && soundMode(other).wantsMicrophone {
            other.microphone = MicrophoneDecision.decide(wanted: true, permission: now ?? .undecided, app: app, ask: .firstRecording)
            applyToolInputs(other)
        }
    }

    /// A line for a person: host.log + the dashboard (a note) and the sandbox's terminals (a notice to its viewers).
    private func say(_ name: String, _ text: String) {
        note(name, text)
        _ = bridgeState.notifyViewers(name, BridgeNotice("microphone", text))
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
