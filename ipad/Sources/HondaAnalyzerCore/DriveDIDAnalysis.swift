#if canImport(SQLite3)
import Foundation
import SQLite3

/// Only already positively answered read-only UDS 0x22 identifiers may be sampled
/// during driving. Incomplete ISO-TP responses and ECU identity DIDs are excluded.
public struct DriveDID: Hashable, Sendable, Identifiable {
    public let ecu: String
    public let did: UInt16
    public let responseCanID: String?
    public let payloadLength: Int

    public var id: String { "\(ecu)-\(String(format: "%04X", did))" }
    public var label: String { "ECU \(ecu) / \(String(format: "%04X", did))" }
}

public func isDrivingSampleCandidate(did: UInt16, payloadLength: Int, status: String) -> Bool {
    status == "positive" &&
        payloadLength >= 2 && payloadLength <= 64 &&
        !(0xF100...0xF1FF).contains(Int(did))
}

public func loadDriveDIDCandidates(from urls: [URL], limit: Int? = nil) -> [DriveDID] {
    var found: [String: DriveDID] = [:]
    for url in urls {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            continue
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT UPPER(ecu), did, response_can_id, length(payload), status
            FROM did_scan WHERE status='positive' AND length(payload) BETWEEN 2 AND 64
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { continue }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let ecuPtr = sqlite3_column_text(statement, 0),
                  let statusPtr = sqlite3_column_text(statement, 4) else { continue }
            let ecu = String(cString: ecuPtr)
            let didValue = Int(sqlite3_column_int(statement, 1))
            guard (0...65535).contains(didValue),
                  normalizedEcuSource(ecu) != nil else { continue }
            let did = UInt16(didValue)
            let length = Int(sqlite3_column_int(statement, 3))
            let status = String(cString: statusPtr)
            guard isDrivingSampleCandidate(did: did, payloadLength: length, status: status) else { continue }
            let canID = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            // A DID must remain bound to its observed ECU. Response IDs must
            // match the validated tester-targeted physical response format.
            if let canID, canID.uppercased() != expectedResponseID(for: ecu) { continue }
            let item = DriveDID(ecu: ecu, did: did, responseCanID: canID, payloadLength: length)
            found[item.id] = item
        }
    }
    // Prefer previously explored 0x2xxx / 0xExxx fields to generic vendor data.
    let sorted = found.values.sorted {
        func priority(_ did: UInt16) -> Int {
            switch did {
            case 0x2000...0x2FFF: return 0
            case 0xE000...0xEFFF: return 1
            default: return 2
            }
        }
        let a = priority($0.did), b = priority($1.did)
        if a != b { return a < b }
        if $0.ecu != $1.ecu { return $0.ecu < $1.ecu }
        return $0.did < $1.did
    }
    guard let limit else { return sorted }
    return Array(sorted.prefix(max(0, limit)))
}

/// Fetch last saved adaptive priorities across the local capture library.
/// Old SQLite logs without the new table are skipped safely.
public func loadDriveSamplingSeeds(from urls: [URL]) -> [DriveSamplingSeed] {
    var found: [String: (String, DriveSamplingSeed)] = [:]
    for url in urls {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            continue
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT UPPER(ecu),did,priority,last_payload,unchanged,contexts,updated_utc
            FROM did_drive_adaptive_state ORDER BY updated_utc
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { continue }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ecuText = sqlite3_column_text(stmt, 0),
                  let priorityText = sqlite3_column_text(stmt, 2),
                  let updatedText = sqlite3_column_text(stmt, 6) else { continue }
            let ecu = String(cString: ecuText)
            let number = Int(sqlite3_column_int(stmt, 1))
            guard (0...65535).contains(number),
                  normalizedEcuSource(ecu) != nil,
                  let priority = DriveSamplingPriority(rawValue: String(cString: priorityText))
            else { continue }
            let did = UInt16(number)
            let bytes: Data?
            if sqlite3_column_type(stmt, 3) == SQLITE_NULL {
                bytes = nil
            } else if let blob = sqlite3_column_blob(stmt, 3) {
                bytes = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3)))
            } else {
                bytes = nil
            }
            let contextText = sqlite3_column_text(stmt, 5)
                .map { String(cString: $0) } ?? ""
            let contexts = contextText.split(separator: ",").compactMap {
                DriveOperatingContext(rawValue: String($0))
            }
            let seed = DriveSamplingSeed(
                ecu: ecu, did: did, priority: priority,
                lastPayload: bytes,
                unchanged: Int(sqlite3_column_int(stmt, 4)),
                contexts: contexts
            )
            let when = String(cString: updatedText)
            if let current = found[seed.id], current.0 > when { continue }
            found[seed.id] = (when, seed)
        }
    }
    return found.values.map { $0.1 }
}

