import Foundation
import Security

/// Every on-disk location the app and the hook agree on.
public struct AppPaths: Sendable {
    public static let bundleID = "com.notchcompanion.app"

    public let support: URL

    public init(support: URL? = nil) {
        self.support = support ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchCompanion", isDirectory: true)
    }

    public static let `default` = AppPaths(support: ProcessInfo.processInfo.environment["NOTCH_SUPPORT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) })

    public var runDirectory: URL { support.appendingPathComponent("run", isDirectory: true) }
    public var spoolDirectory: URL { support.appendingPathComponent("spool", isDirectory: true) }
    public var binDirectory: URL { support.appendingPathComponent("bin", isDirectory: true) }
    public var tokenFile: URL { support.appendingPathComponent("token") }
    public var historyDatabase: URL { support.appendingPathComponent("history.sqlite") }
    public var launchMarker: URL { runDirectory.appendingPathComponent("last-launch") }
    public var installedHook: URL { binDirectory.appendingPathComponent("notch-hook") }

    /// Unix socket paths are capped at 104 bytes; fall back to /tmp when the
    /// home path is too long.
    public var socket: URL {
        let preferred = runDirectory.appendingPathComponent("events.sock")
        if preferred.path.utf8.count < 100 { return preferred }
        return URL(fileURLWithPath: "/tmp/notch-companion-\(getuid())/events.sock")
    }

    /// Creates the private directories (0700). Safe to call repeatedly.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [support, runDirectory, spoolDirectory, binDirectory, socket.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// The per-install shared secret every event must carry. Created by the
    /// app with mode 0600; the hook only reads it.
    public func loadOrCreateToken() throws -> String {
        if let existing = readToken() { return existing }
        try prepare()
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }

    public func readToken() -> String? {
        guard let data = FileManager.default.contents(atPath: tokenFile.path) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count == 64 ? token : nil
    }
}
