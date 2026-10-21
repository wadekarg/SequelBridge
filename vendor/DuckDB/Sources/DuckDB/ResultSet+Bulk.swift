//
//  ResultSet+Bulk.swift
//  DuckDB — SequelBridge local patch (see vendor/DuckDB/README.md, "Local patches")
//
//  Chunk-sequential bulk column reads. The public per-element path (`Column`'s
//  subscript) creates a Vector, a LogicalType and an Element for EVERY cell, and the
//  per-cell `unwrap` re-fetches the validity bitmap, the type id and the data pointer
//  from the C API each time — several C calls and heap allocations per cell, which
//  capped extraction at ~125k cells/s and made a million-row, 12-column result take
//  minutes to stream. These readers walk the result's data chunks once; per chunk they
//  fetch the vector's validity bitmap, data pointer and type ONCE, then convert each
//  value with the same C-struct conversions `Vector.unwrap` uses, so values are
//  identical. A NULL cell, or a column whose type doesn't match, is nil — as the
//  per-element path's `try?` yields.
//
//  The readers are written once against `ChunkWalker` — anything that can visit data
//  chunks with a vector per chunk — and offered on `ResultSet` (a whole materialized
//  result) and on `ResultChunk` (one chunk of a streaming result).
//

#if compiler(>=6.0)
internal import Cduckdb
#else
@_implementationOnly import Cduckdb
#endif
import Foundation

/// Something that can visit the data chunks covering a row range, creating the
/// vector for a column once per chunk and passing the chunk-local index range to read.
protocol ChunkWalker {
  func forEachChunk(column: DBInt, rows: Range<DBInt>, _ body: (Vector, Range<Int>) -> Void)
}

extension ResultSet: ChunkWalker {
  func forEachChunk(column: DBInt, rows: Range<DBInt>, _ body: (Vector, Range<Int>) -> Void) {
    guard !rows.isEmpty, let first = chunkStorage.locate(row: rows.lowerBound) else { return }
    var chunkIndex = first.index
    var start = Int(first.offset)
    var row = rows.lowerBound
    while row < rows.upperBound, chunkIndex < Int(chunkStorage.chunkCount) {
      let size = Int(chunkStorage.chunkSize(at: chunkIndex))
      let take = Swift.min(size - start, Int(rows.upperBound - row))
      if take > 0 {
        chunkStorage[chunkIndex].withVector(at: column) { vector in body(vector, start ..< start + take) }
        row += DBInt(take)
      }
      chunkIndex += 1
      start = 0
    }
  }
}

extension ChunkWalker {

  /// Core: rows `rows` of `column`. `accept` decides (once per chunk) whether the
  /// column's storage type can be read as `C`, and `convert` turns each non-NULL raw
  /// value into `T`. Cells of a chunk that fails `accept` are nil.
  func bulkRaw<C, T>(column: DBInt, rows: Range<DBInt>,
                     accept: (DatabaseType) -> Bool,
                     _ convert: (C, DatabaseType) -> T) -> [T?] {
    var out = [T?]()
    out.reserveCapacity(rows.count)
    forEachChunk(column: column, rows: rows) { vector, range in
      let type = vector.logicalType.underlyingDataType
      guard accept(type) else {
        out.append(contentsOf: repeatElement(nil, count: range.count))
        return
      }
      let base = vector.offset
      vector.withCVector { cvector in
        let validity = duckdb_vector_get_validity(cvector)
        let data = duckdb_vector_get_data(cvector)!.assumingMemoryBound(to: C.self)
        for i in range {
          let j = base + i
          if let validity, validity[j >> 6] & (UInt64(1) << UInt64(j & 63)) == 0 {
            out.append(nil)
          } else {
            out.append(convert(data[j], type))
          }
        }
      }
    }
    return out
  }

  /// Generic path for the rare types with involved conversions (Decimal): one Vector
  /// per chunk, but the per-cell `unwrap` with its own type check.
  func bulkRead<T>(column: DBInt, rows: Range<DBInt>, _ read: (Vector, Int) throws -> T) -> [T?] {
    var out = [T?]()
    out.reserveCapacity(rows.count)
    forEachChunk(column: column, rows: rows) { vector, range in
      for i in range {
        out.append(vector.unwrapNull(at: i) ? nil : (try? read(vector, i)))
      }
    }
    return out
  }

