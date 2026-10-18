//
//  ResultEditingTests.swift
//  SequelBridgeTests
//
//  A Query-tab result can be edited when it is one table's rows, the way Sequel Ace
//  decides it: every value traces back to a column of that table, and the row is
//  found again by the table's primary key, which must be in the result. These pin
//  the reading of the SELECT, the matching of result columns to table columns, and
//  the UPDATE a cell edit sends. Hermetic.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Query-result editing: reading the SELECT")
struct ResultEditingSourceTests {
    private func src(_ sql: String, _ aliases: [String] = ["shop", "crm"]) -> ResultEditing.Source? {
        ResultEditing.source(of: sql, aliases: aliases)
    }

    @Test("plain columns of one table, with WHERE, ORDER BY and LIMIT")
    func plainColumns() {
        #expect(src("SELECT id, status FROM shop.orders WHERE status = 'paid' ORDER BY id DESC LIMIT 5")
                == .init(alias: "shop", database: nil, table: "orders", queryAlias: "orders",
                         items: [.column("id", output: "id"), .column("status", output: "status")]))
    }

    @Test("star, a table alias, a database part, and computed columns")
    func starAndComputed() {
        #expect(src("select * from shop.orders o")?.items == [.all])
        #expect(src("SELECT o.*, upper(o.status) FROM shop.shopdemo.orders AS o")
                == .init(alias: "shop", database: "shopdemo", table: "orders", queryAlias: "o",
                         items: [.all, .computed]))
        #expect(src("SELECT id + 1, 'x', status FROM shop.orders")?.items
                == [.computed, .computed, .column("status", output: "status")])
    }

    @Test("renamed and quoted columns keep the table column they show")
    func renamed() {
        #expect(src("SELECT o.status AS s, o.id ident FROM shop.orders o;")?.items
                == [.column("status", output: "s"), .column("id", output: "ident")])
        #expect(src("SELECT `status`, \"id\" FROM shop.`orders`")?.items
                == [.column("status", output: "status"), .column("id", output: "id")])
    }

    @Test("with one connection a table may be named without its alias")
    func unprefixed() {
        #expect(src("SELECT * FROM orders WHERE id < 10", ["shop"])
                == .init(alias: nil, database: nil, table: "orders", queryAlias: "orders", items: [.all]))
        #expect(src("SELECT * FROM shopdemo.orders", ["shop"])
                == .init(alias: nil, database: "shopdemo", table: "orders", queryAlias: "orders", items: [.all]))
    }

    @Test("anything that isn't one table's rows is declined")
    func declined() {
        for sql in [
            "SELECT o.id FROM shop.orders o JOIN crm.customers c ON o.customer_id = c.id",
            "SELECT * FROM shop.orders, shop.products",
            "SELECT * FROM shop.orders LEFT JOIN shop.order_items ON 1 = 1",
            "SELECT status, COUNT(*) FROM shop.orders GROUP BY status",
            "SELECT DISTINCT status FROM shop.orders",
            "SELECT id FROM shop.orders UNION SELECT id FROM shop.products",
            "WITH x AS (SELECT * FROM shop.orders) SELECT * FROM x",
            "SELECT * FROM (SELECT * FROM shop.orders) t",
            "SELECT 1",
            "SELECT * FROM read_csv('x.csv')",
            "UPDATE shop.orders SET status = 'x'",
            "SELECT * FROM shop.orders FOR UPDATE",
        ] {
            #expect(src(sql) == nil, "\(sql)")
        }
    }
}

@Suite("Query-result editing: matching the result to the table")
struct ResultEditTargetTests {
    private let orders = [
        ColumnInfo(id: "id", name: "id", dataType: "int", nullable: false, isPrimaryKey: true),
        ColumnInfo(id: "customer_id", name: "customer_id", dataType: "int", nullable: false, isPrimaryKey: false),
        ColumnInfo(id: "status", name: "status", dataType: "varchar(10)", nullable: true, isPrimaryKey: false),
        ColumnInfo(id: "placed_at", name: "placed_at", dataType: "datetime", nullable: true, isPrimaryKey: false),
    ]

    private func target(_ sql: String, _ resultColumns: [String],
                        table: [ColumnInfo]? = nil) -> (target: ResultEditTarget?, reason: String?) {
        let source = ResultEditing.source(of: sql, aliases: ["shop"])!
        return ResultEditing.target(source: source, alias: "shop", database: "shopdemo",
                                    resultColumns: resultColumns, tableColumns: table ?? orders)
    }

