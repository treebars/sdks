import Foundation

/// What a link host said about a link that opened the app: this tap's click id, and where the link
/// wanted the person to land — a path inside the app, or, for a link that only ever goes to a website,
/// that website.
struct ResolvedLink: Equatable {
    let clickId: String
    let deepLinkPath: String?
    /// Set only for a website-only link, and then `deepLinkPath` is nil: the person belongs in the browser.
    var webURL: URL? = nil
}

/**
 A Universal Link opened the app, holding only the link's own address.

 iOS decides that before the tap reaches the link host, so the app has neither a click id nor the
 link's deep-link path. Asking the address itself — with the `X-Treebars-Resolve` header — gets both
 back. Without it the app would open on its home screen and the visit could not be tied to the link
 that brought it. The same three pieces as Kotlin's `LinkResolve`.
 */
enum LinkResolve {
    /**
     The address worth asking about, or nil.

     An app is opened by its own website's addresses too, and a question sent to every one of them
     would be a request to somebody's web server per tap. Only https in a link's shape is asked
     (`isLinkPath`) — and the host decides the rest: an address it does not know answers with a
     redirect or a page, which is not the JSON `parse` reads. The whole address is asked, values and
     query included, because the host fills the link's deep-link path from them.

     **And only on one of `hosts`**, the link domains the app gave `initialize` as `linkHosts` — the ones
     it declares as associated domains. A link host that opens an app is always one of the project's own
     custom domains (the shared host serves no association file), so the app already knows the whole
     list; the same rule as Kotlin's, where another app's intent can carry any URL in.
     */
    static func candidate(_ url: URL?, hosts: Set<String>) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              hosts.contains(host)
        else { return nil }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return isLinkPath(path) ? url : nil
    }

    /**
     Whether a percent-encoded path is a link's: `/<key>`, then up to
     `TreebarsConstants.maxLinkPathValues` values — `/spring/u_123/p_9` is the link `spring` carrying two.
     A key is 1 to 64 letters, digits, `_` or `-`; a value is any segment of 1 to
     `TreebarsConstants.maxLinkValueLength` characters once decoded, so an encoded `/` stays inside the
     value it belongs to. One trailing slash is allowed. Both limits are the link host's own.

     `/p/<key>` is not a link's: it is a page-first link's address, which both association files
     exclude, so an app is never opened with one.
     */
    static func isLinkPath(_ path: String) -> Bool {
        var segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2, segments[0].isEmpty else { return false }
        segments.removeFirst()
        if segments.count > 1, segments.last?.isEmpty == true { segments.removeLast() }
        let key = segments.removeFirst()
        guard key != "p", key.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              segments.count <= TreebarsConstants.maxLinkPathValues
        else { return false }
        return segments.allSatisfy { segment in
            guard let value = segment.removingPercentEncoding else { return false }
            return !value.isEmpty && value.utf16.count <= TreebarsConstants.maxLinkValueLength
        }
    }

    /**
     The part of a path an event may carry: on a link host, `/spring` and never the values after it. A
     value is often a person's own id, and a link records one only where its author asked; the click id
     already names the link. A path on any other host comes back unchanged.
     */
    static func openedPath(_ path: String, host: String?, hosts: Set<String>) -> String {
        guard let host, hosts.contains(host.lowercased()) else { return path }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let key = segments.first else { return path }
        return key == "p" && segments.count > 1 ? "/p/\(segments[1])" : "/\(key)"
    }

    /// A host as `linkHosts` may give it — `open.example.com`, or pasted with its scheme or a path —
    /// reduced to the bare lowercase name `candidate` compares against.
    static func normalizeHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /**
     The link host's answer. The path is held to `isDeepLinkPath`, the rule every SDK applies to a
     deep-link path, a referrer's included: it is handed to the app to route on, and a value that is not a
     path inside the app — `https://…`, `//host/…` — would make a link an open redirect out of it. The click
     id stands without it; the tap was real.

     **A website-only link answers with `web_url` instead**, and then the app is handed no path at all: the
     operating system opened the app only because the app claims the link's domain, and the link's author
     said it goes to a website. The address is taken only when `webAddress` accepts it.
     */
    static func parse(_ data: Data, hosts: Set<String> = []) -> ResolvedLink? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clickId = object["click_id"] as? String, !clickId.isEmpty
        else { return nil }
        if let web = object["web_url"] as? String {
            return ResolvedLink(clickId: clickId, deepLinkPath: nil, webURL: webAddress(web, hosts: hosts))
        }
        let path = (object["deep_link_path"] as? String).flatMap { isDeepLinkPath($0) ? $0 : nil }
        return ResolvedLink(clickId: clickId, deepLinkPath: path)
    }

    /**
     A website the browser may be sent to, or nil: https only, with a host, and never one of `hosts`. The
     app's own link domains open the app, so sending the person to one would bring them straight back
     here; and anything but https — a scheme of another app, `javascript:` — is not a website.
     */
    static func webAddress(_ value: String, hosts: Set<String>) -> URL? {
        guard value.utf16.count <= 2048, let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty, !hosts.contains(normalizeHost(host))
        else { return nil }
        return url
    }

    /**
     Asks the link's address what it means. Nil on any refusal, redirect or failure.

     Redirects are NOT followed. A host that does not know the header redirects as it would for a
     browser, and following that would fetch a store page or the customer's website for nothing.
     */
    static func ask(_ url: URL, hosts: Set<String>, session: URLSession = LinkResolve.session) async -> ResolvedLink? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("ios", forHTTPHeaderField: TreebarsConstants.linkResolveHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parse(data, hosts: hosts)
        } catch {
            TreebarsLogger.log("link resolve failed for \(url.absoluteString): \(error)")
            return nil
        }
    }

    /// Somebody is looking at a launching app; a slow answer is worse than none.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        static let shared = NoRedirects()
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}
