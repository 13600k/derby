import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Where the handoff ledger keeps what must survive a restart.
public protocol HandoffLedgerStore: Sendable {
    /// Everything stored, in no particular order.
    func load() -> [HandoffLedger.Stored]
    func save(_ entry: HandoffLedger.Stored)
    func touch(_ keys: [String], at date: Date)
    func remove(_ keys: [String])
    func removeAll()
}

/// Keeps ledger entries in a table of Derby's database.
///
/// The ledger is an actor whose methods must not wait on disk, so writes are
/// queued and applied in the order they were made: an entry evicted just after
/// it was saved must not come back on the next launch.
public final class SQLiteHandoffLedgerStore: HandoffLedgerStore, @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "com.derby.handoff-ledger")
    private var db: OpaquePointer?

    public init(path: String) {
        self.path = path
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    public func load() -> [HandoffLedger.Stored] {
        queue.sync {
            guard let db = open() else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT last_used, payload FROM handoff_ledger;", -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(stmt) }
            var out: [HandoffLedger.Stored] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let text = sqlite3_column_text(stmt, 1),
                      var entry = try? JSONDecoder.derby.decode(HandoffLedger.Stored.self,
                                                                from: Data(String(cString: text).utf8)) else { continue }
                entry.lastUsedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                out.append(entry)
            }
            return out
        }
    }

    public func save(_ entry: HandoffLedger.Stored) {
        guard let data = try? JSONEncoder.derby.encode(entry), let payload = String(data: data, encoding: .utf8) else { return }
        queue.async { [self] in
            guard let db = open() else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO handoff_ledger (key, last_used, payload) VALUES (?, ?, ?);",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, entry.key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, entry.lastUsedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, payload, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    public func touch(_ keys: [String], at date: Date) {
        guard !keys.isEmpty else { return }
        queue.async { [self] in
            eachKey(keys, sql: "UPDATE handoff_ledger SET last_used = ?1 WHERE key = ?2;") { stmt in
                sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            }
        }
    }

    public func remove(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        queue.async { [self] in
            eachKey(keys, sql: "DELETE FROM handoff_ledger WHERE key = ?2;") { _ in }
        }
    }

    public func removeAll() {
        queue.async { [self] in
            guard let db = open() else { return }
            sqlite3_exec(db, "DELETE FROM handoff_ledger;", nil, nil, nil)
        }
    }

    /// Waits for queued writes to land. For tests; the request path never waits.
    public func flush() {
        queue.sync {}
    }

    // MARK: - Queue-only helpers

    private func open() -> OpaquePointer? {
        if let db { return db }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else { return nil }
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA busy_timeout=3000;", nil, nil, nil)
        sqlite3_exec(handle, """
        CREATE TABLE IF NOT EXISTS handoff_ledger (
            key TEXT PRIMARY KEY,
            last_used REAL NOT NULL,
            payload TEXT NOT NULL
        );
        """, nil, nil, nil)
        db = handle
        return handle
    }

    /// Runs `sql` once per key in one transaction, the key bound as `?2`.
    private func eachKey(_ keys: [String], sql: String, bind: (OpaquePointer?) -> Void) {
        guard let db = open() else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        for key in keys {
            bind(stmt)
            sqlite3_bind_text(stmt, 2, key, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }
}
