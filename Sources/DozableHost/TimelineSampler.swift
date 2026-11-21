import Darwin
import Foundation

/// 747: CPU, memory and disk samples of each running sandbox, every `timeline.sample_seconds` (default 60; 0: off), read
/// from THIS Mac's side only — never a guest command. CPU: the VM helper's user + system time (`proc_pid_rusage`) over the
/// wall time since the last sample, over the sandbox's CPUs (0–100 %); memory: the helper's physical footprint, else the
/// spec less what the balloon returned; disk: what the sandbox's folder holds (`allocatedBytes`), every 5 minutes. The
/// helper (a `com.apple.Virtualization.VirtualMachine` process with the sandbox's root disk open) is found once per boot
/// off the daemon's actor and checked at each sample with `proc_pidpath`. A sample costs well under 2 ms per sandbox
/// (measured: `cost`; `make test-cli-timeline-vm` asserts it).
public final class ResourceSampler: @unchecked Sendable {
    public struct Target: Sendable {
        public var name: String
        public var cpus: Int
        public var memoryMiB: UInt64
        public var returnedMiB: UInt64
        public var directory: URL
        public var rootfs: URL
    }
    public struct Reading: Sendable, Equatable { public var cpuPercent: Double?; public var memoryBytes: Int64?; public var diskBytes: Int64? }
    /// What the samples cost (the helper's search apart): how many, the most and the mean, in microseconds.
    public struct Cost: Codable, Sendable, Equatable {
        public var samples = 0
        public var maxMicros = 0.0
        public var meanMicros = 0.0
        public var searches = 0
        public var maxSearchMicros = 0.0
    }

    struct Helper { var pid: pid_t; var lastCPU: UInt64?; var lastWall: UInt64? }
    private let lock = NSLock()
    private var helpers: [String: Helper] = [:]
    private var disk: [String: (bytes: Int64, at: Date)] = [:]
    private var _cost = Cost()
    public var cost: Cost { lock.lock(); defer { lock.unlock() }; return _cost }
    static let diskEvery: TimeInterval = 300
    static let helperSuffix = "com.apple.Virtualization.VirtualMachine"

    public init() {}

    /// Forget a sandbox's helper (it stopped, slept or its VM was replaced): the next sample looks again.
    public func forget(_ name: String) { lock.lock(); helpers[name] = nil; lock.unlock() }
    /// Keep only these sandboxes' state.
    public func retain(_ names: Set<String>) {
        lock.lock(); helpers = helpers.filter { names.contains($0.key) }; disk = disk.filter { names.contains($0.key) }; lock.unlock()
    }

    public func sample(_ t: Target, now: Date = Date()) -> Reading {
        lock.lock(); var h = helpers[t.name]; lock.unlock()
        if let p = h?.pid, !Self.isHelper(p) { h = nil }
        if h == nil {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let pid = Self.findHelper(rootfs: t.rootfs)
            let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
            lock.lock(); _cost.searches += 1; _cost.maxSearchMicros = max(_cost.maxSearchMicros, us); lock.unlock()
            h = pid.map { Helper(pid: $0) }
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var r = Reading()
        if var helper = h {
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(helper.pid, RUSAGE_INFO_V4, $0) }
            } == 0
            if ok {
                let cpu = Self.nanoseconds(ri.ri_user_time + ri.ri_system_time), wall = DispatchTime.now().uptimeNanoseconds
                if let lc = helper.lastCPU, let lw = helper.lastWall, wall > lw, cpu >= lc {
                    r.cpuPercent = min(100, max(0, Double(cpu - lc) / Double(wall - lw) / Double(max(1, t.cpus)) * 100))
                }
                helper.lastCPU = cpu; helper.lastWall = wall
                r.memoryBytes = Int64(ri.ri_phys_footprint)
            }
            lock.lock(); helpers[t.name] = ok ? helper : nil; lock.unlock()
        }
        if r.memoryBytes == nil {
            r.memoryBytes = Int64((t.memoryMiB - min(t.memoryMiB, t.returnedMiB)) * 1_048_576)
        }
        lock.lock(); let d = disk[t.name]; lock.unlock()
        if let d, now.timeIntervalSince(d.at) < Self.diskEvery {
            r.diskBytes = d.bytes
        } else {
            let b = allocatedBytes(t.directory)
            lock.lock(); disk[t.name] = (b, now); lock.unlock()
            r.diskBytes = b
        }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
        lock.lock()
        _cost.meanMicros = (_cost.meanMicros * Double(_cost.samples) + us) / Double(_cost.samples + 1)
        _cost.samples += 1
        _cost.maxMicros = max(_cost.maxMicros, us)
        lock.unlock()
        return r
    }

    /// Mach absolute time units as ns (Apple silicon's timebase is 125/3).
    static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static func nanoseconds(_ abs: UInt64) -> UInt64 { abs * UInt64(timebase.numer) / UInt64(max(1, timebase.denom)) }

    static func isHelper(_ p: pid_t) -> Bool {
        var b = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(p, &b, 4096) > 0 && String(cString: b).hasSuffix(helperSuffix)
    }

    /// The VM helper with exactly this root disk open (its path resolved: two stores may hold a sandbox of one name).
    static func findHelper(rootfs: URL) -> pid_t? {
        let want = WorkspaceStore.resolved(rootfs.path)
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(n) + 256)
        let m = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        for p in pids.prefix(max(m, 0)) where p > 0 && isHelper(p) {
            let size = proc_pidinfo(p, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
            let k = Int(proc_pidinfo(p, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))) / MemoryLayout<proc_fdinfo>.stride
            for fd in fds.prefix(max(k, 0)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vi = vnode_fdinfowithpath()
                let sz = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(p, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, sz) == sz else { continue }
                let path = withUnsafeBytes(of: &vi) { raw in
                    let off = MemoryLayout<vnode_fdinfowithpath>.size - 1024
                    return String(decoding: raw[off..<(off + 1024)].prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if path == want { return p }
            }
        }
        return nil
    }
}

