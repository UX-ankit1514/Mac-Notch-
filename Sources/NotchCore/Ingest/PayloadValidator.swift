import Foundation

/// Gatekeeper for everything arriving over the socket or from the spool.
/// Payload text is data only: nothing in it is ever executed or used as a path.
public struct PayloadValidator: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case tooLarge
        case malformed
        case unsupportedVersion(Int)
        case badToken
        case invalidField(String)
        case stale
    }

    public static let maxBytes = 16 * 1024

    public let token: String

    public init(token: String) {
        self.token = token
    }

    public func validate(_ data: Data, now: Date = Date()) -> Result<AgentEvent, Rejection> {
        guard data.count <= Self.maxBytes else { return .failure(.tooLarge) }
        guard let envelope = try? EventEnvelope.decoder().decode(EventEnvelope.self, from: data) else {
            return .failure(.malformed)
        }
        guard envelope.v == EventEnvelope.currentVersion else {
            return .failure(.unsupportedVersion(envelope.v))
        }
        guard Self.constantTimeEquals(envelope.token, token) else { return .failure(.badToken) }

        let e = envelope.event
        if let problem = Self.fieldProblem(e) { return .failure(.invalidField(problem)) }
        // Hook events are delivered within seconds; spooled ones within a day.
        guard e.timestamp > now.addingTimeInterval(-24 * 3600),
              e.timestamp < now.addingTimeInterval(300) else { return .failure(.stale) }
        return .success(e)
    }

    static func fieldProblem(_ e: AgentEvent) -> String? {
        let sessionCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        if e.sessionID.isEmpty || e.sessionID.count > 128
            || !e.sessionID.unicodeScalars.allSatisfy(sessionCharacters.contains) { return "sessionID" }
        if !isClean(e.project, limit: 120) { return "project" }
        if !isClean(e.detail, limit: 80) { return "detail" }
        if !isClean(e.host.name, limit: 120) { return "host.name" }
        if !isClean(e.host.bundleID, limit: 200) { return "host.bundleID" }
        if let tty = e.host.tty, !(tty.hasPrefix("/dev/tty") && tty.count < 32) { return "host.tty" }
        if !isClean(e.cwd, limit: 1024) || e.cwd.map({ !$0.hasPrefix("/") }) == true { return "cwd" }
        if !isClean(e.connectorVersion, limit: 16) { return "connectorVersion" }
        if !(0...1).contains(e.confidence) { return "confidence" }
        if let pid = e.host.pid, pid <= 1 { return "host.pid" }
        if let pid = e.agentPID, pid <= 1 { return "agentPID" }
        return nil
    }

    /// Rejects control characters and invisible direction/format overrides
    /// that could disguise text.
    static func isClean(_ value: String?, limit: Int) -> Bool {
        guard let value else { return true }
        return value.count <= limit && !value.unicodeScalars.contains(where: Sanitize.isUnsafe)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Token bucket that bounds how many events per second are processed, so an
/// event burst can't stall the UI.
public struct RateLimiter: Sendable {
    public let capacity: Double
    public let refillPerSecond: Double
    private var tokens: Double
    private var last: Date

    public init(capacity: Double = 100, refillPerSecond: Double = 40, now: Date = Date()) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.last = now
    }

    public mutating func allow(now: Date = Date()) -> Bool {
        tokens = min(capacity, tokens + now.timeIntervalSince(last) * refillPerSecond)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// Events the hook couldn't deliver live are written here (0700 directory)
/// and replayed when the app starts.
public struct Spool: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func write(_ data: Data) throws {
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Reads and deletes every spooled payload, oldest first. Caps the count
    /// so a flooded spool can't block launch.
    public func drain(limit: Int = 500) -> [Data] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let sorted = files.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        var out: [Data] = []
        for file in sorted {
            defer { try? fm.removeItem(at: file) }
            guard out.count < limit,
                  let attrs = try? fm.attributesOfItem(atPath: file.path),
                  (attrs[.size] as? Int ?? .max) <= PayloadValidator.maxBytes,
                  let data = fm.contents(atPath: file.path) else { continue }
            out.append(data)
        }
        return out
    }
}
