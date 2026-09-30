import Foundation

/// What a link host said about a link that opened the app: this tap's click id, and where the link
/// wanted the person to land.
struct ResolvedLink: Equatable {
    let clickId: String
    let deepLinkPath: String?
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
     would be a request to somebody's web server per tap. Only https with a single path segment is
     asked — `/<slug>`, what a link looks like; `/p/<slug>` never opens an app, because both association
     files exclude it — and the host decides the rest: an address it does not know answers with a
     redirect or a page, which is not the JSON `parse` reads.

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
        return path.range(of: "^/[A-Za-z0-9_-]{1,64}/?$", options: .regularExpression) != nil ? url : nil
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
     deep-link path, a referrer's included: it is handed to the app to route on, and a value that is not a path
     inside the app — `https://…`, `//host/…` — would make a link an open redirect out of it. The click
     id stands without it; the tap was real.
     */
    static func parse(_ data: Data) -> ResolvedLink? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clickId = object["click_id"] as? String, !clickId.isEmpty
        else { return nil }
        let path = (object["deep_link_path"] as? String).flatMap { isDeepLinkPath($0) ? $0 : nil }
        return ResolvedLink(clickId: clickId, deepLinkPath: path)
    }

    /**
     Asks the link's address what it means. Nil on any refusal, redirect or failure.

     Redirects are NOT followed. A host that does not know the header redirects as it would for a
     browser, and following that would fetch a store page or the customer's website for nothing.
     */
    static func ask(_ url: URL, session: URLSession = LinkResolve.session) async -> ResolvedLink? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("ios", forHTTPHeaderField: TreebarsConstants.linkResolveHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parse(data)
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
