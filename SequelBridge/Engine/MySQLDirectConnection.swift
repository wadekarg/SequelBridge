// Stub for Phase 3. Direct MySQL connection bypasses DuckDB for DDL and admin.
// Will be implemented with MySQLNIO in Phase 3.
import Foundation

final class MySQLDirectConnection {
    let connection: Connection
    private let password: String

    init(_ connection: Connection, password: String) {
        self.connection = connection
        self.password = password
    }

    // Phase 3: implement with MySQLNIO
    func execute(_ sql: String) async throws -> QueryResult {
        throw MySQLDirectError.notImplemented
    }
}

enum MySQLDirectError: LocalizedError {
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Direct MySQL connection not yet implemented. Use QueryEngine for queries."
        }
    }
}
