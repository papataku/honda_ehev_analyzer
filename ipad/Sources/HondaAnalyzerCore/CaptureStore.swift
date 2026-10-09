#if canImport(SQLite3)
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public func captureTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

public enum CaptureStoreError: LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        switch self { case .sqlite(let message): return message }
    }
}

public final class CaptureStore: @unchecked Sendable {
    public let url: URL
    public var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "HondaAnalyzer.CaptureStore", qos: .userInitiated)
    private var db: OpaquePointer?

    private static let schema = """
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=FULL;
    CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY, started_utc TEXT NOT NULL, ended_utc TEXT, status TEXT NOT NULL, git_commit TEXT, tool_version TEXT, vehicle TEXT, notes TEXT);
    CREATE TABLE IF NOT EXISTS raw_capture(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, layer TEXT NOT NULL, source TEXT NOT NULL, payload BLOB NOT NULL, FOREIGN KEY(session_id) REFERENCES sessions(id));
    CREATE TABLE IF NOT EXISTS commands(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, command TEXT NOT NULL, raw_response BLOB, latency_ms REAL, success INTEGER);
    CREATE TABLE IF NOT EXISTS did_responses(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, ecu TEXT, response_can_id TEXT, did INTEGER NOT NULL, positive INTEGER NOT NULL, nrc INTEGER, payload BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, kind TEXT NOT NULL, note TEXT);
    CREATE TABLE IF NOT EXISTS devices(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, kind TEXT, identifier TEXT, metadata_json TEXT);
    CREATE TABLE IF NOT EXISTS ui_actions(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, action TEXT NOT NULL, detail TEXT);
    CREATE INDEX IF NOT EXISTS idx_raw_session_ts ON raw_capture(session_id,ts_utc);
    CREATE INDEX IF NOT EXISTS idx_did ON did_responses(session_id,did,ecu);
    CREATE INDEX IF NOT EXISTS idx_ui_actions_session_ts ON ui_actions(session_id,ts_utc);
    CREATE TABLE IF NOT EXISTS ecus(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ecu TEXT NOT NULL, request_can_id TEXT, response_can_id TEXT, first_seen_utc TEXT, UNIQUE(session_id,ecu,response_can_id));
    CREATE TABLE IF NOT EXISTS did_scan(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, status TEXT NOT NULL, latency_ms REAL, nrc INTEGER, payload BLOB, response_can_id TEXT, updated_utc TEXT NOT NULL, UNIQUE(session_id,ecu,did));
    CREATE INDEX IF NOT EXISTS idx_did_scan_resume ON did_scan(session_id,ecu,status,did);
    CREATE TABLE IF NOT EXISTS did_drive_plan(session_id INTEGER NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, discovered_session_id INTEGER, created_utc TEXT NOT NULL, PRIMARY KEY(session_id,ecu,did));
    CREATE TABLE IF NOT EXISTS did_drive_adaptive_state(
        session_id INTEGER NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL,
        priority TEXT NOT NULL, last_payload BLOB, unchanged INTEGER NOT NULL,
        contexts TEXT NOT NULL, updated_utc TEXT NOT NULL,
        PRIMARY KEY(session_id,ecu,did)
    );
    CREATE TABLE IF NOT EXISTS did_drive_samples(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, response_can_id TEXT, payload BLOB NOT NULL, latency_ms REAL, success INTEGER NOT NULL DEFAULT 1, partial INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS idx_did_drive_samples ON did_drive_samples(session_id,ecu,did,ts_utc);
    """

    public init(url: URL) throws {
        self.url = url
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw CaptureStoreError.sqlite("Unable to open SQLite capture database")
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 2_000)
        try execute(Self.schema)
    }

    deinit { if let db { sqlite3_close(db) } }

    public func createSession(
        gitCommit: String? = nil,
        toolVersion: String = "ipad-native",
        vehicle: String = "Honda STEP WGN RP8 e:HEV"
    ) throws -> Int64 {
        try queue.sync {
            let statement = try prepare("INSERT INTO sessions(started_utc,status,git_commit,tool_version,vehicle) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            bindText(statement, 1, timestamp(Date()))
            bindText(statement, 2, "OPEN")
            bindText(statement, 3, gitCommit)
            bindText(statement, 4, toolVersion)
            bindText(statement, 5, vehicle)
            try stepDone(statement)
            guard let db else { throw CaptureStoreError.sqlite("SQLite database is closed") }
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func appendRaw(sessionID: Int64, at date: Date, layer: String, source: String, payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let s = try self.prepare("INSERT INTO raw_capture(session_id,ts_utc,layer,source,payload) VALUES(?,?,?,?,?)")
                defer { sqlite3_finalize(s) }
                sqlite3_bind_int64(s, 1, sessionID)
                self.bindText(s, 2, self.timestamp(date))
                self.bindText(s, 3, layer)
                self.bindText(s, 4, source)
                self.bindBlob(s, 5, payload)
                try self.stepDone(s)
            } catch { self.report(error) }
        }
    }

    public func appendCommand(sessionID: Int64, at date: Date, result: ElmCommandResult) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let s = try self.prepare("INSERT INTO commands(session_id,ts_utc,command,raw_response,latency_ms,success) VALUES(?,?,?,?,?,?)")
                defer { sqlite3_finalize(s) }
                sqlite3_bind_int64(s, 1, sessionID)
                self.bindText(s, 2, self.timestamp(date))
                self.bindText(s, 3, result.command)
                self.bindBlob(s, 4, result.raw)
                sqlite3_bind_double(s, 5, result.latencyMs)
                sqlite3_bind_int(s, 6, result.success ? 1 : 0)
                try self.stepDone(s)
            } catch { self.report(error) }
        }
    }

    public func saveDevice(
        sessionID: Int64,
        kind: String,
        identifier: String,
        metadataJSON: String
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let s = try self.prepare(
                    "INSERT INTO devices(session_id,kind,identifier,metadata_json) VALUES(?,?,?,?)"
                )
                defer { sqlite3_finalize(s) }
                sqlite3_bind_int64(s, 1, sessionID)
                self.bindText(s, 2, kind)
                self.bindText(s, 3, identifier)
                self.bindText(s, 4, metadataJSON)
                try self.stepDone(s)
            } catch { self.report(error) }
        }
    }

    public func addEvent(sessionID: Int64, at date: Date, kind: String, note: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let s = try self.prepare("INSERT INTO events(session_id,ts_utc,kind,note) VALUES(?,?,?,?)")
                defer { sqlite3_finalize(s) }
                sqlite3_bind_int64(s, 1, sessionID)
                self.bindText(s, 2, self.timestamp(date))
                self.bindText(s, 3, kind)
                self.bindText(s, 4, note)
                try self.stepDone(s)
            } catch { self.report(error) }
        }
    }

    public func saveDidScan(sessionID: Int64, at date: Date, outcome: DidProbeOutcome) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let s = try self.prepare("""
                INSERT INTO did_scan(session_id,ecu,did,status,latency_ms,nrc,payload,response_can_id,updated_utc)
                VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(session_id,ecu,did) DO UPDATE SET
                    status=excluded.status,
                    latency_ms=excluded.latency_ms,
                    nrc=excluded.nrc,
                    payload=excluded.payload,
                    response_can_id=excluded.response_can_id,
                    updated_utc=excluded.updated_utc
                """)
                defer { sqlite3_finalize(s) }
                sqlite3_bind_int64(s, 1, sessionID)
                self.bindText(s, 2, outcome.ecu.uppercased())
                sqlite3_bind_int64(s, 3, Int64(outcome.did))
                self.bindText(s, 4, outcome.status.rawValue)
                if let latency = outcome.latencyMs { sqlite3_bind_double(s, 5, latency) }
                else { sqlite3_bind_null(s, 5) }
                if let nrc = outcome.nrc { sqlite3_bind_int(s, 6, Int32(nrc)) }
                else { sqlite3_bind_null(s, 6) }
                self.bindBlob(s, 7, outcome.payload)
                self.bindText(s, 8, outcome.responseCanID)
                self.bindText(s, 9, self.timestamp(date))
                try self.stepDone(s)
            } catch { self.report(error) }
        }
    }

    public func saveDrivePlan(sessionID: Int64, at date: Date, candidates: [DriveDID]) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                // Large historical Positive inventories must not generate
                // thousands of individual synchronous SQLite commits.
                try self.execute("BEGIN IMMEDIATE")
                do {
                    let s = try self.prepare("""
                        INSERT OR IGNORE INTO did_drive_plan(
                            session_id,ecu,did,discovered_session_id,created_utc
                        ) VALUES(?,?,?,NULL,?)
                    """)
                    defer { sqlite3_finalize(s) }
                    for candidate in candidates {
                        sqlite3_reset(s)
                        sqlite3_clear_bindings(s)
                        sqlite3_bind_int64(s, 1, sessionID)
                        self.bindText(s, 2, candidate.ecu)
                        sqlite3_bind_int64(s, 3, Int64(candidate.did))
                        self.bindText(s, 4, self.timestamp(date))
                        try self.stepDone(s)
                    }
                    try self.execute("COMMIT")
                } catch {
                    try? self.execute("ROLLBACK")
                    throw error
                }
            } catch { self.report(error) }
        }
    }

    /// One transactional snapshot per checkpoint/stop, not one disk commit per DID.
    public func saveDriveSamplingState(
        sessionID: Int64, at date: Date, seeds: [DriveSamplingSeed]
    ) {
        queue.async { [weak self] in
            guard let self, !seeds.isEmpty else { return }
            do {
                try self.execute("BEGIN IMMEDIATE")
                do {
                    let statement = try self.prepare("""
                        INSERT OR REPLACE INTO did_drive_adaptive_state(
                            session_id,ecu,did,priority,last_payload,unchanged,contexts,updated_utc
                        ) VALUES(?,?,?,?,?,?,?,?)
                    """)
                    defer { sqlite3_finalize(statement) }
                    let ts = self.timestamp(date)
                    for seed in seeds {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        sqlite3_bind_int64(statement, 1, sessionID)
                        self.bindText(statement, 2, seed.ecu)
                        sqlite3_bind_int64(statement, 3, Int64(seed.did))
                        self.bindText(statement, 4, seed.priority.rawValue)
                        if let bytes = seed.lastPayload {
                            self.bindBlob(statement, 5, bytes)
                        } else {
                            sqlite3_bind_null(statement, 5)
                        }
                        sqlite3_bind_int64(statement, 6, Int64(seed.unchanged))
                        self.bindText(statement, 7, seed.contexts.map(\.rawValue).joined(separator: ","))
                        self.bindText(statement, 8, ts)
                        try self.stepDone(statement)
                    }
                    try self.execute("COMMIT")
                } catch {
                    try? self.execute("ROLLBACK")
                    throw error
                }
            } catch { self.report(error) }
        }
    }

    public func saveDriveSample(sessionID: Int64, at date: Date, outcome: DidProbeOutcome) {
        guard outcome.status == .positive, outcome.payload.count >= 2 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let s = try self.prepare("""
                    INSERT INTO did_drive_samples(
                        session_id,ts_utc,ecu,did,response_can_id,payload,latency_ms,success,partial
                    ) VALUES(?,?,?,?,?,?,?,?,?)
                """)
                defer { sqlite3_finalize(s) }
                sqlite3_bind_int64(s, 1, sessionID)
                self.bindText(s, 2, self.timestamp(date))
                self.bindText(s, 3, outcome.ecu)
                sqlite3_bind_int64(s, 4, Int64(outcome.did))
                self.bindText(s, 5, outcome.responseCanID)
                self.bindBlob(s, 6, outcome.payload)
                if let ms = outcome.latencyMs { sqlite3_bind_double(s, 7, ms) }
                else { sqlite3_bind_null(s, 7) }
                sqlite3_bind_int(s, 8, 1)
                sqlite3_bind_int(s, 9, 0)
                try self.stepDone(s)
            } catch { self.report(error) }
        }
    }

    public func promoteLatestCommandSuccess(sessionID: Int64, command: String) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let s = try self.prepare("""
                UPDATE commands SET success=1
                WHERE id=(
                    SELECT id FROM commands
                    WHERE session_id=? AND REPLACE(UPPER(command),' ','')=REPLACE(UPPER(?),' ','')
                    ORDER BY id DESC LIMIT 1
                )
                """)
                defer { sqlite3_finalize(s) }
                sqlite3_bind_int64(s, 1, sessionID)
                self.bindText(s, 2, command)
                try self.stepDone(s)
            } catch { self.report(error) }
        }
    }

    public func completedDids(ecu: String, start: UInt16, end: UInt16) throws -> Set<UInt16> {
        try queue.sync {
            let s = try prepare("""
            SELECT DISTINCT did FROM did_scan
            WHERE ecu=? AND did BETWEEN ? AND ?
              AND (status IN ('positive','positive_partial') OR (status='nrc' AND nrc=49))
            """)
            defer { sqlite3_finalize(s) }
            bindText(s, 1, ecu.uppercased())
            sqlite3_bind_int64(s, 2, Int64(start))
            sqlite3_bind_int64(s, 3, Int64(end))
            var result = Set<UInt16>()
            while sqlite3_step(s) == SQLITE_ROW {
                let raw = sqlite3_column_int64(s, 0)
                if raw >= 0, raw <= 0xFFFF { result.insert(UInt16(raw)) }
            }
            return result
        }
    }

    public func positiveDidOutcomes(ecu: String? = nil) throws -> [DidProbeOutcome] {
        try queue.sync {
            let sql: String
            if ecu == nil {
                sql = """
                SELECT ecu,did,status,latency_ms,nrc,payload,response_can_id
                FROM did_scan WHERE status IN ('positive','positive_partial')
                ORDER BY ecu,did
                """
            } else {
                sql = """
                SELECT ecu,did,status,latency_ms,nrc,payload,response_can_id
                FROM did_scan WHERE ecu=? AND status IN ('positive','positive_partial')
                ORDER BY did
                """
            }
            let s = try prepare(sql)
            defer { sqlite3_finalize(s) }
            if let ecu { bindText(s, 1, ecu.uppercased()) }
            var rows: [DidProbeOutcome] = []
            while sqlite3_step(s) == SQLITE_ROW {
                guard let ecuPtr = sqlite3_column_text(s, 0),
                      let statusPtr = sqlite3_column_text(s, 2),
                      let status = DidProbeStatus(rawValue: String(cString: statusPtr)) else { continue }
                let rawDid = sqlite3_column_int64(s, 1)
                guard rawDid >= 0, rawDid <= 0xFFFF else { continue }

                let latency: Double? = sqlite3_column_type(s, 3) == SQLITE_NULL
                    ? nil : sqlite3_column_double(s, 3)
                let nrc: UInt8? = sqlite3_column_type(s, 4) == SQLITE_NULL
                    ? nil : UInt8(clamping: Int(sqlite3_column_int(s, 4)))

                let count = Int(sqlite3_column_bytes(s, 5))
                let payload: Data
                if count > 0, let ptr = sqlite3_column_blob(s, 5) {
                    payload = Data(bytes: ptr, count: count)
                } else {
                    payload = Data()
                }

                let responseID = sqlite3_column_text(s, 6).map { String(cString: $0) }
                rows.append(DidProbeOutcome(
                    ecu: String(cString: ecuPtr),
                    did: UInt16(rawDid),
                    status: status,
                    latencyMs: latency,
                    nrc: nrc,
                    payload: payload,
                    responseCanID: responseID
                ))
            }
            return rows
        }
    }

    public func closeSession(_ sessionID: Int64, status: String = "CLOSED") throws {
        try queue.sync {
            let s = try prepare("UPDATE sessions SET ended_utc=?,status=? WHERE id=?")
            defer { sqlite3_finalize(s) }
            bindText(s, 1, timestamp(Date()))
            bindText(s, 2, status)
            sqlite3_bind_int64(s, 3, sessionID)
            try stepDone(s)
        }
    }

    public func flush() { queue.sync {} }

    private func execute(_ sql: String) throws {
        guard let db else { throw CaptureStoreError.sqlite("SQLite database is closed") }
        var message: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        if rc != SQLITE_OK {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let message { sqlite3_free(message) }
            throw CaptureStoreError.sqlite(detail)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw CaptureStoreError.sqlite("SQLite database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CaptureStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            guard let db else { throw CaptureStoreError.sqlite("SQLite database is closed") }
            throw CaptureStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), sqliteTransient)
        }
    }

    private func timestamp(_ date: Date) -> String { captureTimestamp(date) }

    private func report(_ error: Error) {
        guard let onError else { return }
        DispatchQueue.main.async { onError(error) }
    }
}
#endif
