import Foundation
// SecRandomCopyBytes, for the secret.
import Security

/// The device's pseudonymous id and the secret that proves it — one pair, kept and lost together.
struct DeviceIdentity: Equatable {
    let id: String
    let secret: String

    /// A first-party random id — not `identifierForVendor` — and 32 bytes from the system CSPRNG, as hex.
    static func mint() -> DeviceIdentity {
        DeviceIdentity(id: "dev_\(UUID().uuidString)", secret: mintSecret())
    }

    static func mintSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // SecRandomCopyBytes only fails if the system entropy pool is unavailable, which on iOS
        // means something is very wrong; UUIDs are still random, just fewer bits.
        return status == errSecSuccess
            ? bytes.map { String(format: "%02x", $0) }.joined()
            : (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/**
 Where the pair lives: one file under Application Support, excluded from every backup — the twin of
 Kotlin's `DeviceIdentityStore` in `noBackupFilesDir`.

 Not `UserDefaults`, which iCloud and a computer back up and restore onto whatever phone the backup
 goes to: two handsets would then be one device, the restored one sending events as the original,
 reading its in-app messages and notification history with its secret, and registering its push token
 against it. A file marked `isExcludedFromBackup` is in neither kind of backup, and it goes when the app
 is deleted, so a reinstall is a new device — which the Keychain, surviving deletion, would not give.

 One file for both, so they are only ever kept or lost together. A phone restored from a backup starts
 as a new device, which is what it is.
 */
final class DeviceIdentityStore {
    enum Loaded: Equatable {
        case found(DeviceIdentity)
        case absent
        /// On file and not readable — before the first unlock since a restart, the one time the data
        /// protection key is not there. Not absent, and never to be minted over.
        case unreadable
    }

    static let fileName = "treebars_device_identity"

    let directory: URL
    private var file: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    /// Application Support: the app's own, never shown to the person, and deleted with the app.
    static func standard() -> DeviceIdentityStore? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return DeviceIdentityStore(directory: support.appendingPathComponent("treebars", isDirectory: true))
    }

    func load() -> Loaded {
        // Existence is metadata, readable while the device is locked; the contents are not.
        guard FileManager.default.fileExists(atPath: file.path) else { return .absent }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .unreadable }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return .absent }
        return .found(DeviceIdentity(id: lines[0], secret: lines[1]))
    }

    /// Written whole or not at all (`.atomic`), then marked out of backups — after the write, because
    /// an atomic write replaces the file and a mark on the old one would not carry over.
    @discardableResult
    func save(_ identity: DeviceIdentity) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\(identity.id)\n\(identity.secret)\n".utf8).write(to: file, options: [.atomic])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = file
            try marked.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    func erase() {
        try? FileManager.default.removeItem(at: file)
    }
}
