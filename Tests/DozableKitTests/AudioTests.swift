import Foundation
import Virtualization
import XCTest
@testable import DozableKit

/// 604 → 667 — sound: nothing changes for a sandbox without sound; a sound sandbox gets the device (recorded in its
/// layout), whose microphone is the Mac's only when the host says so, the tools layer's sound items, a verified sound
/// kernel.
final class AudioTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func spec() -> SandboxSpec {
        SandboxSpec(name: "a1", storeRoot: dir, cpus: 2, memoryMiB: 512, rootfsMiB: 1024, bakePackages: ["bash"])
    }

    func json<T: Encodable>(_ v: T) throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(v), as: UTF8.self)
    }

    func testASpecWithoutAudioEncodesExactlyAsBefore() throws {
        let s = spec()
        XCTAssertNil(s.audio)
        XCTAssertFalse(try json(s).contains("\"audio\":"), "no audio key for a sandbox without audio")
        // A spec written before (no key) decodes as no audio.
        let decoded = try JSONDecoder().decode(SandboxSpec.self, from: Data(try json(s).utf8))
        XCTAssertEqual(decoded, s)
        XCTAssertNil(decoded.audio)
        // The prepared disk's key never sees it.
        var a = s
        a.audio = true
        XCTAssertEqual(StoreLayout.goldenKey(for: a), StoreLayout.goldenKey(for: s))
        XCTAssertTrue(try json(a).contains("\"audio\":true"))
        XCTAssertEqual(try JSONDecoder().decode(SandboxSpec.self, from: Data(try json(a).utf8)).audio, true)
    }

    func testToolInputsWithoutAudioEncodeAsBeforeAndPlanNothingNew() throws {
        let plain = ToolInputs(github: true, ssh: false, tmux: true)
        XCTAssertEqual(try json(plain), #"{"github":true,"ssh":false,"tmux":true}"#)
        XCTAssertNil(ToolInputs(audio: false, audioApp: "Terminal").audioApp, "the app is kept only for audio")
        XCTAssertNil(ToolInputs(audio: false, microphone: "mac").microphone, "667: the microphone's state only for sound")
        let ids = ToolsLayer.plan(plain).items.map(\.id)
        XCTAssertFalse(ids.contains("alsa-utils") || ids.contains("asound-conf") || ids.contains("doz-sound"))
        let script = ToolsLayer.applyScript(ToolsLayer.plan(plain), state: .init(), ghCopied: false, ghProblem: nil)
        XCTAssertFalse(script.contains("doz-sound") || script.contains("asound"))
    }

    func testAnAudioSandboxGetsAlsaTheDefaultAndDozSound() throws {
        let inputs = ToolInputs(audio: true, audioApp: "Terminal", microphone: "macOS has not answered — allow Terminal")
        let plan = ToolsLayer.plan(inputs)
        XCTAssertEqual(plan.items.filter { $0.reason.contains("sound") }.map(\.id), ["alsa-utils", "asound-conf", "doz-sound"])
        XCTAssertEqual(plan.items.first { $0.id == "alsa-utils" }?.package, "alsa-utils")
        var state = ToolsLayer.GuestState()
        state.packageManager = "apk"
        let script = ToolsLayer.applyScript(plan, state: state, ghCopied: false, ghProblem: nil, audioApp: inputs.audioApp,
                                            microphone: inputs.microphone)
        XCTAssertTrue(script.contains("apk add --no-progress") && script.contains("alsa-utils"))
        XCTAssertTrue(script.contains(DozSound.asoundStamp) && script.contains("type asym") && !script.contains("dmix ipc_key"))
        XCTAssertTrue(script.contains("\"MAC_APP='Terminal'\" \"MIC='macOS has not answered — allow Terminal'\""), "two conf lines")
        XCTAssertTrue(script.contains(Data(DozSound.script.utf8).base64EncodedString()))
        XCTAssertEqual(DozSound.safeAppName("Evil'; rm -rf /"), "Evil rm -rf ")
        XCTAssertEqual(DozSound.safeAppName(nil), "the app that started doz")
        XCTAssertEqual(DozSound.safeMicrophone(nil), "mac")
        XCTAssertEqual(DozSound.safeMicrophone("x'; $(reboot) `id`"), "x’ (reboot) id", "no quote, $, ; or backtick survives")
        XCTAssertEqual(DozSound.safeMicrophone("the Mac's microphone — Privacy & Security › Microphone"),
                       "the Mac’s microphone — Privacy & Security › Microphone")
        // Both scripts parse as POSIX sh.
        for (name, text) in [("apply", script), ("doz-sound", DozSound.script)] {
            let f = dir.appendingPathComponent(name + ".sh")
            try text.write(to: f, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-n", f.path]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(name) does not parse")
        }
        XCTAssertTrue(DozSound.script.contains(DozSound.stamp) && DozSound.stamp.hasSuffix("v3"))
        XCTAssertTrue(DozSound.script.contains("timeout"), "a recording never hangs")
        XCTAssertTrue(DozSound.script.contains("microphone is silent: $MIC"), "667: it says why the microphone is silent")
        XCTAssertFalse(DozSound.script.contains("Shut Down"), "667: no more Shut Down advice — the host never lets VZ wait on macOS")
    }

    /// 667: the conf the tools layer writes is sourced by doz-sound — its two lines read back as the values.
    func testTheConfReadsBackInTheGuestShell() throws {
        let line = DozSound.installScript(app: "Terminal", microphone: "the microphone is denied for Terminal — System Settings › Privacy", say: { _, _, _ in "" })
        let conf = dir.appendingPathComponent("doz-sound.conf")
        let cmd = line.replacingOccurrences(of: DozSound.confPath, with: conf.path)
            .components(separatedBy: "; ").first!.replacingOccurrences(of: "mkdir -p /etc/doz && ", with: "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd + "; . '\(conf.path)'; printf '%s|%s' \"$MAC_APP\" \"$MIC\""]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       "Terminal|the microphone is denied for Terminal — System Settings › Privacy")
    }

    func testTheAudioDeviceIsInTheLayoutSoAMismatchedRestoreIsRefused() throws {
        func config(audio: Bool, microphone: Bool = false) -> VZVirtualMachineConfiguration {
            let c = VZVirtualMachineConfiguration()
            c.platform = VZGenericPlatformConfiguration()
            if audio { AudioDevice.add(to: c, microphone: microphone) }
            return c
        }
        let with = VMLayout.of(config(audio: true), kernelSHA256: "k")
        let without = VMLayout.of(config(audio: false), kernelSHA256: "k")
        XCTAssertEqual(with.otherDevices["audio"], 1)
        XCTAssertNil(without.otherDevices["audio"])
        XCTAssertFalse(with.differences(from: without).isEmpty)
        XCTAssertFalse(without.differences(from: with).isEmpty)
        let snd = try XCTUnwrap(config(audio: true).audioDevices.first as? VZVirtioSoundDeviceConfiguration)
        XCTAssertEqual(snd.streams.count, 2)
        XCTAssertTrue(snd.streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration })
        XCTAssertTrue(snd.streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration })
        // 667: the microphone is a SOURCE, not a device — the same layout either way (VZ's saved state does record it:
        // a restore keeps the source the VM slept with, `PersistedSandbox.microphoneSource`).
        // (Each config here has its own random machine identifier, so compare the devices.)
        let withMic = VMLayout.of(config(audio: true, microphone: true), kernelSHA256: "k")
        XCTAssertEqual(withMic.otherDevices, with.otherDevices)
        XCTAssertFalse(withMic.differences(from: with).contains { $0.hasPrefix("other devices") }, "\(withMic.differences(from: with))")
        func input(_ mic: Bool) throws -> VZVirtioSoundDeviceInputStreamConfiguration {
            let d = try XCTUnwrap(config(audio: true, microphone: mic).audioDevices.first as? VZVirtioSoundDeviceConfiguration)
            return try XCTUnwrap(d.streams.compactMap { $0 as? VZVirtioSoundDeviceInputStreamConfiguration }.first)
        }
        XCTAssertNil(try input(false).source, "no microphone unless the host says macOS allows it: the guest records silence")
        XCTAssertTrue(try input(true).source is VZHostAudioInputStreamSource)
    }

    /// 667: the microphone's source is recorded with the VM — an older record has none (and its sound VM had the Mac's).
    func testTheMicrophoneSourceIsPersistedWithTheVM() throws {
        var p = PersistedSandbox(spec: spec(), phase: .hibernated, machineIdentifier: Data([1, 2]), macAddress: nil, subnet: nil, shareTags: [:])
        XCTAssertNil(p.microphoneSource)
        XCTAssertFalse(try json(p).contains("microphoneSource"), "a record without sound encodes as before")
        p.microphoneSource = false
        XCTAssertEqual(try JSONDecoder().decode(PersistedSandbox.self, from: Data(try json(p).utf8)).microphoneSource, false)
    }

    func testTheSoundKernelIsVerifiedBeforeUse() throws {
        let fake = dir.appendingPathComponent("vmlinux-fake")
        try Data(repeating: 7, count: 4096).write(to: fake)
        XCTAssertFalse(SoundKernel.isVerified(fake))
        XCTAssertFalse(SoundKernel.isVerified(dir.appendingPathComponent("nothing")))
        let cache = dir.appendingPathComponent("kernels")
        XCTAssertThrowsError(try SoundKernel.install(from: fake, into: cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SoundKernel.path(inCache: cache).path), "nothing unverified is put in place")
        // 667: a new name — a sandbox that slept under 604's kernel still finds that file for its restore.
        XCTAssertEqual(SoundKernel.path(inCache: cache).lastPathComponent, "vmlinux-6.18.15-186-sound2")
        XCTAssertEqual(SoundKernel.sha256.count, 64)
        XCTAssertGreaterThan(SoundKernel.size, 16_000_000)
    }

    // MARK: 667 — the watch for the first recording

    /// A sound sandbox's container sees /proc/asound (its card's state — the watch reads it); every other mask stays.
    func testOnlyASoundSandboxSeesProcAsound() {
        let plain = Sandbox.maskedPaths(sound: false), sound = Sandbox.maskedPaths(sound: true)
        XCTAssertTrue(plain.contains("/proc/asound"), "the OCI default masks it")
        XCTAssertFalse(sound.contains("/proc/asound"))
        XCTAssertEqual(Set(plain).subtracting(sound), ["/proc/asound"], "nothing else is unmasked")
        XCTAssertEqual(Set(sound).subtracting(plain), [])
    }

    /// The guest half: POSIX sh, reads the capture substreams' state, falls back to an open capture device, and ends
    /// when its stdin closes (the host's stop) — never left behind.
    func testTheRecordingWatchIsPlainShAndEndsWithItsInput() throws {
        let s = DozSound.recordingWatchScript
        XCTAssertTrue(s.contains("/proc/asound/card*/pcm*c/sub*/status"))
        XCTAssertTrue(s.contains("\"state: RUNNING\""))
        XCTAssertTrue(s.contains(DozSound.recordingMarker))
        XCTAssertTrue(s.contains("/dev/snd/pcmC[0-9]*D[0-9]*c"), "the fallback for a container that masks /proc/asound")
        XCTAssertTrue(s.contains("cat > /dev/null") && s.contains("kill $!"), "ends when the host closes its input")
        XCTAssertFalse(s.contains("read -t") || s.contains("[[") || s.contains("inotify"), "POSIX sh and builtins (dash, busybox)")
        // Syntax, then: with its input closed it ends at once (here, on the Mac, there is no /proc: it records nothing).
        let syntax = Process()
        syntax.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntax.arguments = ["-n", "-c", s]
        try syntax.run(); syntax.waitUntilExit()
        XCTAssertEqual(syntax.terminationStatus, 0)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", s]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        let t0 = Date()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "stdin at its end: it ends")
        XCTAssertFalse(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(DozSound.recordingMarker))
    }
}
