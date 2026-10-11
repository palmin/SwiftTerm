//
//  KittyPlaceholder.swift
//  SwiftTerm
//
//  Ported from upstream SwiftTerm (MIT License,
//  Copyright (c) 2019-2026 Miguel de Icaza), adapted to this fork.
//
//  Kitty graphics Unicode placeholders: a virtual placement (`U=1`) is shown
//  wherever the client prints U+10EEEE. The foreground colour carries the image
//  id, the underline colour the placement id, and up to three diacritics give
//  the image row, the image column and the most significant byte of the id.
//

import Foundation

struct KittyPlaceholderCell {
    let row: Int
    let col: Int
    let imageId: UInt32
    let placementId: UInt32
    let placeholderRow: Int
    let placeholderCol: Int
    let msb: Int
}

enum KittyPlaceholderDecoder {
    /// Decodes one cell. `underlineColor` is the cell's underline colour (SGR 58),
    /// which carries the placement id; `Attribute` only holds an index into the
    /// terminal's table, so callers resolve it with `Terminal.kittyUnderlineColor(of:)`.
    static func decode(character: Character,
                       attribute: Attribute,
                       row: Int,
                       col: Int,
                       previous: KittyPlaceholderCell?,
                       previousAttribute: Attribute?,
                       underlineColor: Attribute.Color? = nil) -> KittyPlaceholderCell? {
        decode(scalars: character.unicodeScalars.lazy.map(\.value), attribute: attribute,
               row: row, col: col, previous: previous, previousAttribute: previousAttribute,
               underlineColor: underlineColor)
    }

    static func decode<Scalars: Sequence>(scalars: Scalars,
                       attribute: Attribute,
                       row: Int,
                       col: Int,
                       previous: KittyPlaceholderCell?,
                       previousAttribute: Attribute?,
                       underlineColor: Attribute.Color? = nil) -> KittyPlaceholderCell? where Scalars.Element == UInt32 {
        var scalars = scalars.makeIterator()
        guard scalars.next() == KittyPlaceholder.baseScalar else { return nil }
        var count = 0
        var explicitRow: Int?
        var explicitCol: Int?
        var explicitMsb: Int?
        while count < 3, let scalar = scalars.next() {
            guard let index = KittyPlaceholder.diacriticIndex[scalar] else { continue }
            switch count {
            case 0: explicitRow = index
            case 1: explicitCol = index
            default: explicitMsb = index
            }
            count += 1
        }

        let placementId = colorToId(underlineColor) ?? 0
        let sameFg = previousAttribute?.fg == attribute.fg
        // the indices of one terminal's table are equal exactly when the colours are
        let sameUnderline = previousAttribute?.underlineColorIndex == attribute.underlineColorIndex
        let isAdjacent = previous?.row == row && previous?.col == col - 1

        var placeholderRow: Int?
        var placeholderCol: Int?
        var msb = explicitMsb ?? 0

        switch count {
        case 0:
            if let prev = previous, sameFg, sameUnderline, isAdjacent {
                placeholderRow = prev.placeholderRow
                placeholderCol = prev.placeholderCol + 1
                msb = prev.msb
            } else {
                placeholderRow = 0
                placeholderCol = 0
            }
        case 1:
            placeholderRow = explicitRow
            if let prev = previous, sameFg, sameUnderline, isAdjacent, prev.placeholderRow == placeholderRow {
                placeholderCol = prev.placeholderCol + 1
                msb = prev.msb
            } else {
                placeholderCol = 0
            }
        case 2:
            placeholderRow = explicitRow
            placeholderCol = explicitCol
            if let prev = previous, sameFg, sameUnderline, isAdjacent, prev.placeholderRow == placeholderRow, prev.placeholderCol + 1 == placeholderCol {
                msb = prev.msb
            }
        default:
            placeholderRow = explicitRow
            placeholderCol = explicitCol
        }

        guard let placeholderRow, let placeholderCol else {
            return nil
        }

        guard let imageBaseId = colorToId(attribute.fg) else {
            return nil
        }

        let imageId = imageBaseId | (UInt32(min(msb, 255)) << 24)

        return KittyPlaceholderCell(row: row,
                                    col: col,
                                    imageId: imageId,
                                    placementId: placementId,
                                    placeholderRow: placeholderRow,
                                    placeholderCol: placeholderCol,
                                    msb: msb)
    }

