//
//  Connection.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/24/26.
//

import Foundation
import SwiftUI

nonisolated enum ConnectionType: String, Codable, CaseIterable {
    case tcpip  = "TCP/IP"
    case ssh    = "SSH"
    case socket = "Socket"

    // Forward-compatible decoding: an unknown transport from a newer build falls
    // back to TCP/IP rather than throwing and taking the whole saved list with it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConnectionType(rawValue: raw) ?? .tcpip
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct Connection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var alias: String
    var connectionType: ConnectionType = .tcpip
    var engine: DatabaseEngine = .mysql
    var color: String = "#4A90D9"
    var folder: String = ""   // optional home-screen group; "" = ungrouped

    // TCP/IP + SSH (MySQL endpoint)
    var host: String = ""
    var port: Int = 3306
    var username: String = ""
    var database: String = ""

    // SSH tunnel fields
    var sshHost: String = ""
    var sshPort: Int = 22
    var sshUsername: String = ""
    var sshKeyPath: String = ""

    // Socket field
    var socketPath: String = "/tmp/mysql.sock"

    // SSL — defaults false so older saved connections continue to work
    var useSSL: Bool = false

    // Read-only / safe mode — when on, SequelBridge refuses any write (INSERT/UPDATE/
    // DELETE/DDL/…) to this connection, so a prod server can't be changed by accident.
    // Defaults false so older saved connections keep behaving exactly as before.
    var readOnly: Bool = false

    // Explicit memberwise init so callers don't need to specify every field
    init(id: UUID = UUID(), name: String, alias: String,
         connectionType: ConnectionType = .tcpip, color: String = "#4A90D9",
         host: String = "", port: Int = 3306, username: String = "", database: String = "",
         sshHost: String = "", sshPort: Int = 22, sshUsername: String = "", sshKeyPath: String = "",
         socketPath: String = "/tmp/mysql.sock", useSSL: Bool = false,
         engine: DatabaseEngine = .mysql, folder: String = "", readOnly: Bool = false) {
        self.id = id; self.name = name; self.alias = alias
        self.connectionType = connectionType; self.color = color
        self.folder = folder
        self.host = host; self.port = port; self.username = username; self.database = database
        self.sshHost = sshHost; self.sshPort = sshPort
        self.sshUsername = sshUsername; self.sshKeyPath = sshKeyPath
        self.socketPath = socketPath; self.useSSL = useSSL
        self.engine = engine
        self.readOnly = readOnly
    }

    // Custom decoder so connections saved before useSSL was added still load correctly
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,           forKey: .id)
        name           = try c.decode(String.self,         forKey: .name)
        alias          = try c.decode(String.self,         forKey: .alias)
        connectionType = try c.decode(ConnectionType.self, forKey: .connectionType)
        // Absent for connections saved before multi-engine support; those are MySQL.
        engine         = try c.decodeIfPresent(DatabaseEngine.self, forKey: .engine) ?? .mysql
        color          = try c.decode(String.self,         forKey: .color)
        host           = try c.decode(String.self,         forKey: .host)
        port           = try c.decode(Int.self,            forKey: .port)
        username       = try c.decode(String.self,         forKey: .username)
        database       = try c.decode(String.self,         forKey: .database)
        sshHost        = try c.decodeIfPresent(String.self, forKey: .sshHost)     ?? ""
        sshPort        = try c.decodeIfPresent(Int.self,    forKey: .sshPort)     ?? 22
        sshUsername    = try c.decodeIfPresent(String.self, forKey: .sshUsername) ?? ""
        sshKeyPath     = try c.decodeIfPresent(String.self, forKey: .sshKeyPath)  ?? ""
        socketPath     = try c.decodeIfPresent(String.self, forKey: .socketPath)  ?? "/tmp/mysql.sock"
        useSSL         = try c.decodeIfPresent(Bool.self,   forKey: .useSSL)      ?? false
        folder         = try c.decodeIfPresent(String.self, forKey: .folder)      ?? ""
        readOnly       = try c.decodeIfPresent(Bool.self,   forKey: .readOnly)    ?? false
    }

    var displayColor: Color {
        Color(hex: color) ?? .blue
    }

    var displayHost: String {
        if engine == .sqlite {
            return database.isEmpty ? "—" : (database as NSString).lastPathComponent
        }
        switch connectionType {
        case .tcpip:  return host.isEmpty ? "—" : "\(host):\(port)"
        case .ssh:    return sshHost.isEmpty ? "—" : "SSH → \(host)"
        case .socket: return socketPath
        }
    }
}

nonisolated extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