public struct DriveFieldCandidate: Identifiable, Sendable {
    public let ecu: String
    public let did: UInt16
    public let field: String
    public let classification: String
    public let score: Double
    public let samples: Int
    public let speedCorrelation: Double?
    public let evSpeedCorrelation: Double?
    public let engineCorrelation: Double?
    public let hvPowerCorrelation: Double?
    public let minValue: Double
    public let maxValue: Double

    public var id: String { "\(ecu)-\(did)-\(field)" }
}

public struct DriveReference: Sendable {
    public let time: Double
    public let speed: Double?
    public let engineRPM: Double?
    public let hvPower: Double?
    public init(time: Double, speed: Double?, engineRPM: Double?, hvPower: Double?) {
        self.time = time; self.speed = speed
        self.engineRPM = engineRPM; self.hvPower = hvPower
    }
}

public struct DrivePayloadSample: Sendable {
    public let time: Double
    public let ecu: String
    public let did: UInt16
    public let payload: Data
    public init(time: Double, ecu: String, did: UInt16, payload: Data) {
        self.time = time; self.ecu = ecu; self.did = did; self.payload = payload
    }
}

private func drivePearson(_ pairs: [(Double, Double)]) -> Double? {
    guard pairs.count >= 6 else { return nil }
    let count = Double(pairs.count)
    let mx = pairs.reduce(0) { $0 + $1.0 } / count
    let my = pairs.reduce(0) { $0 + $1.1 } / count
    let vx = pairs.reduce(0) { $0 + pow($1.0 - mx, 2) }
    let vy = pairs.reduce(0) { $0 + pow($1.1 - my, 2) }
    guard vx > 0.000001, vy > 0.000001 else { return nil }
    let covariance = pairs.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    return covariance / sqrt(vx * vy)
}