    private static func colorToId(_ color: Attribute.Color?) -> UInt32? {
        guard let color else {
            return nil
        }
        switch color {
        case .ansi256(let code):
            return UInt32(code)
        case .trueColor(let red, let green, let blue):
            return (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
        case .defaultColor, .defaultInvertedColor:
            return 0
        }
    }
}

struct KittyPlaceholderSize: Equatable, Sendable {
    let width: Double
    let height: Double

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

struct KittyPlaceholderRenderPlacement: Equatable {
    let offsetX: Int
    let offsetY: Int
    let sourceX: Int
    let sourceY: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let destWidth: Int
    let destHeight: Int

    static func compute(imageSize: KittyPlaceholderSize,
                        placementCols: Int,
                        placementRows: Int,
                        cellSize: KittyPlaceholderSize,
                        col: Int,
                        row: Int,
                        width: Int,
                        height: Int) -> KittyPlaceholderRenderPlacement? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              placementCols > 0,
              placementRows > 0,
              cellSize.width > 0,
              cellSize.height > 0 else {
            return nil
        }

        let placementWidth = Double(placementCols) * cellSize.width
        let placementHeight = Double(placementRows) * cellSize.height
        let scale = min(placementWidth / imageSize.width, placementHeight / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let imageOffsetX = (placementWidth - scaledWidth) / 2
        let imageOffsetY = (placementHeight - scaledHeight) / 2

        let runX = Double(col) * cellSize.width
        let runY = Double(row) * cellSize.height
        let runWidth = Double(width) * cellSize.width
        let runHeight = Double(height) * cellSize.height

        let destLeft = max(runX, imageOffsetX)
        let destTop = max(runY, imageOffsetY)
        let destRight = min(runX + runWidth, imageOffsetX + scaledWidth)
        let destBottom = min(runY + runHeight, imageOffsetY + scaledHeight)

        let destWidth = destRight - destLeft
        let destHeight = destBottom - destTop
        if destWidth <= 0 || destHeight <= 0 {
            return nil
        }

        let offsetX = destLeft - runX
        let offsetY = destTop - runY
        let sourceX = (destLeft - imageOffsetX) / scale
        let sourceY = (destTop - imageOffsetY) / scale
        let sourceWidth = destWidth / scale
        let sourceHeight = destHeight / scale

        func roundInt(_ value: Double) -> Int {
            Int(value.rounded())
        }

        return KittyPlaceholderRenderPlacement(offsetX: roundInt(offsetX),
                                               offsetY: roundInt(offsetY),
                                               sourceX: roundInt(sourceX),
                                               sourceY: roundInt(sourceY),
                                               sourceWidth: roundInt(sourceWidth),
                                               sourceHeight: roundInt(sourceHeight),
                                               destWidth: roundInt(destWidth),
                                               destHeight: roundInt(destHeight))
    }
}

enum KittyPlaceholder {
    static let baseScalar: UInt32 = 0x10EEEE

    /// True for U+10EEEE, with or without diacritics.
    static func isPlaceholder(_ character: Character) -> Bool {
        character.unicodeScalars.first?.value == baseScalar
    }
    // kitty's rowcolumn-diacritics.txt in order; the index is the encoded value
    static let diacritics: [UInt32] = [
        0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A,
        0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365,
        0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F,
        0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
        0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1, 0x05A8, 0x05A9,
        0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
        0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6,
        0x06D7, 0x06D8, 0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
        0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736,
        0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743, 0x0745, 0x0747, 0x0749, 0x074A,
        0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817,
        0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
        0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951,
        0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD,
        0x193A, 0x1A17, 0x1A75, 0x1A76, 0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C,
        0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
        0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4, 0x1DC5, 0x1DC6,
        0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
        0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF,
        0x1DE0, 0x1DE1, 0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
        0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0,
        0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2, 0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6,
        0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0,
        0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
        0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1,
        0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9,
        0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED, 0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2,
        0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
        0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187, 0x1D188, 0x1D189,
        0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
    ]
    static let diacriticIndex: [UInt32: Int] = {
        var map: [UInt32: Int] = [:]
        for (idx, scalar) in KittyPlaceholder.diacritics.enumerated() {
            map[scalar] = idx
        }
        return map
    }()
}

// MARK: - per-line scanning for renderers

/// A horizontal run of placeholder cells on one buffer line that show adjacent
/// slices of one image row.
public struct KittyPlaceholderRun: Sendable, Hashable {
    /// The screen column of the first cell.
    public let column: Int
    /// The number of cells in the run.
    public let width: Int
    /// The image id, including the most significant byte from the third diacritic.
    public let imageId: UInt32
    /// The placement id from the underline colour; 0 matches any virtual placement of the image.
    public let placementId: UInt32
    /// The image row (in cells) the run shows.
    public let placeholderRow: Int
    /// The image column (in cells) of the first cell.
    public let placeholderColumn: Int

