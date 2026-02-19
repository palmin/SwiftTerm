//
//  Terminal+KittyKeyboard.swift
//  SwiftTerm
//
//  Kitty keyboard protocol support.
//  https://sw.kovidgoyal.net/kitty/keyboard-protocol/
//

import Foundation

extension Terminal {

    // MARK: - CSI u dispatch

    // CSI u is overloaded: plain CSI u is SCORC (restore cursor), while
    // CSI with >, <, ?, = collect prefix is the kitty keyboard protocol.
    func csiUHandler(_ pars: [Int], _ collect: cstring) {
        guard collect.count == 1 else {
            // no collect prefix → standard restore cursor
            cmdRestoreCursor(pars, collect)
            return
        }

        switch collect[0] {
        case UInt8(ascii: ">"): // push current flags, then set new flags
            cmdKittyKeyboardPush(pars)
        case UInt8(ascii: "<"): // pop flags from stack
            cmdKittyKeyboardPop(pars)
        case UInt8(ascii: "?"): // query current flags
            cmdKittyKeyboardQuery()
        case UInt8(ascii: "="): // set flags with mode
            cmdKittyKeyboardSet(pars)
        default:
            log("Kitty: unknown CSI collect=\(collect) u")
        }
    }

    // MARK: - Protocol mode management

    // CSI > flags u — push current flags, then set new flags
    func cmdKittyKeyboardPush(_ pars: [Int]) {
#if DEBUG || TESTFLIGHT
        let flags = UInt(pars.first ?? 0)
        if kittyKeyboardStack.count >= Terminal.kittyKeyboardMaxStack {
            kittyKeyboardStack.removeFirst()
        }
        kittyKeyboardStack.append(kittyKeyboardFlags)
        kittyKeyboardFlags = flags
        log("Kitty: push flags=\(flags), stack depth=\(kittyKeyboardStack.count)")
#endif
    }

    // CSI < number u — pop number entries from stack
    func cmdKittyKeyboardPop(_ pars: [Int]) {
#if DEBUG || TESTFLIGHT
        let count = max(pars.first ?? 1, 1)
        for _ in 0..<count {
            if kittyKeyboardStack.isEmpty {
                kittyKeyboardFlags = 0
                break
            }
            kittyKeyboardFlags = kittyKeyboardStack.removeLast()
        }
        log("Kitty: pop flags=\(kittyKeyboardFlags), stack depth=\(kittyKeyboardStack.count)")
#endif
    }

    // CSI ? u — query current flags, respond with CSI ? flags u
    func cmdKittyKeyboardQuery() {
#if DEBUG || TESTFLIGHT
        log("Kitty: query, responding with flags=\(kittyKeyboardFlags)")
        sendResponse(cc.CSI, "?\(kittyKeyboardFlags)u")
#else
        // in production we report 0 (no kitty support)
        sendResponse(cc.CSI, "?0u")
#endif
    }

    // CSI = flags ; mode u — set flags with mode
    //   mode 1 (default): set all flags to value
    //   mode 2: set only the bits in flags
    //   mode 3: clear only the bits in flags
    func cmdKittyKeyboardSet(_ pars: [Int]) {
#if DEBUG || TESTFLIGHT
        let flags = UInt(pars.first ?? 0)
        let mode = pars.count > 1 ? pars[1] : 1
        switch mode {
        case 1:
            kittyKeyboardFlags = flags
        case 2:
            kittyKeyboardFlags |= flags
        case 3:
            kittyKeyboardFlags &= ~flags
        default:
            kittyKeyboardFlags = flags
        }
        log("Kitty: set flags=\(kittyKeyboardFlags) mode=\(mode)")
#endif
    }

    // CSI > Pp ; Pv m — xterm modifyOtherKeys
    // we silently consume this rather than treating it as SGR
    func cmdModifyOtherKeys(_ pars: [Int], _ collect: cstring) {
        // intentionally ignored: the kitty keyboard protocol supersedes this
        log("Kitty: modifyOtherKeys \(pars) (ignored)")
    }

    // MARK: - Flag convenience properties

    public var kittyDisambiguate: Bool { kittyKeyboardFlags & 1 != 0 }
    public var kittyReportEvents: Bool { kittyKeyboardFlags & 2 != 0 }
    public var kittyReportAlternateKeys: Bool { kittyKeyboardFlags & 4 != 0 }
    public var kittyReportAllKeys: Bool { kittyKeyboardFlags & 8 != 0 }
    public var kittyReportAssociatedText: Bool { kittyKeyboardFlags & 16 != 0 }

