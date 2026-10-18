//
//  BlobDecodingTests.swift
//  SequelBridgeTests
//

import Foundation
import Testing
@testable import SequelBridge

@Suite("BLOB display decoding")
struct BlobDecodingTests {

    @Test("UTF-8 text comes back as text, not hex")
    func textDecodes() {
        #expect(QueryEngine.decodeBlob(Data("customers".utf8)) == "customers")
    }

    @Test("a MySQL column type decodes to something ColumnEdit can parse")
    func columnTypeDecodes() {
        #expect(QueryEngine.decodeBlob(Data("varchar(255)".utf8)) == "varchar(255)")
    }

    @Test("non-UTF-8 bytes stay hex")
    func binaryStaysHex() {
        #expect(QueryEngine.decodeBlob(Data([0xFF, 0xFE, 0x80])) == "fffe80")
    }

    @Test("a PNG header stays hex")
    func pngStaysHex() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(QueryEngine.decodeBlob(png) == "89504e470d0a1a0a")
    }

    @Test("control bytes mean binary even when they are valid UTF-8")
    func controlBytesStayHex() {
        // 0x00 and 0x01 are valid UTF-8 scalars, so a plain decode would accept them.
        #expect(QueryEngine.decodeBlob(Data([0x00, 0x01])) == "0001")
    }

    @Test("tabs and newlines are legitimate text")
    func whitespaceIsText() {
        #expect(QueryEngine.decodeBlob(Data("a\tb\nc".utf8)) == "a\tb\nc")
    }

    @Test("empty data renders as an empty string")
    func emptyData() {
        #expect(QueryEngine.decodeBlob(Data()) == "")
    }

    @Test("multi-byte UTF-8 survives")
    func multiByteText() {
        #expect(QueryEngine.decodeBlob(Data("naïve_café".utf8)) == "naïve_café")
    }
}
