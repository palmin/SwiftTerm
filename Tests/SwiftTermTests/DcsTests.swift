//
//  DcsTests.swift
//
//  Regression coverage for DCS handling: unrecognized Device Control Strings
//  must be swallowed (not printed), and XTGETTCAP (DCS + q) must be answered.
//

import Foundation
import XCTest

@testable import SwiftTerm

final class DcsTests: XCTestCase {

    // captures bytes the terminal sends back to the host (responses)
    final class CapturingDelegate: TerminalDelegate {
        var response: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) {
            response.append(contentsOf: data)
        }
    }

    private func makeTerminal() -> (Terminal, CapturingDelegate) {
        let delegate = CapturingDelegate()
        let terminal = Terminal(delegate: delegate)
        return (terminal, delegate)
    }

    private func firstLine(_ terminal: Terminal) -> String {
        return terminal.buffer.translateBufferLineToString(lineIndex: 0, trimRight: true)
    }

    private func responseString(_ delegate: CapturingDelegate) -> String {
        return String(bytes: delegate.response, encoding: .ascii) ?? ""
    }

    // XTGETTCAP query for "Ms" (hex 4D73) must not spill onto the screen and
    // must be answered with the OSC 52 set-selection capability value.
    func testXtgettcapMsIsAnsweredAndNotPrinted() {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\u{1b}P+q4D73\u{1b}\\")

        XCTAssertFalse(firstLine(terminal).contains("4D73"), "XTGETTCAP payload leaked to screen")

        // \E]52;%p1%s;%p2%s\007 hex-encoded, prefixed with "1+r4D73="
        let msHex = "1B5D35323B2570312573" + "3B2570322573" + "07"
        XCTAssertTrue(responseString(delegate).contains("1+r4D73=" + msHex),
                      "expected Ms capability value, got: \(responseString(delegate))")
    }

    // "Co" (colors, hex 436F) is numeric and reported as 256.
    func testXtgettcapColorsReportsValue() {
        let (terminal, delegate) = makeTerminal()
        terminal.feed(text: "\u{1b}P+q436F\u{1b}\\")

        XCTAssertFalse(firstLine(terminal).contains("436F"))
        // "256" -> 323536
        XCTAssertTrue(responseString(delegate).contains("1+r436F=323536"),
                      "got: \(responseString(delegate))")
    }

    // an unsupported capability must be reported invalid with the 0+r form.
    func testXtgettcapUnknownReportsInvalid() {
        let (terminal, delegate) = makeTerminal()
        // "ZZ" -> 5A5A, not a capability we advertise
        terminal.feed(text: "\u{1b}P+q5A5A\u{1b}\\")

        XCTAssertFalse(firstLine(terminal).contains("5A5A"))
        XCTAssertTrue(responseString(delegate).contains("0+r5A5A"),
                      "got: \(responseString(delegate))")
    }

    // a DCS with a completely unregistered selector must have its body
    // swallowed up to ST, not printed as text (the reported bug).
    func testUnknownDcsSelectorIsSwallowed() {
        let (terminal, _) = makeTerminal()
        // \eP z junk123 \e\\  -- 'z' has no handler
        terminal.feed(text: "before\u{1b}Pzjunk123\u{1b}\\after")

        let line = firstLine(terminal)
        XCTAssertFalse(line.contains("junk123"), "unknown DCS body leaked: \(line)")
        // surrounding printable text is unaffected
        XCTAssertTrue(line.contains("before"))
        XCTAssertTrue(line.contains("after"))
    }

    // multiple capabilities in one query are answered individually.
    func testXtgettcapMultipleCaps() {
        let (terminal, delegate) = makeTerminal()
        // 436F ("Co") ; 5A5A ("ZZ")
        terminal.feed(text: "\u{1b}P+q436F;5A5A\u{1b}\\")

        let response = responseString(delegate)
        XCTAssertTrue(response.contains("1+r436F=323536"), "got: \(response)")
        XCTAssertTrue(response.contains("0+r5A5A"), "got: \(response)")
    }

    static var allTests = [
        ("testXtgettcapMsIsAnsweredAndNotPrinted", testXtgettcapMsIsAnsweredAndNotPrinted),
        ("testXtgettcapColorsReportsValue", testXtgettcapColorsReportsValue),
        ("testXtgettcapUnknownReportsInvalid", testXtgettcapUnknownReportsInvalid),
        ("testUnknownDcsSelectorIsSwallowed", testUnknownDcsSelectorIsSwallowed),
        ("testXtgettcapMultipleCaps", testXtgettcapMultipleCaps),
    ]
}
