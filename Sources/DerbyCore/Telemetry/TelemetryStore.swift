import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Filters for the request inspector.
public struct RequestQuery: Sendable {
    public var limit: Int = 200
    public var offset: Int = 0
    public var logicalModel: String?
    public var providerName: String?
    public var onlyFailures = false
    public var onlyFailovers = false
    public var since: Date?
    public var searchText: String?
    public init() {}
}

public enum UsageWindow: String, Sendable, CaseIterable, Identifiable {
    case today, week, month, all
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All time"
        }
    }
    public var since: Date? {
        let cal = Calendar.current
        switch self {
        case .today: return cal.startOfDay(for: Date())
        case .week: return cal.date(byAdding: .day, value: -7, to: Date())
        case .month: return cal.date(byAdding: .day, value: -30, to: Date())
        case .all: return nil
        }
    }
}

public struct UsageBucket: Sendable, Identifiable, Hashable {
    public var id: String { key }
    public init(key: String, requests: Int, successes: Int, inputTokens: Int, outputTokens: Int,
                cachedTokens: Int, reasoningTokens: Int, costUSD: Double, avgLatency: Double) {
        self.key = key; self.requests = requests; self.successes = successes
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens; self.reasoningTokens = reasoningTokens
        self.costUSD = costUSD; self.avgLatency = avgLatency
    }
    public var key: String
    public var requests: Int
    public var successes: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int
    public var reasoningTokens: Int
    public var costUSD: Double
    public var avgLatency: Double
    public var successRate: Double { requests == 0 ? 0 : Double(successes) / Double(requests) }
}

public struct UsageSummary: Sendable {
    public var totalRequests = 0
    public var successes = 0
    public var failures = 0
    public var failovers = 0
    public var retries = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cachedTokens = 0
    public var reasoningTokens = 0
    public var costUSD = 0.0
    public var avgLatency = 0.0
    public var avgTTFT: Double?
    public var byLogicalModel: [UsageBucket] = []
    public var byProvider: [UsageBucket] = []
    public var byPhysicalModel: [UsageBucket] = []
    public var byClient: [UsageBucket] = []
    public var daily: [UsageBucket] = []
    public init() {}
    public var successRate: Double { totalRequests == 0 ? 1 : Double(successes) / Double(totalRequests) }
}

