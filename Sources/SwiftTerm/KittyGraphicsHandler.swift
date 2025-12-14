//
//  KittyGraphicsHandler.swift
//  SwiftTerm
//
//  Kitty graphics protocol implementation
//  Protocol spec: https://sw.kovidgoyal.net/kitty/graphics-protocol/
//

import Foundation
import CoreGraphics
#if canImport(Compression)
import Compression
#endif
#if canImport(zlib)
import zlib
#endif

/// Handles Kitty graphics protocol APC sequences
/// Format: ESC _ G <control>;<payload> ESC \
class KittyGraphicsHandler: ApcHandler {
    weak var terminal: Terminal?

    // accumulated data across chunks
    private var accumulatedPayload: [UInt8] = []
    private var controlData: [String: String] = [:]
    private var isChunked = false

    private func log(_ message: String) {
#if DEBUG
        print("[KittyGraphics] \(message)")
#endif
    }

    public init(terminal: Terminal) {
        self.terminal = terminal
        log("Handler initialized")
    }

    func hook() {
#if DEBUG
        print("[KittyGraphics] HANDLER hook() ENTRY")
#endif
        // for chunked transfers, don't reset - we're continuing
        if isChunked {
            log("hook() called - continuing chunked transfer (payload so far: \(accumulatedPayload.count) bytes)")
            return
        }

        log("hook() called - starting new APC sequence")
        // reset state for new sequence
        accumulatedPayload = []
        controlData = [:]
    }

    func put(data: ArraySlice<UInt8>) {
        // data format: <control>;<payload>
        // control is key=value pairs separated by commas
        // payload is base64 encoded
        print("[KittyGraphics] HANDLER put() ENTRY - \(data.count) bytes") // unconditional for debugging
        log("put() called with \(data.count) bytes: \(String(bytes: data.prefix(80), encoding: .utf8) ?? "?")")

        guard let str = String(bytes: data, encoding: .utf8) else {
            log("put() ERROR: failed to decode data as UTF-8")
            return
        }

        // split on first semicolon to separate control from payload
        let parts = str.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        log("put() split into \(parts.count) parts")

        // always parse control data if present (may update m= for chunked transfers)
        let controlStr = parts.count > 0 ? String(parts[0]) : ""
        if !controlStr.isEmpty {
            log("put() parsing control: '\(controlStr)'")
            // clear 'm' before parsing - if new chunk doesn't include m, it means m=0 (final)
            controlData.removeValue(forKey: "m")
            parseControlData(controlStr)
            log("put() controlData = \(controlData)")
        }

        // append payload (everything after the semicolon)
        if parts.count > 1 {
            let payloadStr = String(parts[1])
            accumulatedPayload.append(contentsOf: payloadStr.utf8)
            log("put() payload part: '\(payloadStr.prefix(40))...' (\(payloadStr.count) bytes, total: \(accumulatedPayload.count))")
        } else {
            log("put() no payload in this chunk")
        }
    }

    func unhook() {
        print("[KittyGraphics] HANDLER unhook() ENTRY - controlData: \(controlData)") // unconditional for debugging
        log("unhook() called - controlData: \(controlData), payload size: \(accumulatedPayload.count)")

        // check if this is a continuation chunk
        let moreChunks = controlData["m"] == "1"

        if moreChunks {
            // more data coming, store state
            log("unhook() more chunks expected (m=1), waiting...")
            isChunked = true
            return
        }

        // process completed transmission
        log("unhook() processing command...")
        processCommand()

        // reset state
        accumulatedPayload = []
        controlData = [:]
        isChunked = false
        log("unhook() complete, state reset")
    }

    // MARK: - Control Data Parsing

