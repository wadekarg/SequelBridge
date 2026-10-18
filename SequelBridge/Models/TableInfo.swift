//
//  TableInfo.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation

nonisolated enum TableType: String, Codable {
    case table = "BASE TABLE"
    case view  = "VIEW"
}

nonisolated struct ColumnInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var dataType: String       // full MySQL type e.g. "varchar(255)", "int(11)"
    var nullable: Bool
    var keyType: String        // "PRI", "UNI", "MUL", ""
    var defaultValue: String   // column default value, "" if none
    var extra: String          // e.g. "auto_increment", "on update CURRENT_TIMESTAMP"
    var encoding: String       // character_set_name
    var collation: String      // collation_name
    var comment: String        // column_comment

    var isPrimaryKey: Bool { keyType.uppercased() == "PRI" }

    // Convenience init for callers that only have basic info
    init(id: String, name: String, dataType: String, nullable: Bool, isPrimaryKey: Bool) {
        self.id = id; self.name = name; self.dataType = dataType
        self.nullable = nullable; self.keyType = isPrimaryKey ? "PRI" : ""
        self.defaultValue = ""; self.extra = ""; self.encoding = ""; self.collation = ""; self.comment = ""
    }

    init(id: String, name: String, dataType: String, nullable: Bool,
         keyType: String, defaultValue: String, extra: String,
         encoding: String, collation: String, comment: String) {
        self.id = id; self.name = name; self.dataType = dataType
        self.nullable = nullable; self.keyType = keyType
        self.defaultValue = defaultValue; self.extra = extra
        self.encoding = encoding; self.collation = collation; self.comment = comment
    }
}

nonisolated struct IndexInfo: Identifiable, Hashable {
    var id: String             // "\(tableName).\(indexName)"
    var name: String           // "PRIMARY", "idx_email", etc.
    var columns: [String]      // column names in key order
    var unique: Bool           // true when NON_UNIQUE = 0
    var indexType: String      // "BTREE", "HASH", "FULLTEXT"
}

nonisolated struct TableInfo: Identifiable, Hashable {
    var id: String          // "\(alias).\(tableName)"
    var name: String
    var type: TableType
    var alias: String       // which server this belongs to
    var columns: [ColumnInfo] = []  // loaded lazily
    var indexes: [IndexInfo] = []   // loaded lazily
}