    // MARK: - Static encoding helpers

    // these are used by the UI layer to compose key event data
    // in the CSI u format when kittyKeyboardFlags is non-zero.
    // they are static so they can be called without a Terminal instance.

    /// Encodes a keyboard event as a CSI u sequence.
    ///
    /// Full format: CSI keycode:shifted:base-layout ; modifiers:event-type ; text-codepoints u
    ///
    /// - Parameters:
    ///   - keyCode: unicode codepoint for the key (e.g. 97 for 'a', 13 for Enter)
    ///   - modifiers: kitty modifier value (1 + modifier bits: shift=1, alt=2, ctrl=4, super=8)
    ///   - eventType: 1=press, 2=repeat, 3=release. 0 or 1 are omitted from output.
    ///   - flags: the active kittyKeyboardFlags
    ///   - shiftedKey: codepoint of the shifted version (0 to omit)
    ///   - baseLayoutKey: codepoint in base keyboard layout (0 to omit)
    ///   - text: the text produced by the key, encoded as codepoints in the third parameter
    /// - Returns: the escape sequence string to send
    public static func kittyKeySequence(keyCode: Int, modifiers: Int = 1, eventType: Int = 1, flags: UInt = 0,
                                        shiftedKey: Int = 0, baseLayoutKey: Int = 0, text: String? = nil) -> String {
        // key code with alternate key sub-parameters
        var keyPart = "\(keyCode)"
        if flags & 4 != 0, shiftedKey > 0 || baseLayoutKey > 0 {
            keyPart += ":\(shiftedKey > 0 ? "\(shiftedKey)" : "")"
            if baseLayoutKey > 0 {
                keyPart += ":\(baseLayoutKey)"
            }
        }

        // associated text as colon-separated codepoints, filtering control codes
        var textCPs = ""
        if flags & 16 != 0, let text = text {
            textCPs = text.unicodeScalars
                .filter { $0.value >= 0x20 }
                .map { "\($0.value)" }
                .joined(separator: ":")
        }

        let reportEvents = flags & 2 != 0
        let hasModifiers = modifiers > 1
        let hasEventType = reportEvents && eventType > 1
        let hasText = !textCPs.isEmpty

        if hasModifiers || hasEventType || hasText {
            var modPart = "\(modifiers)"
            if hasEventType {
                modPart += ":\(eventType)"
            }
            if hasText {
                return "\u{1B}[\(keyPart);\(modPart);\(textCPs)u"
            }
            return "\u{1B}[\(keyPart);\(modPart)u"
        }

        // text but no modifiers or event type — empty modifier field
        if hasText {
            return "\u{1B}[\(keyPart);;\(textCPs)u"
        }

        return "\u{1B}[\(keyPart)u"
    }

    /// Encodes a functional key using legacy CSI number ~ format with kitty modifier encoding.
    /// For Insert, Delete, PgUp, PgDn, F5-F12.
    public static func kittyFunctionalKeySequence(number: Int, modifiers: Int = 1, eventType: Int = 1, flags: UInt = 0) -> String {
        let reportEvents = flags & 2 != 0
        let hasModifiers = modifiers > 1
        let hasEventType = reportEvents && eventType > 1
        if hasModifiers || hasEventType {
            var modField = "\(modifiers)"
            if hasEventType {
                modField += ":\(eventType)"
            }
            return "\u{1B}[\(number);\(modField)~"
        }

        return "\u{1B}[\(number)~"
    }

    /// Encodes a special key that uses letter-final CSI sequences (arrows, Home, End, F1-F4).
    public static func kittySpecialKeySequence(letter: Character, modifiers: Int = 1, eventType: Int = 1, flags: UInt = 0) -> String {
        let reportEvents = flags & 2 != 0
        let hasModifiers = modifiers > 1
        let hasEventType = reportEvents && eventType > 1
        if hasModifiers || hasEventType {
            var modField = "\(modifiers)"
            if hasEventType {
                modField += ":\(eventType)"
            }
            return "\u{1B}[1;\(modField)\(letter)"
        }

        // no modifiers, no event type — use legacy encoding
        return "\u{1B}[\(letter)"
    }
}
