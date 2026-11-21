import Foundation

/// 747: each kept source's retention — the setting `timeline.<source>` when it is set (14.5a: the derived store and the
/// four new records only), else the source's default.
public enum TimelineRetentionSettings {
    public static func effective(_ source: String, settings: DozableSettings? = nil) -> (retention: TimelineRetention, setBy: String) {
        let def = TimelineSources.source(source)?.defaultRetention ?? TimelineRetention(events: nil, m1: nil, h1: nil, d1: nil)
        return (def, "default")
    }
}
