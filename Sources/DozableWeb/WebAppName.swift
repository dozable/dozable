import Foundation
import DozableHost

// 714 (owner: "we need machine based names for the web app manifest so that i can install it per machine") — the
// installed dashboard is named for its Mac: "Dozable – john-mac-studio" (short name "Doz john"), and so is the page's <title>, so
// two Macs' dashboards installed on one computer are two apps that can be told apart. The Mac's name is its
// LocalHostName (System Settings › Sharing › Local hostname — `john-mac-studio`, the name `<mac>.local` and the LAN option already
// use): short, ASCII, already what a person sees for this Mac in Dozable. (`Host.current().localizedName` — "John's
// MacBook Pro" — is longer and carries the owner's name into every window title.) Only the names change: the
// manifest's `id` (`/?app=dozable`), `start_url` and `scope` stay as built — one origin is one app — and its headers
// (type, cache policy, the page CSP's `manifest-src 'self'`) are the static file's.

public enum WebAppName {
    /// The app's names for a Mac called `mac` (nil: the build's own "Dozable").
    public static func names(mac: String) -> (name: String, shortName: String) {
        ("Dozable – \(mac)", "Doz \(short(mac))")
    }

    /// The Mac's part of `short_name` (≤ 12 characters in all: "Doz " + 8): the whole name when it fits, else its first
    /// hyphen-separated word when that fits ("Johns-MacBook-Pro" → "Johns"), else its first 8 characters.
    public static func short(_ mac: String, limit: Int = 8) -> String {
        if mac.count <= limit { return mac }
        if let first = mac.split(separator: "-").first, !first.isEmpty, first.count <= limit { return String(first) }
        return String(mac.prefix(limit))
    }

    /// A name fit for a title and a manifest: 1–63 letters, digits, hyphens and spaces (a LocalHostName always is);
    /// anything else → nil (the build's own names stay).
    public static func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.count <= 63,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == " ") }) else { return nil }
        return s
    }

    /// This Mac's name: its LocalHostName (`scutil`, read-only). A guarded test run may name one with `DOZ_TEST_MAC_NAME`
    /// (and must, to get one: a test never reads the Mac's own).
    public static func current(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if TestSafety.guarded(env) { return clean(env["DOZ_TEST_MAC_NAME"]) }
        return clean(WebMacNames.current().localHostName)
    }
}

extension WebAssets {
    /// These assets with the app named for `mac`: the web app manifest re-written with `name`/`short_name` (served at a
    /// new content-hashed path, so a browser that cached another Mac name's copy fetches this one) and the page's <title>
    /// and manifest link re-written to match. nil or no manifest: unchanged.
    public func forMac(_ mac: String?) -> WebAssets {
        guard let mac = WebAppName.clean(mac),
              let m = assets.values.first(where: { $0.mimeType == "application/manifest+json" }),
              var json = (try? JSONSerialization.jsonObject(with: m.data)) as? [String: Any],
              let index = assets["/"] else { return self }
        let (name, short) = WebAppName.names(mac: mac)
        json["name"] = name
        json["short_name"] = short
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]) else { return self }
        let digest = Self.sha256Hex(data)
        let path = "/assets/app-\(digest.prefix(16)).webmanifest"
        var page = String(decoding: index.data, as: UTF8.self)
        let link = "href=\"\(m.publicPath)\""
        guard page.contains(link), page.contains("<title>Dozable</title>") else { return self }
        page = page.replacingOccurrences(of: link, with: "href=\"\(path)\"")
            .replacingOccurrences(of: "<title>Dozable</title>", with: "<title>\(name)</title>")
        let pageData = Data(page.utf8)
        var out = assets
        out[m.publicPath] = nil
        out[path] = WebAsset(publicPath: path, mimeType: m.mimeType, cachePolicy: m.cachePolicy, sha256: digest, data: data)
        out["/"] = WebAsset(publicPath: "/", mimeType: index.mimeType, cachePolicy: index.cachePolicy, sha256: Self.sha256Hex(pageData), data: pageData)
        // 745: the chat window's title names its Mac too ("Chat – NAME"); it links no manifest.
        if let c = assets[Self.chatDocument] {
            let text = String(decoding: c.data, as: UTF8.self)
            if text.contains("<title>Chat</title>") {
                let d = Data(text.replacingOccurrences(of: "<title>Chat</title>", with: "<title>Chat – \(mac)</title>").utf8)
                out[Self.chatDocument] = WebAsset(publicPath: Self.chatDocument, mimeType: c.mimeType, cachePolicy: c.cachePolicy, sha256: Self.sha256Hex(d), data: d)
            }
        }
        return WebAssets(assets: out)
    }
}