public func rankDriveFields(
    samples: [DrivePayloadSample],
    references: [DriveReference],
    limit: Int = 40
) -> [DriveFieldCandidate] {
    let refs = references.sorted { $0.time < $1.time }
    let groups = Dictionary(grouping: samples, by: { "\($0.ecu.uppercased())-\($0.did)" })
    var results: [DriveFieldCandidate] = []

    func nearest(_ time: Double) -> DriveReference? {
        guard !refs.isEmpty else { return nil }
        var lo = 0, hi = refs.count
        while lo < hi {
            let m = (lo + hi) / 2
            if refs[m].time < time { lo = m + 1 } else { hi = m }
        }
        let candidates = [lo - 1, lo].filter { refs.indices.contains($0) }
        guard let index = candidates.min(by: {
            abs(refs[$0].time - time) < abs(refs[$1].time - time)
        }), abs(refs[index].time - time) <= 2.5 else { return nil }
        return refs[index]
    }

    for group in groups.values {
        guard group.count >= 8, let first = group.first else { continue }
        let rows = group.sorted { $0.time < $1.time }
        let length = min(32, rows.map { $0.payload.count }.min() ?? 0)
        guard length > 0 else { continue }
        var deduplicated = Set<[Int64]>()
        for width in [1, 2, 4] {
            guard width <= length else { continue }
            for offset in 0...(length - width) {
                for bigEndian in [true, false] where width > 1 || bigEndian {
                    for signed in [false, true] {
                        var values: [(Double, Double)] = []
                        for row in rows {
                            let bytes = row.payload[offset..<(offset + width)]
                            var raw: UInt64 = 0
                            for byte in bigEndian ? Array(bytes) : Array(bytes.reversed()) {
                                raw = (raw << 8) | UInt64(byte)
                            }
                            let bits = width * 8
                            let value: Double
                            if signed && raw & (UInt64(1) << (bits - 1)) != 0 {
                                value = Double(Int64(raw) - (Int64(1) << bits))
                            } else {
                                value = Double(raw)
                            }
                            values.append((row.time, value))
                        }
                        let numbers = values.map { $0.1 }
                        let signature = numbers.map { Int64($0) }
                        guard Set(signature).count >= 4, !deduplicated.contains(signature) else { continue }
                        deduplicated.insert(signature)

                        var speedPairs: [(Double, Double)] = []
                        var evPairs: [(Double, Double)] = []
                        var rpmPairs: [(Double, Double)] = []
                        var powerPairs: [(Double, Double)] = []
                        for (time, val) in values {
                            guard let ref = nearest(time) else { continue }
                            if let speed = ref.speed {
                                speedPairs.append((val, speed))
                                if speed > 3, let rpm = ref.engineRPM, rpm < 150 {
                                    evPairs.append((val, speed))
                                }
                            }
                            if let rpm = ref.engineRPM { rpmPairs.append((val, rpm)) }
                            if let power = ref.hvPower { powerPairs.append((val, power)) }
                        }
                        let sp = drivePearson(speedPairs)
                        let ev = drivePearson(evPairs)
                        let eng = drivePearson(rpmPairs)
                        let pw = drivePearson(powerPairs)
                        let motion = max(abs(ev ?? 0), abs(sp ?? 0) * 0.85)
                        let generator = abs(eng ?? 0)
                        let electrical = abs(pw ?? 0)
                        let diversity = min(1.0, Double(Set(signature).count) / Double(max(8, signature.count / 3)))
                        let motorScore = motion * diversity * (ev == nil ? 0.65 : 1.0)
                        let generatorScore = generator * diversity * (ev == nil || abs(ev ?? 0) < 0.4 ? 1 : 0.55)
                        let powerScore = electrical * diversity * 0.85
                        let best = max(motorScore, generatorScore, powerScore)
                        guard best >= 0.45 else { continue }
                        let type: String
                        if motorScore >= generatorScore && motorScore >= powerScore && motorScore >= 0.60 {
                            type = "駆動モーター回転系候補"
                        } else if generatorScore >= motorScore && generatorScore >= powerScore && generatorScore >= 0.60 {
                            type = "発電機・エンジン連動系候補"
                        } else if powerScore >= 0.60 {
                            type = "トルク・電力系候補"
                        } else {
                            type = "変化信号（未分類）"
                        }
                        let name = "u\(width * 8)\(signed ? "s" : "")\(bigEndian ? "BE" : "LE")@\(offset)"
                        results.append(DriveFieldCandidate(
                            ecu: first.ecu, did: first.did, field: name,
                            classification: type, score: best,
                            samples: values.count, speedCorrelation: sp,
                            evSpeedCorrelation: ev, engineCorrelation: eng,
                            hvPowerCorrelation: pw,
                            minValue: numbers.min() ?? 0, maxValue: numbers.max() ?? 0
                        ))
                    }
                }
            }
        }
    }
    return Array(results.sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.did != $1.did { return $0.did < $1.did }
        return $0.field < $1.field
    }.prefix(max(0, limit)))
}

private func didDriveDate(_ text: String) -> Double? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: text) { return d.timeIntervalSince1970 }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)?.timeIntervalSince1970
}

