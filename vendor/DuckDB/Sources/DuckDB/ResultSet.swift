//
//  DuckDB
//  https://github.com/duckdb/duckdb-swift
//
//  Copyright © 2018-2024 Stichting DuckDB Foundation
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to
//  deal in the Software without restriction, including without limitation the
//  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//  sell copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
//  IN THE SOFTWARE.

#if compiler(>=6.0)
internal import Cduckdb
#else
@_implementationOnly import Cduckdb
#endif
import Foundation

/// An object representing a DuckDB result set
///
/// A DuckDB result set contains the data returned from the database after a
/// successful query.
///
/// A result set is organized into vertical table slices called columns. Each
/// column of the result set is accessible by calling the ``subscript(_:)``
/// method of the result.
///
/// Elements of a column can be accessed by casting the column to the native
/// Swift type that matches the underlying database column type. See ``Column``
/// for further discussion.
public struct ResultSet: Sendable {
  
  /// The number of chunks in the result set
  public var chunkCount: DBInt { chunkStorage.chunkCount }
  /// The number of columns in the result set
  public var columnCount: DBInt { storage.columnCount }
  /// The total number of rows in the result set
  public var rowCount: DBInt { chunkStorage.totalRowCount }
  
  private let storage: ResultStorage
  let chunkStorage: ChunkStorage   // SequelBridge patch: internal for ResultSet+Bulk
  
  init(connection: Connection, sql: String) throws {
    self.storage = try ResultStorage(connection: connection, sql: sql)
    self.chunkStorage = ChunkStorage(resultStorage: storage)
  }
  
  init(prepared: PreparedStatement) throws {
    self.storage = try ResultStorage(prepared: prepared)
    self.chunkStorage = ChunkStorage(resultStorage: storage)
  }
  
  /// Returns a `Void` typed column for the given column index
  ///
  /// A `Void` typed column can be cast to a column matching the underlying
  /// database representation using ``Column/cast(to:)-4376d``. See ``Column``
  /// for further discussion.
  ///
  /// - Parameter columnIndex: the index of the column in the result set
  /// - Returns: a `Void` typed column
  public func column(at columnIndex: DBInt) -> Column<Void> {
    precondition(columnIndex < columnCount)
    return Column(result: self, columnIndex: columnIndex) { $0.unwrapNull() ? nil : () }
  }
  
  /// The underlying column name for the given column index
  ///
  /// - Parameter columnIndex: the index of the column in the result set
  /// - Returns: the name of the column
  public func columnName(at columnIndex: DBInt) -> String {
    storage.columnName(at: columnIndex)
  }
  
  /// The index of the given column name
  ///
  /// - Parameter columnName: the name of the column in the result set
  /// - Returns: the index of the column
  /// - Complexity: O(n)
  public func index(forColumnName columnName: String) -> DBInt? {
    for i in 0..<columnCount {
      if self.columnName(at: i) == columnName {
        return i
      }
    }
    return nil
  }
  
  func columnDataType(at index: DBInt) -> DatabaseType {
    storage.columnDataType(at: index)
  }

  func columnLogicalType(at index: DBInt) -> LogicalType {
    storage.columnLogicalType(at: index)
  }
  
  // SequelBridge patch: upstream located a row by walking every chunk from the first
  // one on each call, so reading a whole result was O(rows² / vectorSize) per column —
  // a million-row, 12-column result took minutes to stream. ChunkStorage now keeps
  // each chunk's starting row and finds the chunk by binary search.
  func element(forColumn columnIndex: DBInt, at index: DBInt) -> Vector.Element {
    guard let hit = chunkStorage.locate(row: index) else {
      preconditionFailure("item out of bounds")
    }
    return hit.chunk.withVector(at: columnIndex) { vector in
      vector[Int(hit.offset)]
    }
  }
}

// MARK: - Collection conformance

extension ResultSet: RandomAccessCollection {
  
  public typealias Element = Column<Void>
  
  public struct Iterator: IteratorProtocol {
    
    private let result: ResultSet
    private var position: DBInt
    
    init(result: ResultSet) {
      self.result = result
      self.position = result.startIndex
    }
    
    public mutating func next() -> Element? {
      guard position < result.endIndex else { return nil }
      defer { position += 1 }
      return .some(result[position])
    }
  }
  
  public var startIndex: DBInt { 0 }
  public var endIndex: DBInt { columnCount }
  
  public subscript(position: DBInt) -> Column<Void> {
    column(at: position)
  }
  
  public func makeIterator() -> Iterator {
    Iterator(result: self)
  }
  
  public func index(after i: DBInt) -> DBInt { i + 1 }
  public func index(before i: DBInt) -> DBInt { i - 1 }
}

