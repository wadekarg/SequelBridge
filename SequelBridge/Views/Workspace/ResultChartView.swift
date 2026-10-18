//
//  ResultChartView.swift
//  SequelBridge
//
//  Charts a query result inline — bar/line/pie over a chosen label + value column.
//  The headline angle: this works on ANY result, including a cross-engine JOIN that
//  no other client can even run, so you can chart MySQL × ClickHouse data directly.
//

import SwiftUI
import Charts

struct ResultChartView: View {
    let result: QueryResult

    @State private var kind: ChartKind = .bar
    @State private var labelCol: Int = 0
    @State private var valueCol: Int = 0
    @State private var numericCols: [Int] = []   // computed once per result, not per body

    private var points: [ChartPoint] { ChartData.points(result, labelCol: labelCol, valueCol: valueCol) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if numericCols.isEmpty {
                message("No numeric column to chart", "Add a numeric column (a count, sum, price…) to the query.")
            } else if points.isEmpty {
                message("Nothing to plot", "The selected value column has no numeric, non-NULL rows.")
            } else {
                chart
                    .padding(16)
                if result.rowCount > ChartData.defaultCap {
                    Text("Showing the first \(ChartData.defaultCap) of \(result.rowCount) rows")
                        .font(.caption2).foregroundColor(.secondary)
                        .padding(.bottom, 6)
                }
            }
        }
        .onAppear { configure() }
        // A new query can arrive while the chart stays on screen; re-pick axes so we
        // never plot the previous result's columns.
        .onChange(of: result.columns) { _, _ in configure() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $kind) {
                ForEach(ChartKind.allCases) { k in
                    Label(k.rawValue, systemImage: k.systemImage).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Divider().frame(height: 14)

            Text("Label").font(.caption).foregroundColor(.secondary)
            Picker("", selection: $labelCol) {
                ForEach(0..<result.columns.count, id: \.self) { i in
                    Text(result.columns[i]).tag(i)
                }
            }
            .labelsHidden().fixedSize()

            Text("Value").font(.caption).foregroundColor(.secondary)
            Picker("", selection: $valueCol) {
                ForEach(numericCols, id: \.self) { i in
                    Text(result.columns[i]).tag(i)
                }
            }
            .labelsHidden().fixedSize()

            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder
    private var chart: some View {
        switch kind {
        case .bar:
            Chart(points) { p in
                BarMark(x: .value("Label", p.label), y: .value(result.columns[safe: valueCol] ?? "Value", p.value))
                    .foregroundStyle(Color.accentColor)
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel(orientation: .vertical) } }
        case .line:
            Chart(points) { p in
                LineMark(x: .value("Label", p.label), y: .value(result.columns[safe: valueCol] ?? "Value", p.value))
                PointMark(x: .value("Label", p.label), y: .value("Value", p.value))
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel(orientation: .vertical) } }
        case .pie:
            Chart(points) { p in
                SectorMark(angle: .value("Value", p.value), innerRadius: .ratio(0.55), angularInset: 1)
                    .foregroundStyle(by: .value("Label", p.label))
                    .cornerRadius(3)
            }
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundColor(.secondary.opacity(0.4))
            Text(title).font(.headline).foregroundColor(.secondary)
            Text(detail).font(.caption).foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Recompute the numeric-column set and reset the axes to sensible defaults for
    /// the current result. Runs on appear and whenever the result's columns change.
    private func configure() {
        numericCols = ChartData.numericColumnIndices(result)
        labelCol = ChartData.defaultLabelColumn(result)
        valueCol = ChartData.defaultValueColumn(result) ?? labelCol
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
