#if canImport(SQLite3)
import Foundation
import SQLite3

public struct DidScanHistory: Equatable, Sendable {
    public var completed: Set<UInt16>
    public var positiveHints: Set<UInt16>

    public init(completed: Set<UInt16> = [], positiveHints: Set<UInt16> = []) {
        self.completed = completed
        self.positiveHints = positiveHints
    }

    public mutating func merge(_ other: DidScanHistory) {
        completed.formUnion(other.completed)
        positiveHints.formUnion(other.positiveHints)
    }
}

public func loadDidScanHistory(
    from urls: [URL],
    ecu: String,
    start: UInt16,
    end: UInt16
) -> DidScanHistory {
    var combined = DidScanHistory()
    for url in urls {
        combined.merge(loadDidScanHistory(
            from: url,
            ecu: ecu,
            start: start,
            end: end
        ))
    }
    return combined
}

public func loadDidScanHistory(
    from url: URL,
    ecu: String,
    start: UInt16,
    end: UInt16
) -> DidScanHistory {
    guard start <= end else { return DidScanHistory() }

    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          let db else {
        if let db { sqlite3_close(db) }
        return DidScanHistory()
    }
    defer { sqlite3_close(db) }

    let existsSQL = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='did_scan' LIMIT 1"
    var existsStatement: OpaquePointer?
    guard sqlite3_prepare_v2(db, existsSQL, -1, &existsStatement, nil) == SQLITE_OK,
          let existsStatement else {
        return DidScanHistory()
    }
    defer { sqlite3_finalize(existsStatement) }
    guard sqlite3_step(existsStatement) == SQLITE_ROW else {
        return DidScanHistory()
    }

    let sql = """
    SELECT did,status,nrc FROM did_scan
    WHERE UPPER(ecu)=UPPER(?) AND did BETWEEN ? AND ?
    """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        return DidScanHistory()
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (ecu.uppercased() as NSString).utf8String, -1, nil)
    sqlite3_bind_int64(statement, 2, Int64(start))
    sqlite3_bind_int64(statement, 3, Int64(end))

    var history = DidScanHistory()
    while sqlite3_step(statement) == SQLITE_ROW {
        let rawDid = sqlite3_column_int64(statement, 0)
        guard rawDid >= 0, rawDid <= 0xFFFF,
              let statusPointer = sqlite3_column_text(statement, 1) else { continue }

        let did = UInt16(rawDid)
        let status = String(cString: statusPointer)
        let nrc: Int? = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int(statement, 2))

        if status == "positive" || status == "positive_partial" {
            history.completed.insert(did)
            history.positiveHints.insert(did)
        } else if status == "nrc", nrc == 0x31 {
            history.completed.insert(did)
        }
    }
    return history
}
#endif
