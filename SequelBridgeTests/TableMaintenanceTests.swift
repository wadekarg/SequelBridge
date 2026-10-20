//
//  TableMaintenanceTests.swift
//  SequelBridgeTests
//
//  Table Maintenance on a table's right-click menu, as in Sequel Ace: Analyze, Check,
//  Optimize, Repair, Flush and Checksum, each with the server's answer. From the Sequel
//  Ace checklist (guide/SEQUEL-ACE.md), where it was missing.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Table maintenance")
struct TableMaintenanceTests {
    @Test("each task names the one table")
    func statements() {
        #expect(TableMaintenance.analyze.sql(database: "shop", table: "orders") == "ANALYZE TABLE `shop`.`orders`")
        #expect(TableMaintenance.check.sql(database: "shop", table: "orders") == "CHECK TABLE `shop`.`orders`")
        #expect(TableMaintenance.optimize.sql(database: "shop", table: "orders") == "OPTIMIZE TABLE `shop`.`orders`")
        #expect(TableMaintenance.repair.sql(database: "shop", table: "orders") == "REPAIR TABLE `shop`.`orders`")
        #expect(TableMaintenance.flush.sql(database: "shop", table: "orders") == "FLUSH TABLES `shop`.`orders`")
        #expect(TableMaintenance.checksum.sql(database: "s`p", table: "o") == "CHECKSUM TABLE `s``p`.`o`")
    }

    @Test("only Check and Checksum leave the table as it is: the others are off on a read-only connection")
    func readOnly() {
        #expect(TableMaintenance.allCases.filter { !$0.changesTheTable } == [.check, .checksum])
    }

    @Test("the server's answer reads as lines: each message, a checksum, or Done")
    func summary() {
        let checked = TableMaintenance.summary(columns: ["Table", "Op", "Msg_type", "Msg_text"],
                                               rows: [["shop.orders", "check", "status", "OK"]])
        #expect(checked == "status: OK")
        let optimized = TableMaintenance.summary(columns: ["Table", "Op", "Msg_type", "Msg_text"], rows: [
            ["shop.orders", "optimize", "note", "Table does not support optimize, doing recreate + analyze instead"],
            ["shop.orders", "optimize", "status", "OK"]])
        #expect(optimized == "note: Table does not support optimize, doing recreate + analyze instead\nstatus: OK")
        #expect(TableMaintenance.summary(columns: ["Table", "Checksum"], rows: [["shop.orders", "3906532113"]]) == "Checksum: 3906532113")
        #expect(TableMaintenance.summary(columns: [], rows: []) == "Done")
    }
}