  func primitiveCells<T: PrimitiveDatabaseValue>(_ type: T.Type, column: DBInt, rows: Range<DBInt>) -> [T?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == T.representedDatabaseTypeID }) { (v: T, _) in v }
  }
  func stringCells(column: DBInt, rows: Range<DBInt>) -> [String?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .varchar }) { (s: duckdb_string, _) in s.asStringFast }
  }
  func intHugeCells(column: DBInt, rows: Range<DBInt>) -> [IntHuge?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .hugeint }) { (v: duckdb_hugeint, _) in v.asIntHuge }
  }
  func uintHugeCells(column: DBInt, rows: Range<DBInt>) -> [UIntHuge?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .uhugeint }) { (v: duckdb_uhugeint, _) in v.asUIntHuge }
  }
  func uuidCells(column: DBInt, rows: Range<DBInt>) -> [UUID?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .uuid }) { (v: duckdb_hugeint, _) in v.asUUID }
  }
  func timeCells(column: DBInt, rows: Range<DBInt>) -> [Time?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .time }) { (v: duckdb_time, _) in v.asTime }
  }
  func timeTzCells(column: DBInt, rows: Range<DBInt>) -> [TimeTz?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .timeTz }) { (v: duckdb_time_tz, _) in v.asTime }
  }
  func dateCells(column: DBInt, rows: Range<DBInt>) -> [Date?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .date }) { (v: duckdb_date, _) in v.asDate }
  }
  func intervalCells(column: DBInt, rows: Range<DBInt>) -> [Interval?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .interval }) { (v: duckdb_interval, _) in v.asInterval }
  }
  /// Seconds/milliseconds/nanoseconds storage is rescaled to microseconds exactly as
  /// `Vector.unwrap(Timestamp.self)` does.
  func timestampCells(column: DBInt, rows: Range<DBInt>) -> [Timestamp?] {
    let kinds: Set<DatabaseType> = [.timestampS, .timestampMS, .timestamp, .timestampTz, .timestampNS]
    return bulkRaw(column: column, rows: rows, accept: { kinds.contains($0) }) { (v: duckdb_timestamp, type) in
      switch type {
      case .timestampS:  return duckdb_timestamp(micros: v.micros * 1_000_000).asTimestamp
      case .timestampMS: return duckdb_timestamp(micros: v.micros * 1_000).asTimestamp
      case .timestampNS: return duckdb_timestamp(micros: v.micros / 1_000).asTimestamp
      default:           return v.asTimestamp
      }
    }
  }
  func blobCells(column: DBInt, rows: Range<DBInt>) -> [Data?] {
    bulkRaw(column: column, rows: rows, accept: { $0 == .blob }) { (v: duckdb_blob, _) in v.asData }
  }
  func decimalCells(column: DBInt, rows: Range<DBInt>) -> [Decimal?] {
    bulkRead(column: column, rows: rows) { try $0.unwrap(Decimal.self, at: $1) }
  }
}

private extension duckdb_string {
  /// Same layout walk as `asString` — a UInt32 length first; up to 12 bytes inline
  /// right after it, otherwise a pointer at offset 8 — but decoded in one allocation
  /// without the Data round trip, and invalid UTF-8 is repaired rather than trapped on.
  var asStringFast: String {
    withUnsafePointer(to: self) { p in
      let raw = UnsafeRawPointer(p)
      let n = Int(raw.load(as: UInt32.self))
      let bytes: UnsafeRawPointer = n <= 12
        ? raw.advanced(by: MemoryLayout<UInt32>.stride)
        : raw.advanced(by: MemoryLayout<UInt64>.stride).load(as: UnsafeRawPointer.self)
      return String(decoding: UnsafeRawBufferPointer(start: bytes, count: n), as: UTF8.self)
    }
  }
}

public extension ResultSet {
  /// The digits a DECIMAL column keeps after the point; nil for any other type.
  func decimalScale(at index: DBInt) -> Int? {
    self[index].underlyingLogicalType.decimalProperties.map { Int($0.scale) }
  }

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
