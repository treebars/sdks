import Foundation

enum TreebarsLogger {
    static var debug = false

    static func log(_ message: String, _ data: Any? = nil) {
        guard debug else { return }
        if let data {
            print("[Treebars] \(message): \(data)")
        } else {
            print("[Treebars] \(message)")
        }
    }

    /// Not gated on `debug`: for a setup step the integration skipped, which nobody turns debug on to find.
    static func warn(_ message: String) {
        print("[Treebars] \(message)")
    }
}
