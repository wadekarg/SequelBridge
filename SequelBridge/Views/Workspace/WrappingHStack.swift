//
//  WrappingHStack.swift
//  SequelBridge
//
//  Lays its subviews out left to right and starts a new row when the next one doesn't
//  fit: the connection tabs at the top of the left panel wrap instead of scrolling out
//  of sight. A subview wider than the row gets a row of its own, at the row's width.
//

import SwiftUI

struct WrappingHStack: Layout {
    var spacing: CGFloat = 0

    /// The row each item lands on, given the items' widths and the width available.
    static func rows(widths: [CGFloat], available: CGFloat, spacing: CGFloat) -> [Int] {
        var result: [Int] = []
        var row = 0, x: CGFloat = 0
        for w in widths {
            if x > 0, x + spacing + w > available { row += 1; x = 0 }
            x += (x > 0 ? spacing : 0) + w
            result.append(row)
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let oneRow = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        let available = proposal.width ?? oneRow
        let rowOf = Self.rows(widths: sizes.map(\.width), available: available, spacing: spacing)
        return CGSize(width: available, height: rowHeights(sizes, rowOf).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rowOf = Self.rows(widths: sizes.map(\.width), available: bounds.width, spacing: spacing)
        let heights = rowHeights(sizes, rowOf)
        var x = bounds.minX, y = bounds.minY, row = 0
        for (i, subview) in subviews.enumerated() {
            if rowOf[i] != row { y += heights[row]; x = bounds.minX; row = rowOf[i] }
            let width = min(sizes[i].width, bounds.width)
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: sizes[i].height))
            x += width + spacing
        }
    }

    private func rowHeights(_ sizes: [CGSize], _ rowOf: [Int]) -> [CGFloat] {
        var heights = [CGFloat](repeating: 0, count: (rowOf.last ?? -1) + 1)
        for (i, row) in rowOf.enumerated() { heights[row] = max(heights[row], sizes[i].height) }
        return heights
    }
}
