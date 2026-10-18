//
//  ChartData.swift
//  SequelBridge
//
//  Pure data extraction for charting a query result, separate from the SwiftUI
//  chart view so it can be unit-tested. A chart plots one label (category) column
//  against one numeric value column over the loaded rows.
//

import Foundation

enum ChartKind: String, CaseIterable, Identifiable {
    case bar = "Bar"
    case line = "Line"
    case pie = "Pie"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .bar:  return "chart.bar"
        case .line: return "chart.xyaxis.line"
        case .pie:  return "chart.pie"
        }
    }
}

struct ChartPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
}

enum ChartData {

    /// Column indices that can serve as a numeric Y axis: either typed numeric, or
    /// (when types are unknown) a column whose non-NULL values all parse as numbers.
    static func numericColumnIndices(_ r: QueryResult) -> [Int] {
        (0..<r.columns.count).filter { ci in
            if ci < r.columnTypes.count, !r.columnTypes[ci].isEmpty {
                return QueryResult.isNumericType(r.columnTypes[ci])
            }
            // No type info: sniff. Numeric only if there's at least one value and
            // every non-NULL value parses as a finite Double.
            var sawValue = false
            for ri in 0..<r.rowCount where !r.isNull(ri, ci) {
                sawValue = true
                if parse(r.cells.value(ri, ci)) == nil { return false }
            }
            return sawValue
        }
    }

    /// A good default label (X) column: the first non-numeric column, else column 0.
    static func defaultLabelColumn(_ r: QueryResult) -> Int {
        let numeric = Set(numericColumnIndices(r))
        return (0..<r.columns.count).first { !numeric.contains($0) } ?? 0
    }

    /// A good default value (Y) column: the first numeric column, else nil.
    static func defaultValueColumn(_ r: QueryResult) -> Int? {
        numericColumnIndices(r).first
    }

    /// Build the plottable points, skipping rows whose value is NULL or non-numeric.
    /// Capped so a huge result still renders a readable chart.
    /// Rows plotted at most; a chart of thousands of bars is unreadable anyway.
    static let defaultCap = 200

    static func points(_ r: QueryResult, labelCol: Int, valueCol: Int, cap: Int = defaultCap) -> [ChartPoint] {
        guard valueCol >= 0, valueCol < r.columns.count else { return [] }
        var out: [ChartPoint] = []
        for ri in 0..<r.rowCount {
            if out.count >= cap { break }
            guard !r.isNull(ri, valueCol), let v = parse(r.cells.value(ri, valueCol)) else { continue }
            let label: String
            if labelCol >= 0, labelCol < r.columns.count {
                label = r.isNull(ri, labelCol) ? "NULL" : r.cells.value(ri, labelCol)
            } else {
                label = "\(ri + 1)"
            }
            out.append(ChartPoint(label: label, value: v))
        }
        return out
    }

    /// Parse a display string to a finite Double (plain numbers only; no thousands
    /// separators, which would be ambiguous across locales).
    static func parse(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let d = Double(t), d.isFinite else { return nil }
        return d
    }
}
