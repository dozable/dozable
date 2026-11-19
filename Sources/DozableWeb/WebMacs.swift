import DozableHost
import Foundation

/// Your Macs in the dashboard (the machine picker, This Mac › Your Macs): ONE typed read, `GET /api/v1/macs`, exactly the
/// read-only HostOp `doz ui macs ls` sends (`macs-ls`) — answered in-process when no daemon runs. Nothing here changes the
/// list (adding and removing are the CLI's) and nothing here calls another Mac: the page opens a plain link to an origin,
/// and that Mac's own sign-in applies. `WebMacsTests`.
public enum WebMacReads {
    /// The request the read route sends (nil: not this route).
    public static func request(for route: WebRoute) -> HostRequest? {
        route == .macs ? HostRequest(.macsList) : nil
    }

    /// This Mac's name as the page's title has it (the LocalHostName; a guarded run's `DOZ_TEST_MAC_NAME`) — read once.
    public static let thisMacName: String? = WebAppName.current()
}

/// The answer: this Mac (first in the picker), then the Macs kept in `<store>/macs.json`, field by field.
public struct WebMacList: Codable, Equatable, Sendable {
    public struct ThisMac: Codable, Equatable, Sendable {
        public var name: String?
    }
    public struct Mac: Codable, Equatable, Sendable {
        public var name: String
        /// `scheme://host[:port]` — the page's link is this and `/`, nothing else.
        public var origin: String
        public var host: String
        public var scheme: String
        public var lastSeenAt: Date?
        public var lastCheckAt: Date?
        public var lastResult: String?
        public var reportedName: String?
    }
    public var thisMac: ThisMac
    public var macs: [Mac]

    public init(_ l: MacListing, thisMac: String?) {
        self.thisMac = ThisMac(name: thisMac)
        macs = l.macs.map {
            Mac(name: $0.name, origin: $0.origin, host: $0.host, scheme: $0.scheme, lastSeenAt: $0.lastSeenAt, lastCheckAt: $0.lastCheckAt,
                lastResult: $0.lastResult, reportedName: $0.reportedName)
        }
    }
}
