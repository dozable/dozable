import Foundation

/// 747: each kept source's retention — one setting per source, `timeline.<source>` (`-` as `_`), `EVENTS/1M/1H/1D` in
/// days, `kept` for kept until deleted, e.g. `timeline.egress = 7/7/90/365`. 0 is refused (a part is at least a day). Set
/// in the file (or the environment) it is the user's; else the source's default. 14.5a: it bounds the history file and
/// the four records it added only (`host_events`, `egress`, `samples`, `key_use`) — never an older record or log.
public enum TimelineRetentionSettings {
    /// A source's setting: `timeline.<source>` with `-` as `_`.
    public static func key(_ source: String) -> String { "timeline." + source.replacingOccurrences(of: "-", with: "_") }

    static let maximumDays = 36_500

    public static func words(_ r: TimelineRetention) -> String {
        [r.events, r.m1, r.h1, r.d1].map { $0.map(String.init) ?? "kept" }.joined(separator: "/")
    }

    /// `30/30/365/kept` → a retention (nil: not one).
    public static func parse(_ s: String) -> TimelineRetention? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4 else { return nil }
        var days: [Int?] = []
        for p in parts {
            if p == "kept" { days.append(nil); continue }
            guard let d = Int(p), (1...maximumDays).contains(d) else { return nil }
            days.append(d)
        }
        return TimelineRetention(events: days[0], m1: days[1], h1: days[2], d1: days[3])
    }

    public static func problem(_ s: String) -> String? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return "four parts EVENTS/1M/1H/1D, like 30/30/365/kept" }
        if parts.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "0" }) { return "each part is at least 1 day, or kept (0 would keep nothing)" }
        return parse(s) == nil ? "each part is a number of days 1–\(maximumDays), or kept" : nil
    }

    /// The settings, one per kept source.
    static var definitions: [SettingDefinition] {
        TimelineSources.kept.map { s in
            let extra: String
            switch s.name {
            case "egress": extra = " Single connections name the hosts a sandbox reached; their counts per sandbox (never a host) are what the longer parts keep."
            case "runs": extra = " A run's frames are its record, kept as the run folder is."
            default: extra = ""
            }
            return SettingDefinition("timeline", s.name.replacingOccurrences(of: "-", with: "_"), .retention, .string(words(s.defaultRetention)),
                                     "Days the history keeps \(s.title.lowercased().replacingOccurrences(of: #" \(.*\)"#, with: "", options: .regularExpression)): single events, then counts by minute, hour and day (kept = until you delete it)." + extra,
                                     applies: .now)
        }
    }

    public static func effective(_ source: String, settings: DozableSettings? = nil) -> (retention: TimelineRetention, setBy: String) {
        let def = TimelineSources.source(source)?.defaultRetention ?? TimelineRetention(events: nil, m1: nil, h1: nil, d1: nil)
        // A source not kept here has no setting: its default is what the contract suggests.
        guard TimelineSources.source(source)?.status == "kept" else { return (def, "default") }
        let st = settings ?? DozableSettings.load()
        let r = st.resolve(key(source))
        guard case .string(let v) = r.value, let parsed = parse(v) else { return (def, "default") }
        switch r.source {
        case .mac, .env, .flag: return (parsed, "user")
        default: return (parsed, "default")
        }
    }

    /// Every kept source's, read once.
    public static func all(_ settings: DozableSettings = DozableSettings.load()) -> [String: (retention: TimelineRetention, setBy: String)] {
        var out: [String: (TimelineRetention, String)] = [:]
        for s in TimelineSources.kept { out[s.name] = effective(s.name, settings: settings) }
        return out
    }
}