extension HostCore {
    /// The sandboxes to sample now: running and not busy (a lifecycle step under way is left alone).
    func samplerTargets() async -> [ResourceSampler.Target] {
        var out: [ResourceSampler.Target] = []
        for m in managed.values {
            let st = await m.sandbox.status
            guard st.phase == .running, !st.busy else { continue }
            out.append(ResourceSampler.Target(name: m.name, cpus: m.sandbox.spec.cpus, memoryMiB: m.sandbox.spec.memoryMiB,
                                              returnedMiB: await m.sandbox.memoryReturnedMiB, directory: m.sandbox.layout.sandboxDirectory,
                                              rootfs: m.sandbox.layout.rootfs))
        }
        return out
    }

    /// The samples' loop (the daemon only): reads the setting each round; the sampling itself runs off the actor.
    nonisolated func runSampler() async {
        guard !readOnly else { return }
        while !Task.isCancelled {
            let every = DozableSettings.load().int(SettingKey.timelineSampleSeconds)
            guard every > 0 else { try? await Task.sleep(for: .seconds(60)); continue }
            try? await Task.sleep(for: .seconds(every))
            let targets = await samplerTargets()
            sampler.retain(Set(targets.map(\.name)))
            let now = TimelineClock.now()
            for t in targets {
                let r = sampler.sample(t, now: now)
                metrics?.sample(run: metricsRun, sandbox: t.name, minute: Int64(now.timeIntervalSince1970 / 60), cpuPercent: r.cpuPercent,
                                memoryBytes: r.memoryBytes, diskBytes: r.diskBytes)
            }
        }
    }
}

/// 747: the timeline's clock — the Mac's, or in a guarded run `DOZ_TEST_TIMELINE_NOW` (ms since 1970, or `+Nd`/`+Nh`
/// ahead of the real clock): how a test moves time to prune. An unguarded run never reads it.
public enum TimelineClock {
    public static func now(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Date {
        let real = Date()
        guard TestSafety.guarded(env), let v = env["DOZ_TEST_TIMELINE_NOW"], !v.isEmpty else { return real }
        if let ms = Double(v) { return Date(timeIntervalSince1970: ms / 1000) }
        if v.hasPrefix("+") || v.hasPrefix("-"), let last = v.last, let n = Double(v.dropFirst().dropLast()) {
            let unit: Double = last == "d" ? 86_400 : last == "h" ? 3600 : last == "m" ? 60 : 0
            guard unit > 0 else { return real }
            return real.addingTimeInterval((v.hasPrefix("-") ? -1 : 1) * n * unit)
        }
        return real
    }
    public static func nowMs(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Int64 {
        Int64((now(env).timeIntervalSince1970 * 1000).rounded())
    }
}