    public init(column: Int, width: Int, imageId: UInt32, placementId: UInt32,
                placeholderRow: Int, placeholderColumn: Int) {
        self.column = column
        self.width = width
        self.imageId = imageId
        self.placementId = placementId
        self.placeholderRow = placeholderRow
        self.placeholderColumn = placeholderColumn
    }
}

/// Decodes the cells of one line from left to right, carrying the implicit
/// row, column and msb inheritance between neighbouring placeholder cells and
/// merging them into runs. A renderer that walks a line itself passes every
/// cell it visits; anything that is not a placeholder breaks the inheritance.
struct KittyPlaceholderLineScanner {
    let row: Int
    private var previous: KittyPlaceholderCell?
    private var previousAttribute: Attribute?
    private(set) var runs: [KittyPlaceholderRun] = []

    init(row: Int = 0) {
        self.row = row
    }

    /// Decodes one cell of the line, returning it when it is a placeholder
    /// (which a renderer draws as a blank cell keeping its background).
    mutating func scan(_ cell: CharData, column: Int, terminal: Terminal) -> KittyPlaceholderCell? {
        // U+10EEEE needs two UTF-16 units, so a placeholder is always an interned grapheme
        guard cell.code > CharData.maxRune else {
            breakInheritance()
            return nil
        }
        let character = terminal.graphemes.character(for: cell.code)
        // the underline colour is only looked up for a placeholder
        guard KittyPlaceholder.isPlaceholder(character) else {
            breakInheritance()
            return nil
        }
        return scan(character: character,
                    attribute: cell.attribute,
                    underlineColor: terminal.kittyUnderlineColor(of: cell.attribute),
                    column: column)
    }

    /// Decodes one cell given its character, for a caller that already resolved it.
    mutating func scan(character: Character, attribute: Attribute, underlineColor: Attribute.Color?, column: Int) -> KittyPlaceholderCell? {
        guard character.unicodeScalars.first?.value == KittyPlaceholder.baseScalar,
              let cell = KittyPlaceholderDecoder.decode(character: character,
                                                        attribute: attribute,
                                                        row: row,
                                                        col: column,
                                                        previous: previous,
                                                        previousAttribute: previousAttribute,
                                                        underlineColor: underlineColor) else {
            breakInheritance()
            return nil
        }
        previous = cell
        previousAttribute = attribute
        append(cell)
        return cell
    }

    /// Call for a cell that is not passed to `scan`, like ordinary text.
    mutating func breakInheritance() {
        previous = nil
        previousAttribute = nil
    }

    private mutating func append(_ cell: KittyPlaceholderCell) {
        if let last = runs.last,
           last.imageId == cell.imageId,
           last.placementId == cell.placementId,
           last.placeholderRow == cell.placeholderRow,
           last.column + last.width == cell.col,
           last.placeholderColumn + last.width == cell.placeholderCol {
            runs[runs.count - 1] = KittyPlaceholderRun(column: last.column,
                                                       width: last.width + 1,
                                                       imageId: last.imageId,
                                                       placementId: last.placementId,
                                                       placeholderRow: last.placeholderRow,
                                                       placeholderColumn: last.placeholderColumn)
        } else {
            runs.append(KittyPlaceholderRun(column: cell.col,
                                            width: 1,
                                            imageId: cell.imageId,
                                            placementId: cell.placementId,
                                            placeholderRow: cell.placeholderRow,
                                            placeholderColumn: cell.placeholderCol))
        }
    }
}

extension Terminal {
    /// The underline colour of a cell (SGR 58), which carries a placeholder's
    /// placement id; nil, which addresses any virtual placement of the image,
    /// when none is set.
    func kittyUnderlineColor(of attribute: Attribute) -> Attribute.Color? {
        underlineColor(of: attribute)
    }

