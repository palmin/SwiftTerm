//
//  KittyGraphicsSnapshot.swift
//  SwiftTerm
//
//  Ported from upstream SwiftTerm (MIT License,
//  Copyright (c) 2019-2026 Miguel de Icaza), adapted to this fork.
//

import Foundation

/// The three Kitty graphics layers relative to cell backgrounds and text.
enum KittyGraphicsRenderLayer: Sendable, Equatable {
    /// Kitty reserves the lower half of the signed z-index range for images
    /// that must stay behind cell backgrounds.
    static let backgroundThreshold = Int32.min / 2

    case belowBackground
    case belowText
    case aboveText

    init(zIndex: Int32) {
        if zIndex < Self.backgroundThreshold {
            self = .belowBackground
        } else if zIndex < 0 {
            self = .belowText
        } else {
            self = .aboveText
        }
    }
}

/// A pixel rectangle in a Kitty graphics image.
public struct KittyGraphicsPixelRect: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A rectangle in protocol pixels (points in ShellFish) or image pixels with a
/// top-left origin, used by the geometry helpers below.
public struct KittyGraphicsRect: Sendable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Resolved screen-cell geometry for a Kitty graphics placement.
public struct KittyGraphicsCellGeometry: Sendable, Hashable {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int

    public init(column: Int, row: Int, columns: Int, rows: Int) {
        self.column = column
        self.row = row
        self.columns = columns
        self.rows = rows
    }
}

/// Immutable decoded image data for a renderer.
public struct KittyGraphicsRenderImage: Sendable, Hashable {
    /// The protocol image ID.
    public let imageId: UInt32
    /// The protocol image number, if the client supplied one.
    public let imageNumber: UInt32?
    /// The image width in pixels.
    public let width: Int
    /// The image height in pixels.
    public let height: Int
    /// Canonical, row-major, straight-alpha RGBA8 pixels.
    ///
    /// An array, not `Data`, so that a snapshot shares the terminal's decoded
    /// pixels by reference. A `Data(...)` conversion here would copy every
    /// pixel of every live image on every frame. The payload is immutable once
    /// decoded, and `contentGeneration` tells a consumer when it changed, so
    /// sharing is safe.
    public let rgba: [UInt8]
    /// A cache generation that changes when the displayed pixels change.
    public let contentGeneration: UInt64

    public init(
        imageId: UInt32,
        imageNumber: UInt32?,
        width: Int,
        height: Int,
        rgba: [UInt8],
        contentGeneration: UInt64
    ) {
        self.imageId = imageId
        self.imageNumber = imageNumber
        self.width = width
        self.height = height
        self.rgba = rgba
        self.contentGeneration = contentGeneration
    }
}

/// Immutable placement geometry for a renderer.
public struct KittyGraphicsRenderPlacement: Sendable, Hashable {
    /// A terminal-assigned stable token. Anonymous placements also have a token.
    public let token: UInt64
    /// The client placement ID, or zero for an anonymous placement.
    public let placementId: UInt32
    /// The image to use for this placement.
    public let imageId: UInt32
    /// The visible source crop in top-row-first image pixels.
    public let visibleSource: KittyGraphicsPixelRect
    /// Destination cells relative to the current viewport.
    public let geometry: KittyGraphicsCellGeometry
    /// The horizontal offset in protocol pixels.
    public let pixelOffsetX: Int
    /// The vertical offset in protocol pixels.
    public let pixelOffsetY: Int
    /// The protocol z-index.
    public let zIndex: Int32
    /// `true` when Unicode placeholder cells control the visible regions.
    public let isVirtual: Bool
    /// A stable order for placements that have the same z-index.
    public let insertionOrder: UInt64
    /// The scroll-invariant row of the anchor cell, `buffer.linesTop` plus the
    /// index into `buffer.lines`, the row space a renderer that lays out the
    /// whole scrollback uses. Meaningless for a virtual placement.
    public let absoluteRow: Int
    /// The column count the client asked for with `c`, or 0 when it gave none.
    public let requestedColumns: Int
    /// The row count the client asked for with `r`, or 0 when it gave none.
    public let requestedRows: Int
    /// Rows of the placement's box that a scroll region cut off above
    /// `geometry.row`. The image keeps the layout it has in the whole box,
    /// and only the `geometry.rows` rows left show.
    public let clipTopRows: Int
    /// Rows of the placement's box that a scroll region cut off below its last row.
    public let clipBottomRows: Int