// MARK: - Debug Description

extension ResultSet: CustomDebugStringConvertible {
  
  public var debugDescription: String {
    let summary = "chunks: \(chunkCount); rows: \(rowCount); columns: \(columnCount); layout:"
    var columns = [String]()
    for i in 0..<columnCount {
      let name = columnName(at: i)
      let type = columnDataType(at: i).description.uppercased()
      columns.append("\t\(name) \(type)")
    }
    return "<\(Self.self): { \(summary) (\n\(columns.joined(separator: ",\n"))\n);>"
  }
}

// MARK: - Utilities

fileprivate final class ResultStorage: Sendable {
  
  let columnCount: DBInt
  
  private let ptr = UnsafeMutablePointer<duckdb_result>.allocate(capacity: 1)
  
  init(connection: Connection, sql: String) throws {
    let status = sql.withCString { [ptr] queryStrPtr in
      connection.withCConnection { duckdb_query($0, queryStrPtr, ptr) }
    }
    guard status == .success else {
      let error = duckdb_result_error(ptr).map(String.init(cString:))
      throw DatabaseError.connectionQueryError(reason: error)
    }
    self.columnCount = duckdb_column_count(ptr)
  }
  
  init(prepared: PreparedStatement) throws {
    let status = prepared.withCPreparedStatement { [ptr] in duckdb_execute_prepared($0, ptr) }
    guard status == .success else {
      let error = duckdb_result_error(ptr).map(String.init(cString:))
      throw DatabaseError.preparedStatementQueryError(reason: error)
    }
    self.columnCount = duckdb_column_count(ptr)
  }
  
  func columnName(at columnIndex: DBInt) -> String {
    String(cString: duckdb_column_name(ptr, columnIndex))
  }
  
  func columnDataType(at index: DBInt) -> DatabaseType {
    let dataType = duckdb_column_type(ptr, index)
    return DatabaseType(rawValue: dataType.rawValue)
  }

  func columnLogicalType(at index: DBInt) -> LogicalType {
    return LogicalType { duckdb_column_logical_type(ptr, index) }
  }
  
  func withCResult<T>(_ body: (duckdb_result) throws -> T) rethrows -> T {
    try body(ptr.pointee)
  }
  
  deinit {
    duckdb_destroy_result(ptr)
    ptr.deallocate()
  }
}

// SequelBridge patch: internal (was fileprivate) so ResultSet+Bulk can walk chunks.
final class ChunkStorage: Sendable {
  
  let chunkCount: DBInt
  let totalRowCount: DBInt
  private let chunks: [DataChunk]
  /// SequelBridge patch: the row index at which each chunk starts (prefix sums of the
  /// chunk sizes), read once here — `DataChunk.count` is a C call every time — so
  /// `locate` can map a row to its chunk by binary search instead of a scan.
  private let chunkStarts: [DBInt]

  // fileprivate: ResultStorage is file-private; only ResultSet (this file) builds one.
  fileprivate init(resultStorage: ResultStorage) {
    let chunkCount = resultStorage.withCResult { duckdb_result_chunk_count($0) }
    var chunks = [DataChunk]()
    var starts = [DBInt]()
    chunks.reserveCapacity(Int(chunkCount))
    starts.reserveCapacity(Int(chunkCount))
    var totalRowCount = DBInt(0)
    for i in 0 ..< chunkCount {
      let chunk = resultStorage.withCResult { DataChunk(cresult: $0, index: i) }
      chunks.append(chunk)
      starts.append(totalRowCount)
      totalRowCount += chunk.count
    }
    self.chunks = chunks
    self.chunkStarts = starts
    self.chunkCount = chunkCount
    self.totalRowCount = totalRowCount
  }

  subscript(position: Int) -> DataChunk { chunks[position] }

  /// The chunk holding `row`, its index, and the row's offset within it; nil when out
  /// of range. Picks the last chunk whose start is at or before `row`, so an empty
  /// chunk (start equal to the next chunk's) is skipped over. O(log chunkCount).
  func locate(row: DBInt) -> (chunk: DataChunk, index: Int, offset: DBInt)? {
    guard row < totalRowCount, !chunks.isEmpty else { return nil }
    var lo = 0
    var hi = chunks.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if chunkStarts[mid] <= row { lo = mid } else { hi = mid - 1 }
    }
    return (chunks[lo], lo, row - chunkStarts[lo])
  }

  /// Rows in chunk `index`, from the precomputed starts — no C call.
  func chunkSize(at index: Int) -> DBInt {
    (index + 1 < chunks.count ? chunkStarts[index + 1] : totalRowCount) - chunkStarts[index]
  }
}