/// SQLite-backed request history, usage rollups and structured logs.
///
/// All access is serialized through this actor, which keeps the hot request
/// path off the database: the executor hands finished records over and returns.
public actor TelemetryStore: TelemetrySink {
    private var db: OpaquePointer?
    private let path: String
    private var settings: LoggingSettings
    private var writesSinceVacuum = 0

    public init(path: String = AppPaths.databaseFile.path, settings: LoggingSettings = .default) {
        self.path = path
        self.settings = settings
    }

    public func open() throws {
        guard db == nil else { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw DerbyError(kind: .unknown, message: "Could not open the Derby database at \(path).")
        }
        db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA busy_timeout=3000;")
        exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    public func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    public func update(settings: LoggingSettings) { self.settings = settings }

    // MARK: - Schema

    private func migrate() throws {
        exec("""
        CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS requests (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            logical_model TEXT NOT NULL,
            requested_model TEXT NOT NULL,
            client_name TEXT NOT NULL,
            dialect TEXT NOT NULL,
            streaming INTEGER NOT NULL,
            succeeded INTEGER NOT NULL,
            final_provider TEXT,
            final_provider_id TEXT,
            final_model TEXT,
            total_seconds REAL NOT NULL,
            ttft_seconds REAL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cached_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0,
            retry_count INTEGER NOT NULL DEFAULT 0,
            failover_count INTEGER NOT NULL DEFAULT 0,
            http_status INTEGER NOT NULL DEFAULT 200,
            failure_kind TEXT,
            error_message TEXT,
            routing_strategy TEXT,
            routing_explanation TEXT,
            payload TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_requests_created ON requests(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_requests_logical ON requests(logical_model, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_requests_provider ON requests(final_provider, created_at DESC);
        CREATE TABLE IF NOT EXISTS logs (
            id TEXT PRIMARY KEY,
            at REAL NOT NULL,
            level TEXT NOT NULL,
            category TEXT NOT NULL,
            message TEXT NOT NULL,
            request_id TEXT,
            fields TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_logs_at ON logs(at DESC);
        """)
        exec("INSERT OR REPLACE INTO schema_meta(key, value) VALUES('version','1');")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            if let err { sqlite3_free(err) }
            return false
        }
        return true
    }

    // MARK: - TelemetrySink

    public func record(_ record: RequestRecord) async {
        guard db != nil else { return }
        guard settings.historyRetentionDays != 0 || settings.maxHistoryRows > 0 else { return }
        let payload = (try? JSONEncoder.derby.encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sql = """
        INSERT OR REPLACE INTO requests
        (id, created_at, logical_model, requested_model, client_name, dialect, streaming, succeeded,
         final_provider, final_provider_id, final_model, total_seconds, ttft_seconds,
         input_tokens, output_tokens, cached_tokens, reasoning_tokens, cost_usd,
         retry_count, failover_count, http_status, failure_kind, error_message,
         routing_strategy, routing_explanation, payload)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, record.id)
        sqlite3_bind_double(stmt, 2, record.createdAt.timeIntervalSince1970)
        bindText(stmt, 3, record.logicalModel)
        bindText(stmt, 4, record.requestedModel)
        bindText(stmt, 5, record.clientName)
        bindText(stmt, 6, record.dialect)
        sqlite3_bind_int(stmt, 7, record.streaming ? 1 : 0)
        sqlite3_bind_int(stmt, 8, record.succeeded ? 1 : 0)
        bindText(stmt, 9, record.finalProviderName)
        bindText(stmt, 10, record.finalProviderID?.uuidString)
        bindText(stmt, 11, record.finalModelID)
        sqlite3_bind_double(stmt, 12, record.totalSeconds)
        if let t = record.timeToFirstTokenSeconds { sqlite3_bind_double(stmt, 13, t) } else { sqlite3_bind_null(stmt, 13) }
        sqlite3_bind_int(stmt, 14, Int32(record.usage.inputTokens))
        sqlite3_bind_int(stmt, 15, Int32(record.usage.outputTokens))
        sqlite3_bind_int(stmt, 16, Int32(record.usage.cachedInputTokens))
        sqlite3_bind_int(stmt, 17, Int32(record.usage.reasoningTokens))
        sqlite3_bind_double(stmt, 18, record.costUSD)
        sqlite3_bind_int(stmt, 19, Int32(record.retryCount))
        sqlite3_bind_int(stmt, 20, Int32(record.failoverCount))
        sqlite3_bind_int(stmt, 21, Int32(record.httpStatus))
        bindText(stmt, 22, record.failureKind?.rawValue)
        bindText(stmt, 23, record.errorMessage)
        bindText(stmt, 24, record.routingStrategy)
        bindText(stmt, 25, record.routingExplanation)
        bindText(stmt, 26, payload)
        _ = sqlite3_step(stmt)

        writesSinceVacuum += 1
        if writesSinceVacuum >= 200 {
            writesSinceVacuum = 0
            pruneNow()
        }
    }

    public func log(_ entry: LogEntry) async {
        guard db != nil, entry.level >= settings.level else { return }
        let sql = "INSERT OR REPLACE INTO logs(id, at, level, category, message, request_id, fields) VALUES (?,?,?,?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, entry.id)
        sqlite3_bind_double(stmt, 2, entry.at.timeIntervalSince1970)
        bindText(stmt, 3, entry.level.rawValue)
        bindText(stmt, 4, entry.category)
        bindText(stmt, 5, entry.message)
        bindText(stmt, 6, entry.requestID)
        bindText(stmt, 7, (try? JSONSerialization.data(withJSONObject: entry.fields)).flatMap { String(data: $0, encoding: .utf8) })
        _ = sqlite3_step(stmt)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, index) }
    }

    // MARK: - Queries

    public func requests(_ query: RequestQuery) -> [RequestRecord] {
        guard db != nil else { return [] }
        var sql = "SELECT payload FROM requests WHERE 1=1"
        var binds: [(Int32) -> Void] = []
        var i: Int32 = 0
        func bindS(_ v: String) { i += 1; let idx = i; binds.append { _ in }; _ = idx }

        var params: [String] = []
        if let lm = query.logicalModel { sql += " AND logical_model = ?"; params.append(lm) }
        if let p = query.providerName { sql += " AND final_provider = ?"; params.append(p) }
        if query.onlyFailures { sql += " AND succeeded = 0" }
        if query.onlyFailovers { sql += " AND failover_count > 0" }
        var since: Double?
        if let s = query.since { sql += " AND created_at >= ?"; since = s.timeIntervalSince1970 }
        var search: String?
        if let t = query.searchText, !t.isEmpty {
            sql += " AND (id LIKE ? OR final_model LIKE ? OR error_message LIKE ? OR client_name LIKE ?)"
            search = "%\(t)%"
        }
        sql += " ORDER BY created_at DESC LIMIT ? OFFSET ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for p in params { bindText(stmt, idx, p); idx += 1 }
        if let since { sqlite3_bind_double(stmt, idx, since); idx += 1 }
        if let search { for _ in 0..<4 { bindText(stmt, idx, search); idx += 1 } }
        sqlite3_bind_int(stmt, idx, Int32(query.limit)); idx += 1
        sqlite3_bind_int(stmt, idx, Int32(query.offset))

        var out: [RequestRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let json = String(cString: c)
            if let d = json.data(using: .utf8), let r = try? JSONDecoder.derby.decode(RequestRecord.self, from: d) {
                out.append(r)
            }
        }
        _ = binds
        return out
    }

    public func request(id: String) -> RequestRecord? {
        var q = RequestQuery()
        q.limit = 1
        q.searchText = id
        return requests(q).first { $0.id == id }
    }

    public func usage(window: UsageWindow) -> UsageSummary {
        var summary = UsageSummary()
        guard db != nil else { return summary }
        let sinceClause = window.since != nil ? " WHERE created_at >= ?" : ""
        let since = window.since?.timeIntervalSince1970

        // Headline totals.
        let totalsSQL = """
        SELECT COUNT(*), SUM(succeeded), SUM(input_tokens), SUM(output_tokens), SUM(cached_tokens),
               SUM(reasoning_tokens), SUM(cost_usd), AVG(total_seconds), AVG(ttft_seconds),
               SUM(failover_count), SUM(retry_count)
        FROM requests\(sinceClause);
        """
        withStatement(totalsSQL, since: since) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return }
            summary.totalRequests = Int(sqlite3_column_int(stmt, 0))
            summary.successes = Int(sqlite3_column_int(stmt, 1))
            summary.failures = summary.totalRequests - summary.successes
            summary.inputTokens = Int(sqlite3_column_int64(stmt, 2))
            summary.outputTokens = Int(sqlite3_column_int64(stmt, 3))
            summary.cachedTokens = Int(sqlite3_column_int64(stmt, 4))
            summary.reasoningTokens = Int(sqlite3_column_int64(stmt, 5))
            summary.costUSD = sqlite3_column_double(stmt, 6)
            summary.avgLatency = sqlite3_column_double(stmt, 7)
            if sqlite3_column_type(stmt, 8) != SQLITE_NULL { summary.avgTTFT = sqlite3_column_double(stmt, 8) }
            summary.failovers = Int(sqlite3_column_int(stmt, 9))
            summary.retries = Int(sqlite3_column_int(stmt, 10))
        }

        summary.byLogicalModel = buckets(groupBy: "logical_model", since: since)
        summary.byProvider = buckets(groupBy: "COALESCE(final_provider, 'none')", since: since)
        summary.byPhysicalModel = buckets(groupBy: "COALESCE(final_model, 'none')", since: since)
        summary.byClient = buckets(groupBy: "client_name", since: since)
        summary.daily = buckets(groupBy: "date(created_at, 'unixepoch', 'localtime')", since: since, orderByKey: true)
        return summary
    }

    private func buckets(groupBy expr: String, since: Double?, orderByKey: Bool = false) -> [UsageBucket] {
        let sinceClause = since != nil ? " WHERE created_at >= ?" : ""
        let order = orderByKey ? "k ASC" : "COUNT(*) DESC"
        let sql = """
        SELECT \(expr) AS k, COUNT(*), SUM(succeeded), SUM(input_tokens), SUM(output_tokens),
               SUM(cached_tokens), SUM(reasoning_tokens), SUM(cost_usd), AVG(total_seconds)
        FROM requests\(sinceClause) GROUP BY k ORDER BY \(order) LIMIT 100;
        """
        var out: [UsageBucket] = []
        withStatement(sql, since: since) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "—"
                out.append(UsageBucket(key: key,
                                       requests: Int(sqlite3_column_int(stmt, 1)),
                                       successes: Int(sqlite3_column_int(stmt, 2)),
                                       inputTokens: Int(sqlite3_column_int64(stmt, 3)),
                                       outputTokens: Int(sqlite3_column_int64(stmt, 4)),
                                       cachedTokens: Int(sqlite3_column_int64(stmt, 5)),
                                       reasoningTokens: Int(sqlite3_column_int64(stmt, 6)),
                                       costUSD: sqlite3_column_double(stmt, 7),
                                       avgLatency: sqlite3_column_double(stmt, 8)))
            }
        }
        return out
    }

    private func withStatement(_ sql: String, since: Double?, _ body: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        if let since { sqlite3_bind_double(stmt, 1, since) }
        body(stmt)
    }

    public func logs(level: LogLevel = .debug, limit: Int = 500, search: String? = nil) -> [LogEntry] {
        guard db != nil else { return [] }
        let levels = LogLevel.allCases.filter { $0 >= level }.map { "'\($0.rawValue)'" }.joined(separator: ",")
        var sql = "SELECT id, at, level, category, message, request_id, fields FROM logs WHERE level IN (\(levels))"
        if search?.isEmpty == false { sql += " AND (message LIKE ? OR category LIKE ? OR request_id LIKE ?)" }
        sql += " ORDER BY at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        if let s = search, !s.isEmpty { for _ in 0..<3 { bindText(stmt, idx, "%\(s)%"); idx += 1 } }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var out: [LogEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let at = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let level = LogLevel(rawValue: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "info") ?? .info
            let category = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let message = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let reqID = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            var fields: [String: String] = [:]
            if let f = sqlite3_column_text(stmt, 6).map({ String(cString: $0) }),
               let d = f.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                fields = parsed
            }
            out.append(LogEntry(level: level, category: category, message: message,
                                requestID: reqID, fields: fields, at: at))
        }
        return out
    }

    // MARK: - Maintenance

    public func pruneNow() {
        guard db != nil else { return }
        if settings.historyRetentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(settings.historyRetentionDays) * 86400).timeIntervalSince1970
            exec("DELETE FROM requests WHERE created_at < \(cutoff);")
        }
        if settings.maxHistoryRows > 0 {
            exec("""
            DELETE FROM requests WHERE id NOT IN (
                SELECT id FROM requests ORDER BY created_at DESC LIMIT \(settings.maxHistoryRows)
            );
            """)
        }
        if settings.logRetentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(settings.logRetentionDays) * 86400).timeIntervalSince1970
            exec("DELETE FROM logs WHERE at < \(cutoff);")
        }
    }

    public func clearHistory() {
        exec("DELETE FROM requests;")
    }
    public func clearLogs() {
        exec("DELETE FROM logs;")
    }

    /// Total request count, used by the Overview tiles.
    public func requestCount(since: Date?) -> Int {
        var count = 0
        let sql = since != nil
            ? "SELECT COUNT(*) FROM requests WHERE created_at >= ?;"
            : "SELECT COUNT(*) FROM requests;"
        withStatement(sql, since: since?.timeIntervalSince1970) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { count = Int(sqlite3_column_int(stmt, 0)) }
        }
        return count
    }

    /// Everything needed for the diagnostics export.
    public func exportDiagnostics(limit: Int = 200) -> String {
        var q = RequestQuery()
        q.limit = limit
        let recent = requests(q)
        let recentLogs = logs(limit: 500)
        var out = "# Derby diagnostics\nGenerated: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        out += "## Recent requests (\(recent.count))\n"
        for r in recent {
            out += "- \(ISO8601DateFormatter().string(from: r.createdAt)) \(r.id) \(r.logicalModel) -> "
            out += "\(r.finalProviderName ?? "none")/\(r.finalModelID ?? "-") "
            out += r.succeeded ? "OK" : "FAIL(\(r.failureKind?.rawValue ?? "?"))"
            out += " \(r.totalSeconds.msString) \(r.usage.inputTokens)in/\(r.usage.outputTokens)out\n"
        }
        out += "\n## Logs (\(recentLogs.count))\n"
        for l in recentLogs { out += l.formatted + "\n" }
        return SecretRedactor.redact(out)
    }
}

extension JSONEncoder {
    static var derby: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}
extension JSONDecoder {
    static var derby: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