/// Replays a finalized SQLite capture. Classification never writes a signal
/// definition and never assumes a PID/DID semantic meaning from CAN ID alone.
public func analyzeDriveCapture(_ url: URL) -> [DriveFieldCandidate] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          let db else { if let db { sqlite3_close(db) }; return [] }
    defer { sqlite3_close(db) }

    var references: [DriveReference] = []
    var lastSpeed: (Double, Double)?
    var lastRPM: (Double, Double)?
    var lastPower: (Double, Double)?
    var command: OpaquePointer?
    let commandSQL = """
        SELECT ts_utc, UPPER(command), raw_response FROM commands
        WHERE command IN ('010C','010D','019A') ORDER BY ts_utc
    """
    if sqlite3_prepare_v2(db, commandSQL, -1, &command, nil) == SQLITE_OK, let command {
        defer { sqlite3_finalize(command) }
        while sqlite3_step(command) == SQLITE_ROW {
            guard let ts = sqlite3_column_text(command, 0),
                  let cmd = sqlite3_column_text(command, 1),
                  let time = didDriveDate(String(cString: ts)) else { continue }
            let n = Int(sqlite3_column_bytes(command, 2))
            let raw = sqlite3_column_blob(command, 2).map { Data(bytes: $0, count: n) } ?? Data()
            let text = String(data: raw, encoding: .utf8) ?? ""
            switch String(cString: cmd) {
            case "010C": if let v = decodeEngineRPM(text) { lastRPM = (time, v) }
            case "010D": if let v = decodeVehicleSpeed(text) { lastSpeed = (time, Double(v)) }
            case "019A": if let v = decodeHybridEv9A(text)?.powerKW { lastPower = (time, v) }
            default: break
            }
            let speed = lastSpeed.flatMap { time - $0.0 <= 2.5 ? $0.1 : nil }
            let rpm = lastRPM.flatMap { time - $0.0 <= 2.5 ? $0.1 : nil }
            let power = lastPower.flatMap { time - $0.0 <= 2.5 ? $0.1 : nil }
            references.append(DriveReference(time: time, speed: speed, engineRPM: rpm, hvPower: power))
        }
    }

    var samples: [DrivePayloadSample] = []
    var statement: OpaquePointer?
    // Analyze a bounded, time-spanning subset per DID. The SQLite capture is
    // never altered: only the in-memory correlation working set is reduced.
    // Modern iOS SQLite supports window functions (ROW_NUMBER / COUNT).
    let sql = """
        WITH ranked AS (
            SELECT ts_utc,ecu,did,payload,
                   ROW_NUMBER() OVER (PARTITION BY UPPER(ecu), did ORDER BY ts_utc) AS seq,
                   COUNT(*) OVER (PARTITION BY UPPER(ecu), did) AS total
            FROM did_drive_samples
            WHERE success=1 AND partial=0 AND length(payload) BETWEEN 2 AND 64
        )
        SELECT ts_utc,ecu,did,payload
        FROM ranked
        WHERE seq = 1 OR seq = total OR
              ((seq - 1) % MAX(1, total / 256)) = 0
        ORDER BY ts_utc
    """
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement {
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let ts = sqlite3_column_text(statement, 0),
                  let ecu = sqlite3_column_text(statement, 1),
                  let time = didDriveDate(String(cString: ts)),
                  sqlite3_column_type(statement, 3) != SQLITE_NULL else { continue }
            let n = Int(sqlite3_column_bytes(statement, 3))
            guard n >= 2 && n <= 64, let raw = sqlite3_column_blob(statement, 3) else { continue }
            samples.append(DrivePayloadSample(
                time: time, ecu: String(cString: ecu),
                did: UInt16(truncatingIfNeeded: sqlite3_column_int64(statement, 2)),
                payload: Data(bytes: raw, count: n)
            ))
        }
    }
    return rankDriveFields(samples: samples, references: references)
}
#endif