    /// Returns true when the cell holds a kitty Unicode placeholder (U+10EEEE,
    /// with or without diacritics).
    func isKittyPlaceholder(_ cell: CharData) -> Bool {
        cell.code > CharData.maxRune &&
            graphemes.character(for: cell.code).unicodeScalars.first?.value == KittyPlaceholder.baseScalar
    }

    /// Decodes the placeholder runs of one buffer line. The runs only depend on
    /// the line, so a renderer can cache them with the line's text and resolve
    /// them again whenever the kitty snapshot changes. Call on the terminal's queue.
    public func kittyPlaceholderRuns(in line: BufferLine) -> [KittyPlaceholderRun] {
        var scanner = KittyPlaceholderLineScanner()
        let count = min(cols, line.count)
        var col = 0
        while col < count {
            let cell = line[col]
            _ = scanner.scan(cell, column: col, terminal: self)
            col += max(1, Int(cell.width))
        }
        return scanner.runs
    }
}

/// The part of a virtual placement that one placeholder run shows.
public struct KittyPlaceholderSlice: Sendable, Hashable {
    /// The image to draw.
    public let imageId: UInt32
    /// The token of the virtual placement the run resolved to.
    public let token: UInt64
    /// The insertion order of that placement, for stacking.
    public let insertionOrder: UInt64
    /// The part of the image shown, in image pixels.
    public let source: KittyGraphicsRect
    /// Where it lands in protocol pixels, relative to the top left corner of
    /// the run's first cell and already clipped to the run.
    public let destination: KittyGraphicsRect
}

extension KittyGraphicsRenderSnapshot {
    /// The virtual placements grouped by image id, in snapshot order. Build it
    /// once per snapshot and pass it to `resolve`.
    public func virtualPlacementsByImageId() -> [UInt32: [KittyGraphicsRenderPlacement]] {
        Dictionary(grouping: placements.filter(\.isVirtual), by: \.imageId)
    }

