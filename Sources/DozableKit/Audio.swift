import CryptoKit
import Foundation
import Virtualization

// Sound (604 experimental → 667): a sandbox with sound gets one virtio-snd device — the Mac's speakers out and, when
// the Mac's microphone is allowed, its microphone in. Chosen per sandbox at create (`SandboxSpec.audio`, the setting
// `sandbox.audio`); a sandbox without it is exactly what it was before (no device, the pinned kernel, the same keys).
// Workspace changes/604-*/604.01-SPIKE.md has the first evidence; changes/667-*/ the production measurements.

/// The sound kernel a sandbox with sound boots: kata 6.18.15-186 + `Guest/sound-kernel/sound.conf` (ALSA and
/// virtio-snd — nothing outside sound differs), built
/// reproducibly by `Guest/sound-kernel/build-in-guest.sh`. It is never downloaded: a release carries it
/// (`libexec/doz/kernels/`), the host copies it into the store's kernel cache after checking its sha256, and the VM
/// boots it from there. Image bakes and every image key keep the PINNED kernel (`KernelArtifact.recommended`) — only
/// the sound sandbox's own VM differs.
public enum SoundKernel {
    /// 667: a new name for the rebuilt kernel — a sandbox that slept under 604's file (`vmlinux-6.18.15-186-sound`)
    /// keeps finding it in the cache for its restore (`VMLayout.kernelForRestore`); nothing overwrites it.
    public static let fileName = "vmlinux-6.18.15-186-sound2"
    public static let sha256 = "8d71cc61a0e55103d942c1a4961a3e72cc1159b8f442e882a2b7a6c6455a8b93"
    public static let size: UInt64 = 16_284_160

    /// The file's sha256 is the pinned one (size first — a cheap refusal).
    public static func isVerified(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? NSNumber)?.uint64Value == size,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    /// Where a sound sandbox's VM reads it: `<kernel cache>/<fileName>`.
    public static func path(inCache directory: URL) -> URL { directory.appendingPathComponent(fileName) }

    /// Put a verified copy into `cache` from `source`; nothing when one is there.
    /// Returns the cached file. Throws when the source is missing or not the pinned file.
    @discardableResult
    public static func install(from source: URL, into cache: URL) throws -> URL {
        let target = path(inCache: cache)
        if isVerified(target) { return target }
        guard isVerified(source) else {
            throw SandboxError.invalidSpec("the sound kernel at \(source.path) is missing or not the pinned file (sha256 \(sha256.prefix(12)))")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let tmp = cache.appendingPathComponent(".\(fileName).\(getpid()).tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: source, to: tmp)
        _ = try? fm.removeItem(at: target)
        try fm.moveItem(at: tmp, to: target)
        return target
    }
}

/// The audio device a sound sandbox's VM gets: one virtio-snd device with an input stream and an output stream to the
/// Mac's default speakers. A VM input — `VMLayout` records it (`otherDevices["audio"]`), so a snapshot is restored only
/// into a VM that has it.
///
/// 667: the input stream is ALWAYS there (the guest sees the same card whatever the microphone), but its SOURCE is the
/// Mac's microphone only when `microphone` is true — the host passes true only when macOS has already allowed it.
/// Otherwise the stream has no source and the guest records silence. So Virtualization never opens the microphone
/// while macOS's question is unanswered: 604's "VM stops when paused with the question pending" and "a recording
/// opened before Allow stays stuck" cannot happen. The source is not in `VMLayout` (the guest sees the same card), but
/// it IS in VZ's saved state: a restore into a VM with another source fails ("the file format is not compatible with
/// this version of the OS" — measured both ways, probes/667-*/mic-source-restore.sh). So a restore keeps the source
/// the VM slept with (`PersistedSandbox.microphoneSource`); a new decision waits for a cold boot.
enum AudioDevice {
    static func add(to config: VZVirtualMachineConfiguration, microphone: Bool) {
        let snd = VZVirtioSoundDeviceConfiguration()
        let input = VZVirtioSoundDeviceInputStreamConfiguration()
        if microphone { input.source = VZHostAudioInputStreamSource() }
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        snd.streams = [input, output]
        config.audioDevices = [snd]
    }
}

// 667: 604's "an open stream stalls after hibernate/restore" no longer happens (measured three times: a playback and a
// capture stream held open across pause, sleep, hibernate and a restore into a new host process kept real time — the
// workspace probe probes/667-*/remeasure.sh). Nothing re-syncs streams at a wake; if it comes back, the remedy that was
// built and then dropped is in changes/667-*/667.01-PLAN-SOUND.md.
