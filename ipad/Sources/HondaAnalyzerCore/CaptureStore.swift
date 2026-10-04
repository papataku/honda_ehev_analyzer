#if canImport(SQLite3)
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), sqliteTransient)
        }
    }

    private func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func report(_ error: Error) {
        guard let onError else { return }
        DispatchQueue.main.async { onError(error) }
    }
}
#endif
