//
//  DatabaseSheetTests.swift
//  SequelBridgeTests
//
//  Add Database… (with encoding and collation) and Delete Database… in the database
//  menu, as in Sequel Ace: from the Sequel Ace checklist (guide/SEQUEL-ACE.md), where
//  both were typed SQL only.
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("Database menu: add and delete a database")
struct DatabaseSheetTests {
    @Test("a new database names its encoding and collation, or takes the server's defaults")
    func create() {
        #expect(SQLBuilder.createDatabase("shop", charset: "utf8mb4", collation: "utf8mb4_unicode_ci")
                == "CREATE DATABASE `shop` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        #expect(SQLBuilder.createDatabase("shop", charset: "latin1", collation: "") == "CREATE DATABASE `shop` CHARACTER SET latin1")
        #expect(SQLBuilder.createDatabase("shop", charset: "", collation: "") == "CREATE DATABASE `shop`")
        #expect(SQLBuilder.createDatabase("odd`name", charset: "", collation: "") == "CREATE DATABASE `odd``name`")
    }

    @Test("deleting drops the one database named")
    func drop() {
        #expect(SQLBuilder.dropDatabase("shop") == "DROP DATABASE `shop`")
        #expect(SQLBuilder.dropDatabase("odd`name") == "DROP DATABASE `odd``name`")
    }

    @Test("the collations offered are the encoding's, its default first")
    func collations() {
        let all = [("latin1_swedish_ci", "latin1", false), ("utf8mb4_bin", "utf8mb4", false),
                   ("utf8mb4_general_ci", "utf8mb4", true), ("utf8mb4_unicode_ci", "utf8mb4", false)]
            .map { DatabaseCollation(name: $0.0, charset: $0.1, isDefault: $0.2) }
        #expect(DatabaseCollation.offered(all, charset: "utf8mb4") == ["utf8mb4_general_ci", "utf8mb4_bin", "utf8mb4_unicode_ci"])
        #expect(DatabaseCollation.offered(all, charset: "") == [])
    }
}
