//
//  ForeignKeyFollowTests.swift
//  SequelBridgeTests
//
//  Following a foreign key from the Content tab, as in Sequel Ace: a cell of a key's
//  column leads to the row it points at. From the Sequel Ace checklist
//  (guide/SEQUEL-ACE.md), where it was missing.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Content tab: following a foreign key")
struct ForeignKeyFollowTests {
    typealias K = ForeignKeyFollow

    // fetchRelations' rows: constraint, columns, referenced table, referenced columns, on delete, on update.
    @Test("each column of a key leads to the table and columns it references")
    func targets() {
        let one = K.targets([["fk_orders_customer", "customer_id", "customers", "id", "CASCADE", "RESTRICT"]])
        #expect(one["customer_id"] == K.Target(table: "customers", columns: ["customer_id"], referenced: ["id"]))
        let two = K.targets([["fk_line", "order_id, line", "order_lines", "order_id, line_no", "", ""]])
        let target = K.Target(table: "order_lines", columns: ["order_id", "line"], referenced: ["order_id", "line_no"])
        #expect(two["order_id"] == target)
        #expect(two["line"] == target)
        #expect(K.targets([["broken", "a, b", "t", "x", "", ""]]).isEmpty, "a key whose sides don't pair up leads nowhere")
    }

    @Test("the referenced row's condition holds every column of the key; a NULL points at nothing")
    func condition() {
        let one = K.Target(table: "customers", columns: ["customer_id"], referenced: ["id"])
        #expect(K.condition(one, values: ["customer_id": "2"], dialect: .mysql) == "`id` = '2'")
        let two = K.Target(table: "order_lines", columns: ["order_id", "line"], referenced: ["order_id", "line_no"])
        #expect(K.condition(two, values: ["order_id": "7", "line": "3"], dialect: .standard)
                == "\"order_id\" = '7' AND \"line_no\" = '3'")
        #expect(K.condition(two, values: ["order_id": "7"], dialect: .standard) == nil)
    }
}
