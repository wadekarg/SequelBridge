//
//  RelationsTableLayoutTests.swift
//  SequelBridgeTests
//
//  The Relations table in a pane narrower than its columns: the window a 1024×768 screen
//  opens leaves 551 points beside the left panel. A table that asks for more than its pane
//  is centered and cut off on both sides, and its last column, the foreign key's name, was
//  squeezed to nothing.
//

import AppKit
import SwiftUI
import Testing
@testable import SequelBridge

@MainActor
@Suite("Relations table in a narrow pane")
struct RelationsTableLayoutTests {
    private let fk = RelationInfo(name: "ui_fk", column: "pid", referencedTable: "ui_parent",
                                  referencedColumn: "id", onDelete: "RESTRICT", onUpdate: "CASCADE")

    @Test("takes no more width than its pane has; what doesn't fit scrolls")
    func fitsItsPane() {
        let host = NSHostingController(rootView: RelationsTable(relations: [fk], selectedId: .constant(nil)))
        for width in [551.0, 400, 300] {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 400))
            #expect(size.width <= width, "a \(Int(width))-point pane: the table took \(size.width)")
        }
    }

    @Test("the name column is as wide as the longest name")
    func nameColumnFitsTheLongestName() {
        let long = RelationInfo(name: "fk_order_lines_customer_shipping_address", column: "address_id",
                                referencedTable: "addresses", referencedColumn: "id",
                                onDelete: "SET NULL", onUpdate: "NO ACTION")
        let longWidth = NSAttributedString(string: long.name, attributes: [.font: NSFont.systemFont(ofSize: 11)]).size().width
        #expect(RelationsTable.nameColumnWidth(for: [fk, long]) >= longWidth)
        #expect(RelationsTable.nameColumnWidth(for: [fk]) > 0)
    }
}
