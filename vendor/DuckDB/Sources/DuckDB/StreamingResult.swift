//
//  StreamingResult.swift
//  DuckDB — SequelBridge local patch (see vendor/DuckDB/README.md, "Local patches")
//
//  A query executed as a STREAMING result: DuckDB runs the pipeline lazily and hands
//  out one data chunk per `nextChunk()`, so a large result is never materialized
//  inside DuckDB (the wrapper's `ResultSet` holds every chunk of a finished query) and
//  the first rows are available while the query is still producing the rest. Chunks
//  read through the same bulk readers as `ResultSet`, so cells render identically.
//
//  Uses `duckdb_execute_prepared_streaming`, which the C API marks deprecated since
//  1.0 but still ships (the chunk functions `ResultSet` relies on are in the same
//  boat); the pending API is the migration path if it is removed.
//

#if compiler(>=6.0)
internal import Cduckdb
#else
@_implementationOnly import Cduckdb
#endif
import Foundation

/// One data chunk of a streaming result: up to a vector's worth of rows (2048).
public final class ResultChunk {
  let chunk: DataChunk

  init(_ chunk: DataChunk) { self.chunk = chunk }

  public var rowCount: Int { Int(chunk.count) }
  public var columnCount: Int { Int(chunk.columnCount) }

  /// The storage type of a column, as `ResultSet`'s `Column.underlyingDatabaseType`.
  public func columnDataType(at index: DBInt) -> DatabaseType {
    chunk.withVector(at: index) { $0.logicalType.underlyingDataType }
  }
}

extension ResultChunk: ChunkWalker {
  func forEachChunk(column: DBInt, rows: Range<DBInt>, _ body: (Vector, Range<Int>) -> Void) {
    let upper = Swift.min(Int(rows.upperBound), rowCount)
    let lower = Int(rows.lowerBound)
    guard lower < upper else { return }
    chunk.withVector(at: column) { vector in body(vector, lower ..< upper) }
  }
}

public extension ResultChunk {
  func bulk(_ type: String.Type,    column: DBInt, rows: Range<DBInt>) -> [String?]    { stringCells(column: column, rows: rows) }
  func bulk(_ type: Bool.Type,      column: DBInt, rows: Range<DBInt>) -> [Bool?]      { primitiveCells(Bool.self,   column: column, rows: rows) }
  func bulk(_ type: Int8.Type,      column: DBInt, rows: Range<DBInt>) -> [Int8?]      { primitiveCells(Int8.self,   column: column, rows: rows) }
  func bulk(_ type: Int16.Type,     column: DBInt, rows: Range<DBInt>) -> [Int16?]     { primitiveCells(Int16.self,  column: column, rows: rows) }
  func bulk(_ type: Int32.Type,     column: DBInt, rows: Range<DBInt>) -> [Int32?]     { primitiveCells(Int32.self,  column: column, rows: rows) }
  func bulk(_ type: Int64.Type,     column: DBInt, rows: Range<DBInt>) -> [Int64?]     { primitiveCells(Int64.self,  column: column, rows: rows) }
  func bulk(_ type: UInt8.Type,     column: DBInt, rows: Range<DBInt>) -> [UInt8?]     { primitiveCells(UInt8.self,  column: column, rows: rows) }
  func bulk(_ type: UInt16.Type,    column: DBInt, rows: Range<DBInt>) -> [UInt16?]    { primitiveCells(UInt16.self, column: column, rows: rows) }
  func bulk(_ type: UInt32.Type,    column: DBInt, rows: Range<DBInt>) -> [UInt32?]    { primitiveCells(UInt32.self, column: column, rows: rows) }
  func bulk(_ type: UInt64.Type,    column: DBInt, rows: Range<DBInt>) -> [UInt64?]    { primitiveCells(UInt64.self, column: column, rows: rows) }
  func bulk(_ type: Float.Type,     column: DBInt, rows: Range<DBInt>) -> [Float?]     { primitiveCells(Float.self,  column: column, rows: rows) }
  func bulk(_ type: Double.Type,    column: DBInt, rows: Range<DBInt>) -> [Double?]    { primitiveCells(Double.self, column: column, rows: rows) }
  func bulk(_ type: IntHuge.Type,   column: DBInt, rows: Range<DBInt>) -> [IntHuge?]   { intHugeCells(column: column, rows: rows) }
  func bulk(_ type: UIntHuge.Type,  column: DBInt, rows: Range<DBInt>) -> [UIntHuge?]  { uintHugeCells(column: column, rows: rows) }
  func bulk(_ type: UUID.Type,      column: DBInt, rows: Range<DBInt>) -> [UUID?]      { uuidCells(column: column, rows: rows) }
  func bulk(_ type: Time.Type,      column: DBInt, rows: Range<DBInt>) -> [Time?]      { timeCells(column: column, rows: rows) }
  func bulk(_ type: TimeTz.Type,    column: DBInt, rows: Range<DBInt>) -> [TimeTz?]    { timeTzCells(column: column, rows: rows) }
  func bulk(_ type: Date.Type,      column: DBInt, rows: Range<DBInt>) -> [Date?]      { dateCells(column: column, rows: rows) }
  func bulk(_ type: Interval.Type,  column: DBInt, rows: Range<DBInt>) -> [Interval?]  { intervalCells(column: column, rows: rows) }
  func bulk(_ type: Timestamp.Type, column: DBInt, rows: Range<DBInt>) -> [Timestamp?] { timestampCells(column: column, rows: rows) }
  func bulk(_ type: Data.Type,      column: DBInt, rows: Range<DBInt>) -> [Data?]      { blobCells(column: column, rows: rows) }
  func bulk(_ type: Decimal.Type,   column: DBInt, rows: Range<DBInt>) -> [Decimal?]   { decimalCells(column: column, rows: rows) }
}

/// A prepared statement executed as a streaming result.
public final class StreamingResult {
  private let ptr = UnsafeMutablePointer<duckdb_result>.allocate(capacity: 1)
  private let prepared: PreparedStatement   // kept alive for the life of the stream
  private var exhausted = false

  public let columnCount: DBInt

  public init(prepared: PreparedStatement) throws {
    self.prepared = prepared
    let status = prepared.withCPreparedStatement { [ptr] in duckdb_execute_prepared_streaming($0, ptr) }
    guard status == .success else {
      // The failed result is still destroyed in deinit, as the C API requires.
      let error = duckdb_result_error(ptr).map(String.init(cString:))
      columnCount = 0
      exhausted = true
      throw DatabaseError.preparedStatementQueryError(reason: error)
    }
    columnCount = duckdb_column_count(ptr)
  }

  public func columnName(at index: DBInt) -> String {
    String(cString: duckdb_column_name(ptr, index))
  }

  public func columnDataType(at index: DBInt) -> DatabaseType {
    DatabaseType(rawValue: duckdb_column_type(ptr, index).rawValue)
  }

  /// The next chunk, or nil once the result is exhausted. An error raised while the
  /// query produces rows (a bad cast in a later row, an interrupt) surfaces here.
  public func nextChunk() throws -> ResultChunk? {
    guard !exhausted else { return nil }
    guard let cchunk = duckdb_fetch_chunk(ptr.pointee) else {
      exhausted = true
      if let error = duckdb_result_error(ptr) {
        throw DatabaseError.connectionQueryError(reason: String(cString: error))
      }
      return nil
    }
    return ResultChunk(DataChunk(owning: cchunk))
  }

  deinit {
    duckdb_destroy_result(ptr)
    ptr.deallocate()
  }
}
