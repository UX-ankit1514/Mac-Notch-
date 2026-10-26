import Foundation
import SQLite3

/// Local notification history (PRD FR-09). Stores event metadata only:
/// agent, project, type, time, status, and the navigation hints needed to
/// return to the source. Never prompts, commands or code.
public final class HistoryStore: @unchecked Sendable {
    public enum StoreError: Error { case open(String), sql(String) }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        db = handle
        chmod(url.path, 0o600)
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS notifications (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                agent TEXT NOT NULL,
                session TEXT NOT NULL,
                project TEXT,
                detail TEXT,
                host_bundle TEXT,
                host_name TEXT,
                host_pid INTEGER,
                host_tty TEXT,
                cwd TEXT,
                agent_pid INTEGER,
                priority INTEGER NOT NULL,
                status TEXT NOT NULL,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL,
                resolved_at REAL,
                dismissed INTEGER NOT NULL DEFAULT 0,
                muted INTEGER NOT NULL DEFAULT 0,
                connector_version TEXT,
                confidence REAL
            );
            CREATE INDEX IF NOT EXISTS notifications_last_seen ON notifications(last_seen);
            """)
    }

    deinit { sqlite3_close(db) }

    public func upsert(_ records: [NotificationRecord]) {
        guard !records.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let sql = """
            INSERT INTO notifications (id, type, agent, session, project, detail, host_bundle, host_name,
                host_pid, host_tty, cwd, agent_pid, priority, status, first_seen, last_seen, resolved_at,
                dismissed, muted, connector_version, confidence)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET type=excluded.type, detail=excluded.detail, status=excluded.status,
                last_seen=excluded.last_seen, resolved_at=excluded.resolved_at, dismissed=excluded.dismissed
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for r in records {
            let e = r.event
            sqlite3_reset(stmt)
            bind(stmt, 1, r.id.uuidString)
            bind(stmt, 2, e.type.rawValue)
            bind(stmt, 3, e.agent.rawValue)
            bind(stmt, 4, e.sessionID)
            bind(stmt, 5, e.project)
            bind(stmt, 6, e.detail)
            bind(stmt, 7, e.host.bundleID)
            bind(stmt, 8, e.host.name)
            bind(stmt, 9, e.host.pid.map(Int64.init))
            bind(stmt, 10, e.host.tty)
            bind(stmt, 11, e.cwd)
            bind(stmt, 12, e.agentPID.map(Int64.init))
            bind(stmt, 13, Int64(e.priority.rawValue))
            bind(stmt, 14, r.status.rawValue)
            bind(stmt, 15, r.firstSeen.timeIntervalSince1970)
            bind(stmt, 16, r.lastSeen.timeIntervalSince1970)
            bind(stmt, 17, r.resolvedAt?.timeIntervalSince1970)
            bind(stmt, 18, Int64(r.dismissed ? 1 : 0))
            bind(stmt, 19, Int64(r.muted ? 1 : 0))
            bind(stmt, 20, e.connectorVersion)
            bind(stmt, 21, e.confidence)
            sqlite3_step(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Newest first.
    public func recent(limit: Int = 200) -> [NotificationRecord] {
        query("SELECT * FROM notifications ORDER BY last_seen DESC LIMIT \(max(1, min(limit, 5000)))")
    }

    public func pending(newerThan cutoff: Date) -> [NotificationRecord] {
        query("SELECT * FROM notifications WHERE status = 'pending' AND last_seen > \(cutoff.timeIntervalSince1970) ORDER BY last_seen DESC")
    }

    /// Last event received from each agent, for the connector status screen.
    public func lastEvent(for agent: AgentKind) -> Date? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(last_seen) FROM notifications WHERE agent = ? AND connector_version != 'sim'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, agent.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    public func prune(olderThan cutoff: Date) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM notifications WHERE last_seen < \(cutoff.timeIntervalSince1970) AND status != 'pending'", nil, nil, nil)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM notifications; VACUUM;", nil, nil, nil)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM notifications", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: Internals

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    private func query(_ sql: String) -> [NotificationRecord] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [NotificationRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let record = row(stmt) { out.append(record) }
        }
        return out
    }

    private func row(_ stmt: OpaquePointer?) -> NotificationRecord? {
        func text(_ i: Int32) -> String? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
        }
        func int(_ i: Int32) -> Int64? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
        }
        func real(_ i: Int32) -> Double? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
        }
        guard let id = text(0).flatMap(UUID.init(uuidString:)),
              let type = text(1).flatMap(EventType.init(rawValue:)),
              let agent = text(2).flatMap(AgentKind.init(rawValue:)),
              let session = text(3),
              let priority = int(12).flatMap({ Priority(rawValue: Int($0)) }),
              let status = text(13).flatMap(EventStatus.init(rawValue:)),
              let first = real(14), let last = real(15) else { return nil }
        let host = HostInfo(bundleID: text(6), name: text(7), pid: int(8).map { Int32($0) }, tty: text(9))
        let event = AgentEvent(
            id: id, type: type, agent: agent, sessionID: session, host: host, project: text(4),
            cwd: text(10), agentPID: int(11).map { Int32($0) }, timestamp: Date(timeIntervalSince1970: first),
            priority: priority, status: status, connectorVersion: text(19) ?? "1",
            confidence: real(20) ?? 1, detail: text(5))
        var record = NotificationRecord(event: event, muted: int(18) == 1)
        record.status = status
        record.firstSeen = Date(timeIntervalSince1970: first)
        record.lastSeen = Date(timeIntervalSince1970: last)
        record.resolvedAt = real(16).map(Date.init(timeIntervalSince1970:))
        record.dismissed = int(17) == 1
        return record
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, i, value, -1, Self.transient) } else { sqlite3_bind_null(stmt, i) }
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ value: Int64?) {
        if let value { sqlite3_bind_int64(stmt, i, value) } else { sqlite3_bind_null(stmt, i) }
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, i, value) } else { sqlite3_bind_null(stmt, i) }
    }
}
