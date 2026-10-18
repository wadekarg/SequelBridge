//
//  ConnectionErrorTests.swift
//  SequelBridgeTests
//
//  A failed connection now carries the driver's own reason (wrong password, SSL required
//  but not offered) instead of "Connection query failed". Both drivers put the whole
//  connection string in that message, password included; the app must show the reason
//  and never the password, on screen or in its log. Messages below are the drivers'
//  real wording, recorded from MariaDB 10.0 and PostgreSQL 16.
//

import Foundation
import Testing
import DuckDB
@testable import SequelBridge

@MainActor
@Suite("Connection errors: the driver's reason, never the password")
struct ConnectionErrorTests {
    private let mysqlSSL = #"IO Error: Failed to connect to MySQL database with parameters "host=127.0.0.1 port=3309 user=root password=s3cret database=sbtest ssl_mode=required": TLS/SSL error: SSL is required, but the server does not support it. Attempted host: 127.0.0.1"#
    private let mysqlDenied = #"IO Error: Failed to connect to MySQL database with parameters "host=127.0.0.1 port=3309 user=root password=WRONG database=sbtest": Access denied for user 'root'@'localhost' (using password: YES). Attempted host: 127.0.0.1"#
    private let pgSSL = #"IO Error: Unable to connect to Postgres at "host=127.0.0.1 port=5433 user=sbuser password=s3cret dbname=sbtest sslmode=require": connection to server at "127.0.0.1", port 5433 failed: server does not support SSL, but SSL was required"#

    @Test("MySQL: the reason stays, the connection string and password go")
    func mysql() {
        let ssl = QueryEngine.connectionError(mysqlSSL, password: "s3cret")
        #expect(ssl == "TLS/SSL error: SSL is required, but the server does not support it. Attempted host: 127.0.0.1")
        let denied = QueryEngine.connectionError(mysqlDenied, password: "WRONG")
        #expect(denied.hasPrefix("Access denied for user 'root'"))
        #expect(!denied.contains("WRONG"))
    }

    @Test("PostgreSQL: the reason stays, the connection string and password go")
    func postgres() {
        let ssl = QueryEngine.connectionError(pgSSL, password: "s3cret")
        #expect(ssl.hasSuffix("server does not support SSL, but SSL was required"))
        #expect(!ssl.contains("s3cret"))
        #expect(!ssl.contains("dbname="))
    }

    @Test("a password anywhere else in a message is hidden too, whatever its characters")
    func anywhere() {
        #expect(!QueryEngine.connectionError("reconnect with p@ss w0rd'x failed", password: "p@ss w0rd'x").contains("w0rd"))
        #expect(!QueryEngine.connectionError("bad key password=abc123 in DSN", password: "").contains("abc123"))
        #expect(!QueryEngine.connectionError("bad key passwd=abc123 in DSN", password: "").contains("abc123"))
    }

    @Test("every engine error shown in the app has passwords hidden")
    func extractReasonRedacts() {
        let error = DatabaseError.connectionQueryError(reason: pgSSL)
        #expect(!QueryEngine.extractReason(from: error).contains("s3cret"))
    }
}
