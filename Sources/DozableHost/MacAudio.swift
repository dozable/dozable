import Darwin
import DozableKit
import Foundation

// Sound (604 → 667), the host's part: the sandbox's sound mode, where this doz's sound kernel is (a release carries it
// beside the executable; never downloaded), putting a verified copy into a store's kernel cache, and which Mac app
// macOS asks about the microphone for. macOS charges a VM's microphone to the host's RESPONSIBLE app — the app at
// the top of the chain that launched it (Terminal, iTerm, an IDE), not doz and not Virtualization (workspace
// changes/604-*/604.01-SPIKE.md, stage 1b). The microphone's permission: Microphone.swift.

/// 667: a sandbox's sound — the setting `sandbox.audio`, per sandbox.
public enum SoundMode: String, CaseIterable, Codable, Sendable {
    /// No sound device (every sandbox before 604, and the default).
    case off
    /// The Mac's speakers; the sandbox's microphone records silence and macOS is never asked.
    case speakers
    /// The Mac's speakers and microphone (once macOS has allowed it).
    case on

    /// It has the sound device (and boots the sound kernel) — decided when the sandbox is created.
    public var hasDevice: Bool { self != .off }
    /// It records from the Mac's microphone (when allowed).
    public var wantsMicrophone: Bool { self == .on }

    /// At create: `--audio` (on) or `--sound MODE`, else the sandbox's own value, else the setting.
    public static func atCreate(flag: SoundMode?, own: TOMLValue?, setting: TOMLValue) -> SoundMode {
        if let flag { return flag }
        if case .string(let s)? = own, let m = SoundMode(rawValue: s) { return m }
        if case .string(let s) = setting, let m = SoundMode(rawValue: s) { return m }
        return .off
    }

    /// A sandbox's now: off without the device; with it, its value — where `off` (a store's setting a sound sandbox
    /// follows) reads as speakers: the device stays, the microphone is not used.
    public static func of(hasDevice: Bool, value: TOMLValue) -> SoundMode {
        guard hasDevice else { return .off }
        if case .string(let s) = value, s == SoundMode.on.rawValue { return .on }
        return .speakers
    }

    /// Why a sandbox's own value cannot be `value` (nil: it can): the device is chosen at create.
    public static func changeProblem(hasDevice: Bool, to value: SoundMode, sandbox: String) -> String? {
        if hasDevice && value == .off {
            return "\(sandbox) was created with sound (a sound device and the sound kernel): speakers or on — to drop sound, create a new sandbox without it"
        }
        if !hasDevice && value != .off {
            return "sound is chosen when a sandbox is created (doz create --sound \(value.rawValue), New sandbox › Sound) — \(sandbox) has none"
        }
        return nil
    }
}

public enum MacAudio {
    /// The sound kernel this doz carries: `<dir of the resolved executable>/kernels/<file>` (the release tarball's
    /// libexec/doz/kernels/), or `DOZ_TEST_SOUND_KERNEL` (a test seam: a development build has none beside it).
    public static func bundledSoundKernel(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let p = env["DOZ_TEST_SOUND_KERNEL"], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        let exe = URL(fileURLWithPath: HostLauncher.executablePath).resolvingSymlinksInPath()
        let url = exe.deletingLastPathComponent().appendingPathComponent("kernels").appendingPathComponent(SoundKernel.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Put the verified sound kernel into `cache` (nothing when it is there). Throws a message for a person.
    @discardableResult
    public static func installSoundKernel(into cache: URL, environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let target = SoundKernel.path(inCache: cache)
        if SoundKernel.isVerified(target) { return target }
        guard let source = bundledSoundKernel(environment: env) else {
            throw HostError(.invalid, "sound needs the sound kernel, and this doz does not carry one (a release has libexec/doz/kernels/\(SoundKernel.fileName))")
        }
        do { return try SoundKernel.install(from: source, into: cache) } catch {
            throw HostError(.invalid, "sound: \(error.localizedDescription)")
        }
    }

    /// The Mac app macOS attributes `pid`'s microphone use to (its responsible process's .app), or nil.
    public struct ResponsibleApp: Codable, Equatable, Sendable {
        public var name: String
        public var bundleID: String?
        public var path: String
        public var pid: Int32
        public var description: String { bundleID.map { "\(name) (\($0))" } ?? name }
    }

    public static func responsibleApp(of pid: Int32 = getpid()) -> ResponsibleApp? {
        // libsystem's responsibility SPI (what TCC itself consults); looked up at run time — never linked against.
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        let rpid = unsafeBitCast(sym, to: Fn.self)(pid)
        guard rpid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(rpid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        // The OUTERMOST .app on the path (an IDE's helper apps sit inside its own bundle).
        var app: URL?
        var u = URL(fileURLWithPath: path)
        while u.path != "/" && !u.path.isEmpty {
            if u.pathExtension == "app" { app = u }
            u = u.deletingLastPathComponent()
        }
        guard let app else { return ResponsibleApp(name: URL(fileURLWithPath: path).lastPathComponent, bundleID: nil, path: path, pid: rpid) }
        let b = Bundle(url: app)
        let name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? app.deletingPathExtension().lastPathComponent
        return ResponsibleApp(name: name, bundleID: b?.bundleIdentifier, path: app.path, pid: rpid)
    }
}