    private func parseControlData(_ str: String) {
        // format: key=value,key=value,...
        let pairs = str.split(separator: ",")
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                controlData[String(kv[0])] = String(kv[1])
            } else if kv.count == 1 {
                controlData[String(kv[0])] = ""
            }
        }
    }

    // MARK: - Command Processing

    private func processCommand() {
        let action = controlData["a"] ?? "t" // default is transmit
#if DEBUG
        print("[KittyGraphics] HANDLER processCommand() - action='\(action)', all controlData=\(controlData)")
#endif
        log("processCommand() action='\(action)'")

        switch action {
        case "t": // transmit only (store image)
            log("processCommand() transmit only")
            transmitImage(display: false)
        case "T": // transmit and display
            log("processCommand() transmit and display")
            transmitImage(display: true)
        case "p": // display (place) previously transmitted image
            log("processCommand() place image")
            displayImage()
        case "d": // delete image
            log("processCommand() delete image")
            deleteImage()
        case "q": // query
            log("processCommand() query")
            handleQuery()
        default:
            log("processCommand() unknown action: \(action)")
            sendErrorResponse("ENOTSUPPORTED:unknown action '\(action)'")
        }
    }

    // MARK: - Image Transmission

    private func transmitImage(display: Bool) {
        log("transmitImage(display: \(display)) starting")

        guard let terminal = terminal else {
            log("transmitImage() ERROR: terminal is nil")
            return
        }

        // decode base64 payload
        let payloadString = String(bytes: accumulatedPayload, encoding: .utf8) ?? ""
        log("transmitImage() payload string length: \(payloadString.count)")

        // determine transmission type
        let transmissionType = controlData["t"] ?? "d" // default is direct
        log("transmitImage() transmission type: \(transmissionType)")

        var imageData: Data

        switch transmissionType {
        case "d": // direct - payload is base64-encoded image data
            log("transmitImage() base64 first 50 chars: '\(String(payloadString.prefix(50)))'")
            log("transmitImage() base64 last 50 chars: '\(String(payloadString.suffix(50)))'")
            log("transmitImage() base64 length mod 4: \(payloadString.count % 4)")

            // try to decode - if it fails, try padding
            var base64ToTry = payloadString
            let padding = (4 - (payloadString.count % 4)) % 4
            if padding > 0 {
                base64ToTry += String(repeating: "=", count: padding)
                log("transmitImage() added \(padding) padding chars")
            }

            guard let decoded = Data(base64Encoded: base64ToTry, options: .ignoreUnknownCharacters) else {
                log("transmitImage() ERROR: invalid base64 even with padding")
                sendErrorResponse("EBADDATA:invalid base64")
                return
            }
            imageData = decoded
            log("transmitImage() decoded \(imageData.count) bytes from base64")

        case "f", "t": // file or temp file - payload is base64-encoded file path
            guard let pathData = Data(base64Encoded: payloadString, options: .ignoreUnknownCharacters),
                  let filePath = String(data: pathData, encoding: .utf8) else {
                log("transmitImage() ERROR: invalid file path encoding")
                sendErrorResponse("EBADDATA:invalid file path")
                return
            }
            log("transmitImage() reading from file: \(filePath)")

            do {
                imageData = try Data(contentsOf: URL(fileURLWithPath: filePath))
                log("transmitImage() read \(imageData.count) bytes from file")
            } catch {
                log("transmitImage() ERROR: failed to read file: \(error)")
                sendErrorResponse("ENOENT:file not found")
                return
            }

        case "s": // shared memory - not supported on iOS
            log("transmitImage() ERROR: shared memory not supported")
            sendErrorResponse("ENOTSUPPORTED:shared memory")
            return

        default:
            log("transmitImage() ERROR: unknown transmission type: \(transmissionType)")
            sendErrorResponse("ENOTSUPPORTED:transmission type \(transmissionType)")
            return
        }

        log("transmitImage() have \(imageData.count) bytes of image data")

        var processedData = imageData

        // handle compression
        if controlData["o"] == "z" {
            log("transmitImage() decompressing zlib data...")
            guard let decompressed = decompressZlib(imageData) else {
                log("transmitImage() ERROR: zlib decompression failed")
                sendErrorResponse("EBADDATA:zlib decompression failed")
                return
            }
            processedData = decompressed
            log("transmitImage() decompressed to \(processedData.count) bytes")
        }

        // determine image format
        let format = Int(controlData["f"] ?? "32") ?? 32
        log("transmitImage() format=\(format)")

        var image: TTImage?

        switch format {
        case 100: // PNG
            log("transmitImage() creating image from PNG")
            image = createImageFromPNG(processedData)
        case 24: // RGB (3 bytes per pixel)
            log("transmitImage() creating image from RGB")
            image = createImageFromRaw(processedData, hasAlpha: false)
        case 32: // RGBA (4 bytes per pixel)
            log("transmitImage() creating image from RGBA")
            image = createImageFromRaw(processedData, hasAlpha: true)
        default:
            log("transmitImage() ERROR: unsupported format \(format)")
            sendErrorResponse("ENOTSUPPORTED:format \(format)")
            return
        }

        guard let finalImage = image else {
            log("transmitImage() ERROR: failed to create image")
            sendErrorResponse("EBADDATA:failed to create image")
            return
        }
        log("transmitImage() image created successfully: \(finalImage)")

        // get image ID for storage
        let imageId = UInt32(controlData["i"] ?? "0") ?? 0
        log("transmitImage() imageId=\(imageId)")

        // store image if ID provided
        if imageId > 0 {
            terminal.storeKittyImage(id: imageId, image: finalImage)
            log("transmitImage() stored image with id \(imageId)")
        }

        // display if requested
        if display {
            log("transmitImage() displaying image...")
            displayImageWithOptions(finalImage)
        }

        // send success response
        if controlData["q"] != "1" { // q=1 means quiet mode
            log("transmitImage() sending OK response")
            sendOKResponse(imageId: imageId)
        }
        log("transmitImage() complete")
    }

    private func displayImage() {
        guard let terminal = terminal else { return }

        let imageId = UInt32(controlData["i"] ?? "0") ?? 0

        guard imageId > 0, let image = terminal.getKittyImage(id: imageId) else {
            sendErrorResponse("ENOENT:image not found")
            return
        }

        displayImageWithOptions(image)

        if controlData["q"] != "1" {
            sendOKResponse(imageId: imageId)
        }
    }

    private func displayImageWithOptions(_ image: TTImage) {
        guard let terminal = terminal else { return }

        // get display options
        let columns = Int(controlData["c"] ?? "0") ?? 0
        let rows = Int(controlData["r"] ?? "0") ?? 0

        let cell = ImageCell(image)

        // set cell dimensions if specified
        if columns > 0 {
            cell.width = columns
        }
        if rows > 0 {
            cell.height = rows
        }

        terminal.image(cell)
    }

    private func deleteImage() {
        guard let terminal = terminal else { return }

        let deleteWhat = controlData["d"] ?? "a"
        let imageId = UInt32(controlData["i"] ?? "0") ?? 0

        switch deleteWhat {
        case "a", "A": // delete all images
            terminal.deleteAllKittyImages()
        case "i", "I": // delete by image ID
            if imageId > 0 {
                terminal.deleteKittyImage(id: imageId)
            }
        default:
            // other delete modes not yet supported
            break
        }

        if controlData["q"] != "1" {
            sendOKResponse(imageId: imageId)
        }
    }

    // MARK: - Query Handling

    private func handleQuery() {
        // respond that we support the protocol
        let imageId = UInt32(controlData["i"] ?? "0") ?? 0
#if DEBUG
        NSLog("[KittyGraphics] HANDLER handleQuery() - sending OK for imageId=%u", imageId)
#endif
        log("handleQuery() sending OK for imageId=\(imageId)")
        sendOKResponse(imageId: imageId)
    }

    // MARK: - Response Helpers

    private func sendOKResponse(imageId: UInt32) {
        guard let terminal = terminal else {
#if DEBUG
            NSLog("[KittyGraphics] HANDLER sendOKResponse() - terminal is nil!")
#endif
            return
        }

        // format: ESC _ G i=<id>;OK ESC \
        var response = "\u{1b}_Gi=\(imageId);OK\u{1b}\\"
        if imageId == 0 {
            response = "\u{1b}_GOK\u{1b}\\"
        }
#if DEBUG
        NSLog("[KittyGraphics] HANDLER sendOKResponse() - sending: %@", response.debugDescription)
#endif
        terminal.sendResponse(text: response)
    }

    private func sendErrorResponse(_ error: String) {
        guard let terminal = terminal else { return }

        // format: ESC _ G i=<id>;<error> ESC \
        let imageId = UInt32(controlData["i"] ?? "0") ?? 0
        let response = "\u{1b}_Gi=\(imageId);\(error)\u{1b}\\"
        terminal.sendResponse(text: response)
    }

    // MARK: - Image Creation

    private func createImageFromPNG(_ data: Data) -> TTImage? {
#if os(iOS) || os(tvOS) || os(visionOS)
        return UIImage(data: data)
#elseif os(macOS)
        return NSImage(data: data)
#else
        return nil
#endif
    }

    private func createImageFromRaw(_ data: Data, hasAlpha: Bool) -> TTImage? {
        // get dimensions from control data
        guard let width = Int(controlData["s"] ?? "0"), width > 0,
              let height = Int(controlData["v"] ?? "0"), height > 0 else {
            return nil
        }

        let bytesPerPixel = hasAlpha ? 4 : 3
        let expectedSize = width * height * bytesPerPixel

        guard data.count >= expectedSize else {
            return nil
        }

        // convert to RGBA if needed
        var rgbaData: [UInt8]
        if hasAlpha {
            rgbaData = [UInt8](data.prefix(expectedSize))
        } else {
            // convert RGB to RGBA
            rgbaData = [UInt8](repeating: 0, count: width * height * 4)
            var srcIdx = 0
            var dstIdx = 0
            for _ in 0..<(width * height) {
                rgbaData[dstIdx] = data[srcIdx]
                rgbaData[dstIdx + 1] = data[srcIdx + 1]
                rgbaData[dstIdx + 2] = data[srcIdx + 2]
                rgbaData[dstIdx + 3] = 255 // opaque alpha
                srcIdx += 3
                dstIdx += 4
            }
        }

        // create CGImage
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(rgbaData) as CFData) else {
            return nil
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: rgbColorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }

