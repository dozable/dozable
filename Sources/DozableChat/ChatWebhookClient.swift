import Foundation

// The webhook client: one POST of a JSON body to the address a bot's webhook entry names, with the entry's
// Authorization value as it is. What it does not do, on purpose:
//   - connect anywhere else: no proxy (the system's settings are not read), no redirect followed (a 3xx is the answer,
//     and it is not 2xx), no cookies, no cache, no stored credentials;
//   - read the answer's body: the call ends at the status line and headers, so an answer of any size costs nothing;
//   - wait without end: every call has a deadline for the whole of it (30 s in the server);
//   - say where it went: what it reports is the status, or a short reason the address could not be reached — never
//     the address or the header, which can carry a secret.

/// One try's outcome.
public enum ChatWebhookTry: Sendable, Equatable {
    /// The webhook answered with this status, after ms milliseconds.
    case answered(status: Int, ms: Int)
    /// It could not be reached: a short reason with neither the address nor the header in it.
    case unreachable(String)
}

/// Sends one webhook call. The server's is `ChatURLSessionWebhook`; a test may pass its own.
public protocol ChatWebhookPoster: Sendable {
    func post(url: String, authorization: String, body: [UInt8], timeout: Double) async -> ChatWebhookTry
}

public struct ChatURLSessionWebhook: ChatWebhookPoster {
    public init() {}

    public func post(url: String, authorization: String, body: [UInt8], timeout: Double) async -> ChatWebhookTry {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), u.host != nil else {
            return .unreachable("the webhook address is not a URL")
        }
        guard scheme == "http" || scheme == "https" else { return .unreachable("unsupported protocol scheme \"\(scheme)\"") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = Data(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !authorization.isEmpty { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        req.httpShouldHandleCookies = false

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]          // no proxy: the address the entry names, and nothing else
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout     // the whole call, however the server trickles its answer
        cfg.waitsForConnectivity = false
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let one = OneCall()
        let session = URLSession(configuration: cfg, delegate: one, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let start = DispatchTime.now()
        return await withCheckedContinuation { (c: CheckedContinuation<ChatWebhookTry, Never>) in
            one.begin(c, start: start)
            session.dataTask(with: req).resume()
        }
    }
}

/// The delegate of one call: it refuses every redirect, takes the status from the head of the answer and cancels the
/// rest, and finishes exactly once.
private final class OneCall: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ChatWebhookTry, Never>?
    private var status: Int?
    private var start = DispatchTime.now()

    func begin(_ c: CheckedContinuation<ChatWebhookTry, Never>, start: DispatchTime) {
        lock.withLock { continuation = c; self.start = start }
    }

    private func finish(_ r: ChatWebhookTry) {
        let c: CheckedContinuation<ChatWebhookTry, Never>? = lock.withLock { defer { continuation = nil }; return continuation }
        c?.resume(returning: r)
    }

    private var ms: Int { Int((DispatchTime.now().uptimeNanoseconds - lock.withLock { start }.uptimeNanoseconds) / 1_000_000) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // never followed: the 3xx itself is the answer
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock { status = code }
        let elapsed = ms
        completionHandler(.cancel)   // the body is never read
        finish(.answered(status: code, ms: elapsed))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let code = lock.withLock({ status }) { finish(.answered(status: code, ms: ms)); return }
        finish(.unreachable(Self.reason(error)))
    }

    /// A short reason in the words of the reference server's client where there is one; never the address.
    static func reason(_ error: Error?) -> String {
        guard let e = error as? URLError else { return "no answer" }
        switch e.code {
        case .cannotConnectToHost: return "connection refused"
        case .timedOut: return "context deadline exceeded (Client.Timeout exceeded while awaiting headers)"
        case .cannotFindHost, .dnsLookupFailed: return "no such host"
        case .networkConnectionLost: return "EOF"
        case .notConnectedToInternet: return "network is unreachable"
        case .badServerResponse: return "malformed HTTP response"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return "a TLS error (\(e.code.rawValue))"
        case .cancelled: return "cancelled"
        default: return "network error \(e.code.rawValue)"
        }
    }
}