    @Test("SELECT * maps every column and finds the key")
    func star() {
        let r = target("SELECT * FROM shop.orders", ["id", "customer_id", "status", "placed_at"])
        #expect(r.reason == nil)
        #expect(r.target == ResultEditTarget(alias: "shop", database: "shopdemo", table: "orders",
                                             columns: [0: "id", 1: "customer_id", 2: "status", 3: "placed_at"],
                                             primaryKey: [.init(column: "id", resultIndex: 0)]))
    }

    @Test("a renamed column edits its table column; a computed one says why it can't")
    func renamedAndComputed() {
        let r = target("SELECT status AS s, upper(status), ID FROM shop.orders", ["s", "upper(status)", "ID"])
        #expect(r.reason == nil)
        #expect(r.target?.columns == [0: "status", 2: "id"])
        #expect(r.target?.primaryKey == [.init(column: "id", resultIndex: 2)])
        #expect(r.target?.reason(forColumn: 0) == nil)
        #expect(r.target?.reason(forColumn: 1) == ResultEditing.computedColumn)
    }

    @Test("without the primary key in the result nothing is editable, and it says what to add")
    func keyMissing() {
        let r = target("SELECT status FROM shop.orders", ["status"])
        #expect(r.target == nil)
        #expect(r.reason == ResultEditing.missingKey(table: "orders", key: ["id"]))
    }

    @Test("a table without a primary key isn't editable")
    func noKey() {
        let noPK = orders.map { ColumnInfo(id: $0.id, name: $0.name, dataType: $0.dataType,
                                           nullable: $0.nullable, isPrimaryKey: false) }
        let r = target("SELECT * FROM shop.orders", ["id", "customer_id", "status", "placed_at"], table: noPK)
        #expect(r.target == nil)
        #expect(r.reason == CellEditability.reason(engine: .mysql, readOnly: false, hasPrimaryKey: false))
    }

    @Test("a result whose columns don't line up with the SELECT isn't edited")
    func mismatched() {
        #expect(target("SELECT * FROM shop.orders", ["id", "status"]).reason == ResultEditing.unmatchedColumns)
        #expect(target("SELECT id, status FROM shop.orders", ["id", "state"]).reason == ResultEditing.unmatchedColumns)
        // A bare name that isn't one of the table's columns is computed (CURRENT_DATE).
        #expect(target("SELECT id, CURRENT_DATE FROM shop.orders", ["id", "current_date"]).target?.columns == [0: "id"])
    }

    @Test("a composite key uses every key column, wherever it sits in the result")
    func compositeKey() {
        let items = [
            ColumnInfo(id: "order_id", name: "order_id", dataType: "int", nullable: false, isPrimaryKey: true),
            ColumnInfo(id: "product_id", name: "product_id", dataType: "int", nullable: false, isPrimaryKey: true),
            ColumnInfo(id: "qty", name: "qty", dataType: "int", nullable: false, isPrimaryKey: false),
        ]
        let source = ResultEditing.source(of: "SELECT qty, product_id, order_id FROM shop.order_items", aliases: ["shop"])!
        let r = ResultEditing.target(source: source, alias: "shop", database: "shopdemo",
                                     resultColumns: ["qty", "product_id", "order_id"], tableColumns: items)
        #expect(r.target?.primaryKey == [.init(column: "order_id", resultIndex: 2),
                                         .init(column: "product_id", resultIndex: 1)])
    }

    @Test("the UPDATE for a cell is keyed by that row's primary key")
    func update() {
        let t = target("SELECT id, status FROM shop.orders", ["id", "status"]).target!
        var shown = QueryResult(columns: ["id", "status"], rows: [["7", "paid"], ["8", "pending"]], executionTime: 0)
        shown.nullMask = [[false, false], [false, false]]
        #expect(t.update(row: 1, column: 1, value: "shipped", in: shown)
                == SQLBuilder.update(alias: "shop", database: "shopdemo", table: "orders", column: "status",
                                     newValue: "shipped", primaryKey: [(column: "id", value: "8")]))
        #expect(t.update(row: 0, column: 1, value: nil, in: shown)
                == SQLBuilder.update(alias: "shop", database: "shopdemo", table: "orders", column: "status",
                                     newValue: nil, primaryKey: [(column: "id", value: "7")]))
    }
}
