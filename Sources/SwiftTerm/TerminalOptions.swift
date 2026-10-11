//
//  TerminalOptions.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 2/29/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Foundation

/// Configuration option for the desired cursor style, this style can also be overwritten by the application
/// inside the terminal, and the UI control can choose to honor this request.
public enum CursorStyle {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkingBar
    case steadyBar
}

/// Configuration for the kitty graphics protocol, which is enabled unless the
/// storage limit is zero.
///
/// Only direct (`t=d`) transmission is accepted. The client runs on the remote
/// host, so the file, temporary file or shared memory name in a `t=f`, `t=t` or
/// `t=s` transmission names something on that host; those are always refused
/// and nothing local is read or deleted.
public struct KittyGraphicsConfiguration: Sendable, Equatable {
    /// The default per-screen limit, 64 MB of decoded RGBA, which holds a few
    /// full-screen Retina screenshots
    public static let defaultStorageLimitBytesPerScreen: UInt32 = 64 << 20

    /// Maximum decoded bytes stored on each screen; the primary and alternate
    /// screens have separate budgets. Zero disables the protocol, including
    /// query replies.
    public var storageLimitBytesPerScreen: UInt32

    public init(storageLimitBytesPerScreen: UInt32 = KittyGraphicsConfiguration.defaultStorageLimitBytesPerScreen) {
        self.storageLimitBytesPerScreen = storageLimitBytesPerScreen
    }
}

/// Configuration options for the terminal at startup, these values are only read at startup
public struct TerminalOptions {
    /// Desired number of columns at startup (default 80)
    public var cols: Int
    /// Desired number of rows at startup (default 25)
    public var rows: Int
    /// Controls whether a Line-Feed character will also behave like a carriage return (true) or not (false).  defaults to true)
    public var convertEol: Bool
    /// Desired value for the terminal name, defaults to xterm-color
    public var termName: String
    /// The desired startup cursor style, this merely sets an internal variable, it is the view job to render it
    public var cursorStyle: CursorStyle
    /// Deprecated?   The new accessibility work will make this useless
    public var screenReaderMode: Bool
    /// Size of the scrollback buffer, defaults to 500 lines
    public var scrollback: Int
    /// Default size of the tabs, defaults to 8
    public var tabStopWidth: Int
    /// Name and version reported in reply to XTVERSION (CSI > q), for example
    /// "ShellFish 1.2.3".  Terminal multiplexers and some applications use this
    /// to recognise the terminal and enable features for it.  Defaults to nil,
    /// which leaves the query unanswered.
    public var xtversion: String?
    /// Kitty graphics protocol storage limit per screen, enabled by default
    public var kittyGraphics: KittyGraphicsConfiguration

    /// Default options
    public static let `default` = TerminalOptions.init(cols: 80,
                                                       rows: 25,
                                                       convertEol: true,
                                                       termName: "xterm-color",
                                                       cursorStyle: .blinkBlock,
                                                       screenReaderMode: false,
                                                       scrollback: 500,
                                                       tabStopWidth: 8,
                                                       xtversion: nil,
                                                       kittyGraphics: KittyGraphicsConfiguration())

  public init(cols: Int = Self.default.cols, rows: Int = Self.default.rows, convertEol: Bool = Self.default.convertEol, termName: String = Self.default.termName, cursorStyle: CursorStyle = Self.default.cursorStyle, screenReaderMode: Bool = Self.default.screenReaderMode, scrollback: Int = Self.default.scrollback, tabStopWidth: Int = Self.default.tabStopWidth, xtversion: String? = Self.default.xtversion, kittyGraphics: KittyGraphicsConfiguration = Self.default.kittyGraphics) {
        self.cols = cols
        self.rows = rows
        self.convertEol = convertEol
        self.termName = termName
        self.cursorStyle = cursorStyle
        self.screenReaderMode = screenReaderMode
        self.scrollback = scrollback
        self.tabStopWidth = tabStopWidth
        self.xtversion = xtversion
        self.kittyGraphics = kittyGraphics
    }
}
