import Foundation
import SQLite3

/// A regenerable, per-asset cache. Keeping each analysis in its own row avoids
/// rewriting the entire photo library's feature prints for every scan update.
final class SuggestionAnalysisStore {
    private var database: OpaquePointer?
    private let legacyURL: URL

    private struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(url: URL, legacyURL: URL) throws {
        self.legacyURL = legacyURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open analysis cache"
            if let connection { sqlite3_close(connection) }
            throw StoreError(message: message)
        }
        database = connection
        do {
            // DELETE journaling keeps the one-time migration from needing a
            // second full-size WAL file while the legacy JSON still exists.
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS analyses (id TEXT PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
        } catch {
            sqlite3_close(connection)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    /// Import the old JSON only once. A transaction and readback finish before
    /// the old file is removed, so interruption cannot discard completed work.
    func loadMigratingLegacy() throws -> [String: SuggestionAnalysis] {
        let hasLegacy = FileManager.default.fileExists(atPath: legacyURL.path)
        if try migrationCompleted() {
            if let cached = try? load() {
                if hasLegacy { try? FileManager.default.removeItem(at: legacyURL) }
                return cached
            }
        }
        if hasLegacy {
            let data = try Data(contentsOf: legacyURL)
            guard let recovered = SuggestionAnalysisCache.decode(data) else {
                throw StoreError(message: "Unable to read the previous analysis cache")
            }
            try replaceAll(recovered)
            try verifyStoredRows(expectedCount: recovered.count)
            try? FileManager.default.removeItem(at: legacyURL)
            return recovered
        }
        return try load()
    }

    func apply(upserts: [String: SuggestionAnalysis], removals: Set<String>) throws {
        guard !upserts.isEmpty || !removals.isEmpty else { return }
        try transaction {
            try delete(removals)
            try insert(upserts)
        }
    }

    private func replaceAll(_ analyses: [String: SuggestionAnalysis]) throws {
        try transaction {
            try execute("DELETE FROM analyses")
            try insert(analyses)
            try execute("INSERT OR REPLACE INTO metadata (key, value) VALUES ('legacy_migrated', '1')")
        }
    }

    private func load() throws -> [String: SuggestionAnalysis] {
        let statement = try prepare("SELECT id, payload FROM analyses")
        defer { sqlite3_finalize(statement) }
        let decoder = PropertyListDecoder()
        var result: [String: SuggestionAnalysis] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = sqlite3_column_text(statement, 0),
                      let blob = sqlite3_column_blob(statement, 1) else {
                    throw StoreError(message: "Invalid analysis cache row")
                }
                let id = String(cString: idText)
                let payload = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
                result[id] = try decoder.decode(SuggestionAnalysis.self, from: payload)
            case SQLITE_DONE:
                return result
            default:
                throw databaseError()
            }
        }
    }

    /// Verify every migrated row without retaining a second copy of the
    /// library's feature prints in memory during the one-time import.
    private func verifyStoredRows(expectedCount: Int) throws {
        let statement = try prepare("SELECT payload FROM analyses")
        defer { sqlite3_finalize(statement) }
        let decoder = PropertyListDecoder()
        var count = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let blob = sqlite3_column_blob(statement, 0) else {
                    throw StoreError(message: "Invalid migrated analysis row")
                }
                let payload = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
                _ = try decoder.decode(SuggestionAnalysis.self, from: payload)
                count += 1
            case SQLITE_DONE:
                guard count == expectedCount else {
                    throw StoreError(message: "Analysis cache migration did not restore every entry")
                }
                return
            default:
                throw databaseError()
            }
        }
    }

    private func migrationCompleted() throws -> Bool {
        let statement = try prepare("SELECT value FROM metadata WHERE key = 'legacy_migrated'")
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError()
        }
    }

    private func insert(_ analyses: [String: SuggestionAnalysis]) throws {
        guard !analyses.isEmpty else { return }
        let statement = try prepare("INSERT OR REPLACE INTO analyses (id, payload) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for (id, analysis) in analyses {
            let payload = try encoder.encode(analysis)
            guard let payloadLength = Int32(exactly: payload.count) else {
                throw StoreError(message: "Analysis cache entry is too large")
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let textResult = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, Self.transient) }
            let blobResult = payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, payloadLength, Self.transient)
            }
            guard textResult == SQLITE_OK, blobResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError()
            }
        }
    }

    private func delete(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        let statement = try prepare("DELETE FROM analyses WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let binding = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, Self.transient) }
            guard binding == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw databaseError()
            }
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        return statement
    }

    private func databaseError() -> StoreError {
        StoreError(message: String(cString: sqlite3_errmsg(handle)))
    }

    private var handle: OpaquePointer { database! }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
