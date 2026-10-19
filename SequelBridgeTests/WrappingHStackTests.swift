//
//  WrappingHStackTests.swift
//  SequelBridgeTests
//
//  The connection tabs at the top of the left panel sat in one strip that scrolled
//  sideways, so with several servers open their names slid out of sight. They wrap onto
//  more rows now. This pins where the rows break.
//

import CoreGraphics
import Testing
@testable import SequelBridge

@Suite("Wrapping tabs: where the rows break")
struct WrappingHStackTests {
    private func rows(_ widths: [CGFloat], in available: CGFloat, spacing: CGFloat = 0) -> [Int] {
        WrappingHStack.rows(widths: widths, available: available, spacing: spacing)
    }

    @Test("tabs that fit stay on one row")
    func fit() {
        #expect(rows([50, 60], in: 200) == [0, 0])
        #expect(rows([125, 125], in: 250) == [0, 0])
        #expect(rows([], in: 200) == [])
    }

    @Test("the next tab that doesn't fit starts a row")
    func wrap() {
        #expect(rows([120, 100, 90], in: 250) == [0, 0, 1])
        #expect(rows([120, 100, 90, 140, 30], in: 250) == [0, 0, 1, 1, 2])
        #expect(rows([120, 120], in: 245, spacing: 10) == [0, 1])
    }

    @Test("a tab wider than the panel gets a row of its own")
    func wide() {
        #expect(rows([300, 50], in: 250) == [0, 1])
        #expect(rows([50, 300, 50], in: 250) == [0, 1, 2])
    }
}
