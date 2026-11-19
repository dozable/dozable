import Foundation

/// Whether one of your Macs' dashboards answers — asked only when a person asks (`doz ui macs add`, `doz ui macs check`),
/// never by the page, the daemon or a timer.
///
/// ONE request: `GET <origin>/` — with an ephemeral session (no cookie or credential storage, no URL cache, no proxy), no
/// redirect followed (a 308 is "answers, but redirected to https"), a 3 s deadline, a 64 KiB cap on the body, the
/// system's trust only. Nothing of this Mac's is sent: no cookie, no authorization, no referrer, no path but `/`. The body
/// is read only for its `<title>` and never logged. Reachable = 200 and the title `Dozable` or `Dozable – NAME` (the name
/// is kept as `reportedName`). `MacReachabilityTests` (local listeners on ports the system chooses).
public enum MacReachability {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        case reachable
        /// It answered, but not as a Dozable dashboard.
        case notDozable = "not-dozable"
        /// It answered with a redirect to https: add it with its https:// address.
        case redirected
        case refused, timeout, tls, dns
    }

    public struct Result: Equatable, Sendable {
        public var outcome: Outcome
        /// The name its dashboard gave itself (reachable only).
        public var reportedName: String?
        public init(_ outcome: Outcome, reportedName: String? = nil) { self.outcome = outcome; self.reportedName = reportedName }
    }

    public static let deadline: TimeInterval = 3
    public static let maximumBody = 64 << 10

    /// Check one origin. `deadline` is a test seam (the product uses 3 s).
    public static func check(_ o: MacOrigin, deadline: TimeInterval = Self.deadline) async -> Result {
        guard let url = URL(string: o.link) else { return Result(.dns) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = deadline
        config.timeoutIntervalForResource = deadline
        config.httpAdditionalHeaders = [:]
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: deadline)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        req.setValue("doz", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: req, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { return Result(.notDozable) }
            if (300...399).contains(http.statusCode) {
                let to = (http.value(forHTTPHeaderField: "Location") ?? "").lowercased()
                return Result(to.hasPrefix("https://") ? .redirected : .notDozable)
            }
            guard http.statusCode == 200 else { return Result(.notDozable) }
            var body = Data()
            body.reserveCapacity(4096)
            for try await b in bytes {
                body.append(b)
                if body.count >= maximumBody { break }
            }
            guard let t = title(body) else { return Result(.notDozable) }
            return Result(.reachable, reportedName: t.name)
        } catch {
            return Result(outcome(of: error))
        }
    }

    /// What a failed request means for a person.
    static func outcome(of error: Error) -> Outcome {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return .refused }
        switch e.code {
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dns
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired, NSURLErrorAppTransportSecurityRequiresSecureConnection: return .tls
        default: return .refused
        }
    }

    /// The page's title, when it is a Dozable dashboard's: `Dozable` (name nil) or `Dozable – NAME` / `Dozable - NAME`.
    public static func title(_ body: Data) -> (isDozable: Bool, name: String?)? {
        let text = String(decoding: body.prefix(maximumBody), as: UTF8.self)
        guard let open = text.range(of: "<title>", options: .caseInsensitive),
              let close = text.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) else { return nil }
        let t = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "Dozable" { return (true, nil) }
        for sep in ["Dozable – ", "Dozable - "] where t.hasPrefix(sep) {
            guard let n = cleanName(String(t.dropFirst(sep.count))) else { return nil }
            return (true, n)
        }
        return nil
    }

    /// A reported name as it may be kept and shown: letters, digits, `.`, `_`, `-`, 1–63 — anything else is not kept.
    public static func cleanName(_ s: String) -> String? {
        guard (1...63).contains(s.utf8.count),
              s.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F })
        else { return nil }
        return s
    }

    /// The outcome in a person's words.
    public static func words(_ o: Outcome) -> String {
        switch o {
        case .reachable: "answered"
        case .notDozable: "something answered, but not a Dozable dashboard"
        case .redirected: "it answers, redirected to https — add it with its https:// address"
        case .refused: "nothing answered (refused or unreachable)"
        case .timeout: "no answer within 3 seconds"
        case .tls: "its https certificate was not accepted"
        case .dns: "its name was not found"
        }
    }

    /// The task's own delegate: a redirect is never followed (the 3xx itself is the answer).
    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
