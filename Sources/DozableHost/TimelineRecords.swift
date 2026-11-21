import Foundation

/// 747: a daemon event's line as the timeline keeps it (`metrics.sqlite` `host_events`): a step by its stable key
/// (`MetricsStepKey`), a phase by its name, a note or a line of the daemon's own with every path shown with `~` and every
/// host-like word (`example.com`, an address, `name:443`) replaced by "a host" — at most 200 characters. Never guest
/// text: progress, output, console lines, connections and session status are not kept.
public enum HostEventSummary {
    /// The kinds kept.
    public static let kept: Set<HostEvent.Kind> = [.phase, .step, .started, .failed, .note, .host]

    public static func make(_ e: HostEvent) -> String? {
        guard kept.contains(e.kind) else { return nil }
        let text = e.text ?? ""
        switch e.kind {
        case .step, .started, .failed: return TimelineText.line(MetricsStepKey.key(for: text))
        case .phase: return TimelineText.line(e.phase ?? text)
        default: return TimelineText.line(scrub(DisplayPath.tildeIn(text)))
        }
    }

    /// Every host-like word as "a host": a dotted name whose last label is letters (`example.com`, `api.example.net:443`),
    /// an IPv4 address (with or without a port), an IPv6 address in brackets.
    public static func scrub(_ s: String) -> String {
        var out = s
        let patterns = [
            #"\[[0-9A-Fa-f:]+\](:\d+)?"#,
            #"\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b"#,
            #"\b[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(:\d+)?\b"#,
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "a host", options: .regularExpression)
        }
        return out
    }
}