    public init(
        token: UInt64,
        placementId: UInt32,
        imageId: UInt32,
        visibleSource: KittyGraphicsPixelRect,
        geometry: KittyGraphicsCellGeometry,
        pixelOffsetX: Int,
        pixelOffsetY: Int,
        zIndex: Int32,
        isVirtual: Bool,
        insertionOrder: UInt64,
        absoluteRow: Int = 0,
        requestedColumns: Int = 0,
        requestedRows: Int = 0,
        clipTopRows: Int = 0,
        clipBottomRows: Int = 0
    ) {
        self.token = token
        self.placementId = placementId
        self.imageId = imageId
        self.visibleSource = visibleSource
        self.geometry = geometry
        self.pixelOffsetX = pixelOffsetX
        self.pixelOffsetY = pixelOffsetY
        self.zIndex = zIndex
        self.isVirtual = isVirtual
        self.insertionOrder = insertionOrder
        self.absoluteRow = absoluteRow
        self.requestedColumns = requestedColumns
        self.requestedRows = requestedRows
        self.clipTopRows = clipTopRows
        self.clipBottomRows = clipBottomRows
    }

    /// The `columns x rows` cell box of a real placement that shows, relative
    /// to the top left corner of its anchor cell. A renderer clips the image to it.
    public func cellBox(cellWidth: Double, cellHeight: Double) -> KittyGraphicsRect {
        KittyGraphicsRect(x: 0, y: 0,
                          width: Double(geometry.columns) * cellWidth,
                          height: Double(geometry.rows) * cellHeight)
    }

    /// The whole box the image was given, relative to the top left corner of
    /// the anchor cell, including the rows a scroll region cut off above and
    /// below `cellBox`. A renderer fits the image to this box and clips it to
    /// `cellBox`; without a cut the two are the same.
    public func layoutBox(cellWidth: Double, cellHeight: Double) -> KittyGraphicsRect {
        KittyGraphicsRect(x: 0, y: -Double(clipTopRows) * cellHeight,
                          width: Double(geometry.columns) * cellWidth,
                          height: Double(clipTopRows + geometry.rows + clipBottomRows) * cellHeight)
    }

    /// Where `visibleSource` lands for a real placement, relative to the top
    /// left corner of its anchor cell, following the spec's sizing rules: the
    /// natural size when neither `c` nor `r` was given, the other side from
    /// the aspect ratio when one was given, and fitted and centred
    /// (letterboxed) in the box when both were given. The pixel offsets move
    /// the image right and down, and rows a scroll region cut off above the
    /// anchor cell move it up. Clip the result to `cellBox`.
    public func destination(cellWidth: Double, cellHeight: Double) -> KittyGraphicsRect {
        let offsetX = Double(pixelOffsetX)
        let offsetY = Double(pixelOffsetY)
        // the rows cut off above move the whole layout up, the box keeps its size
        let top = offsetY - Double(clipTopRows) * cellHeight
        let sourceWidth = Double(max(1, visibleSource.width))
        let sourceHeight = Double(max(1, visibleSource.height))
        let boxWidth = max(0, Double(requestedColumns) * cellWidth - offsetX)
        let boxHeight = max(0, Double(requestedRows) * cellHeight - offsetY)
        switch (requestedColumns > 0, requestedRows > 0) {
        case (false, false):
            return KittyGraphicsRect(x: offsetX, y: top, width: sourceWidth, height: sourceHeight)
        case (true, false):
            return KittyGraphicsRect(x: offsetX, y: top,
                                     width: boxWidth, height: boxWidth * sourceHeight / sourceWidth)
        case (false, true):
            return KittyGraphicsRect(x: offsetX, y: top,
                                     width: boxHeight * sourceWidth / sourceHeight, height: boxHeight)
        case (true, true):
            let scale = min(boxWidth / sourceWidth, boxHeight / sourceHeight)
            let width = sourceWidth * scale
            let height = sourceHeight * scale
            return KittyGraphicsRect(x: offsetX + (boxWidth - width) / 2,
                                     y: top + (boxHeight - height) / 2,
                                     width: width, height: height)
        }
    }
}

/// Immutable Kitty graphics renderer input.
public struct KittyGraphicsRenderSnapshot: Sendable, Hashable {
    /// A cache generation that changes after a storage or placement mutation.
    public let storageGeneration: UInt64
    /// The stored images for the active screen, keyed by image ID.
    public let imagesById: [UInt32: KittyGraphicsRenderImage]
    /// Placements sorted by z-index and insertion order.
    public let placements: [KittyGraphicsRenderPlacement]

    public init(
        storageGeneration: UInt64,
        imagesById: [UInt32: KittyGraphicsRenderImage],
        placements: [KittyGraphicsRenderPlacement]
    ) {
        self.storageGeneration = storageGeneration
        self.imagesById = imagesById
        self.placements = placements
    }
}