#if os(iOS) || os(tvOS) || os(visionOS)
        return UIImage(cgImage: cgImage)
#elseif os(macOS)
return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
#else
        return nil
#endif
    }

    // MARK: - Compression

    private func decompressZlib(_ data: Data) -> Data? {
#if canImport(Compression)
        // use Apple's Compression framework
        let bufferSize = data.count * 4 // estimate decompressed size
        var decompressed = Data(count: bufferSize)

        let result = decompressed.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    destPtr.bindMemory(to: UInt8.self).baseAddress!,
                    bufferSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard result > 0 else {
            return nil
        }

        decompressed.count = result
        return decompressed
#elseif canImport(zlib)
        // fallback: try using zlib directly
        return decompressZlibFallback(data)
#else
        return nil
#endif
    }

#if canImport(zlib)
    private func decompressZlibFallback(_ data: Data) -> Data? {
        // simple zlib decompression using Foundation
        // this handles RFC 1950 zlib format
        guard data.count > 2 else { return nil }

        // check zlib header
        let header = data[0]
        guard (header & 0x0F) == 8 else { return nil } // deflate method

        // allocate output buffer (estimate 4x compression ratio)
        var destLen = uLongf(data.count * 4)
        var dest = [UInt8](repeating: 0, count: Int(destLen))

        let result = data.withUnsafeBytes { srcPtr -> Int32 in
            uncompress(&dest, &destLen,
                      srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                      uLongf(data.count))
        }

        guard result == Z_OK else {
            return nil
        }

        return Data(dest.prefix(Int(destLen)))
    }
#endif
}