    /// Resolves one placeholder run: the first virtual placement of the image
    /// that matches its placement id and covers its image row and column; the
    /// visible source is fitted and centred in the placement's cell box, moved
    /// by the pixel offsets and clipped to the run. Returns nil when nothing of
    /// the image falls in the run.
    public func resolve(_ run: KittyPlaceholderRun,
                        virtualPlacements: [UInt32: [KittyGraphicsRenderPlacement]],
                        cellWidth: Double,
                        cellHeight: Double) -> KittyPlaceholderSlice? {
        guard cellWidth > 0, cellHeight > 0, run.width > 0,
              let record = virtualPlacements[run.imageId]?.first(where: {
                  (run.placementId == 0 || $0.placementId == run.placementId) &&
                  $0.geometry.columns > run.placeholderColumn &&
                  $0.geometry.rows > run.placeholderRow
              }), imagesById[record.imageId] != nil else { return nil }
        let source = record.visibleSource
        guard source.width > 0, source.height > 0 else { return nil }
        let boxWidth = Double(record.geometry.columns) * cellWidth
        let boxHeight = Double(record.geometry.rows) * cellHeight
        let scale = min(boxWidth / Double(source.width), boxHeight / Double(source.height))
        guard scale > 0, scale.isFinite else { return nil }
        let fitWidth = Double(source.width) * scale
        let fitHeight = Double(source.height) * scale
        // the fitted image and the run in the placement's own space, whose origin is its top left cell
        let imageX = Double(record.pixelOffsetX) + (boxWidth - fitWidth) / 2
        let imageY = Double(record.pixelOffsetY) + (boxHeight - fitHeight) / 2
        let runX = Double(run.placeholderColumn) * cellWidth
        let runY = Double(run.placeholderRow) * cellHeight
        // cells past the placement's last column show nothing
        let runRight = min(runX + Double(run.width) * cellWidth, boxWidth)
        let left = max(runX, imageX)
        let top = max(runY, imageY)
        let right = min(runRight, imageX + fitWidth)
        let bottom = min(runY + cellHeight, imageY + fitHeight)
        guard right > left, bottom > top else { return nil }
        return KittyPlaceholderSlice(
            imageId: record.imageId,
            token: record.token,
            insertionOrder: record.insertionOrder,
            source: KittyGraphicsRect(x: Double(source.x) + (left - imageX) / scale,
                                      y: Double(source.y) + (top - imageY) / scale,
                                      width: (right - left) / scale,
                                      height: (bottom - top) / scale),
            destination: KittyGraphicsRect(x: left - runX, y: top - runY,
                                           width: right - left, height: bottom - top))
    }
}

// MARK: - per-cell resolution of the visible screen (upstream's portable resolver)

/// A rectangle in top-row-first pixel coordinates.
public struct TerminalKittyPlaceholderRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

/// The visible part of a virtual image in one terminal cell.
public struct TerminalKittyPlaceholderPlacement: Sendable, Equatable {
    public let imageId: UInt32
    public let token: UInt64
    public let insertionOrder: UInt64
    public let source: TerminalKittyPlaceholderRect
    public let destination: TerminalKittyPlaceholderRect
}

extension Terminal {
    /// Resolve visible Unicode placeholders and crop aspect-fit virtual images
    /// to their cells. Call on the terminal's queue, with a snapshot taken there
    /// so image and text state agree.
    public func visibleKittyPlaceholderPlacements(
        snapshot: KittyGraphicsRenderSnapshot, cellWidth: Int, cellHeight: Int
    ) -> [TerminalKittyPlaceholderPlacement] {
        guard cellWidth > 0, cellHeight > 0 else { return [] }
        let records = snapshot.virtualPlacementsByImageId()
        guard !records.isEmpty else { return [] }
        let cw = Double(cellWidth), ch = Double(cellHeight)
        let display = buffer
        var result: [TerminalKittyPlaceholderPlacement] = []
        for row in 0..<rows {
            let index = display.yDisp + row
            guard index >= 0, index < display.lines.count else { continue }
            let line = display.lines[index]
            var scanner = KittyPlaceholderLineScanner(row: row)
            for col in 0..<min(cols, line.count) {
                guard let placeholder = scanner.scan(line[col], column: col, terminal: self),
                      let record = records[placeholder.imageId]?.first(where: {
                          (placeholder.placementId == 0 || $0.placementId == placeholder.placementId) &&
                          $0.geometry.columns > placeholder.placeholderCol &&
                          $0.geometry.rows > placeholder.placeholderRow
                      }), snapshot.imagesById[record.imageId] != nil else { continue }
                let source = record.visibleSource
                guard source.width > 0, source.height > 0 else { continue }
                let width = Double(record.geometry.columns) * cw
                let height = Double(record.geometry.rows) * ch
                let scale = min(width / Double(source.width), height / Double(source.height))
                guard scale > 0, scale.isFinite else { continue }
                let fitWidth = Double(source.width) * scale
                let fitHeight = Double(source.height) * scale
                let x = Double(col - placeholder.placeholderCol) * cw + Double(record.pixelOffsetX) + (width - fitWidth) / 2
                let y = Double(row - placeholder.placeholderRow) * ch + Double(record.pixelOffsetY) + (height - fitHeight) / 2
                let left = max(Double(col) * cw, x)
                let top = max(Double(row) * ch, y)
                let right = min(Double(col + 1) * cw, x + fitWidth)
                let bottom = min(Double(row + 1) * ch, y + fitHeight)
                guard right > left, bottom > top else { continue }
                result.append(TerminalKittyPlaceholderPlacement(
                    imageId: record.imageId, token: record.token, insertionOrder: record.insertionOrder,
                    source: TerminalKittyPlaceholderRect(
                        x: Double(source.x) + (left - x) / scale,
                        y: Double(source.y) + (top - y) / scale,
                        width: (right - left) / scale, height: (bottom - top) / scale),
                    destination: TerminalKittyPlaceholderRect(x: left, y: top, width: right - left, height: bottom - top)))
            }
        }
        return result
    }
}
