// SimMirror — captures the macOS Simulator app's window and serves it as
// an MJPEG stream over HTTP. Used by the Testing Agent backend to mirror
// the iOS simulator into the web UI in real time.
//
// Architecture:
//   1. ScreenCaptureKit (macOS 12.3+) lists windows and captures the
//      Simulator window directly — no Quartz screencapture-loop hack,
//      no full-display capture, no permissions beyond ScreenCapture.
//   2. Each captured frame is JPEG-encoded via ImageIO (no third-party
//      deps) at the requested quality and width.
//   3. A tiny HTTP server (Foundation Network) hands the encoded
//      frames out as `multipart/x-mixed-replace; boundary=frame` so
//      browsers render it directly through `<img src="...">`.
//
// Usage:
//   sim-mirror --port 9999 --window-title-substring "iPhone 17 Pro Max"
//   sim-mirror --port 9999 --window-id 12345
//   sim-mirror --port 9999 --pid 12345
//
// The capture loop runs at the requested fps but never exceeds what the
// real frame producer can deliver — ScreenCaptureKit drops frames if the
// consumer is slow, so the HTTP side stays responsive.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - CLI parsing

struct Config {
    var port: UInt16 = 9999
    var fps: Int = 15
    var quality: Float = 0.7
    var maxWidth: Int = 480
    var windowTitleSubstring: String? = nil
    var windowId: CGWindowID? = nil
    var pid: pid_t? = nil
    var verbose: Bool = false
    // Pixels to crop off each side of the captured image BEFORE the
    // resize step. Defaults to zero so the user sees the full Simulator
    // skin (device frame, traffic lights, title with the actual phone
    // model and iOS version) — that information is part of the demo
    // value. Override per-deploy with --crop-top etc. if you need to
    // strip the chrome.
    //
    // Insets are in the captured image's pixel space — for retina
    // captures that's 2x the macOS points the Simulator window reports.
    var cropTop: Int = 0
    var cropBottom: Int = 0
    var cropLeft: Int = 0
    var cropRight: Int = 0
}

func parseArgs() -> Config {
    var c = Config()
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let a = args[i]
        switch a {
        case "--port":
            i += 1
            c.port = UInt16(args[i]) ?? 9999
        case "--fps":
            i += 1
            c.fps = Int(args[i]) ?? 15
        case "--quality":
            i += 1
            c.quality = Float(args[i]) ?? 0.7
        case "--max-width":
            i += 1
            c.maxWidth = Int(args[i]) ?? 480
        case "--crop-top":
            i += 1
            c.cropTop = Int(args[i]) ?? 0
        case "--crop-bottom":
            i += 1
            c.cropBottom = Int(args[i]) ?? 0
        case "--crop-left":
            i += 1
            c.cropLeft = Int(args[i]) ?? 0
        case "--crop-right":
            i += 1
            c.cropRight = Int(args[i]) ?? 0
        case "--window-title-substring":
            i += 1
            c.windowTitleSubstring = args[i]
        case "--window-id":
            i += 1
            c.windowId = CGWindowID(args[i]) ?? nil
        case "--pid":
            i += 1
            c.pid = pid_t(args[i]) ?? nil
        case "-v", "--verbose":
            c.verbose = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write("Unknown argument: \(a)\n".data(using: .utf8)!)
            printUsage()
            exit(2)
        }
        i += 1
    }
    return c
}

func printUsage() {
    let usage = """
    sim-mirror — capture the macOS Simulator window and stream it as MJPEG.

    USAGE:
      sim-mirror [--port 9999] [--fps 15] [--quality 0.7] [--max-width 480]
                 (--window-title-substring "iPhone" | --window-id N | --pid N)

    OPTIONS:
      --port                  HTTP port to serve MJPEG on (default: 9999)
      --fps                   Target capture frame rate (default: 15)
      --quality               JPEG quality 0.0 - 1.0 (default: 0.7)
      --max-width             Resize captured frame width to this many px (default: 480)
      --window-title-substring  Match the first window whose title contains this string
      --window-id             Match by exact CGWindowID
      --pid                   Match the first window owned by this process id
      -v, --verbose           Verbose logging to stderr
      -h, --help              Show this help

    ENDPOINTS:
      GET  /                  Same as /stream.mjpg
      GET  /stream.mjpg       multipart/x-mixed-replace MJPEG stream
      GET  /health            Returns "ok" if a frame has been captured recently
      GET  /snapshot.jpg      Single most recent frame as a static JPEG
    """
    print(usage)
}

// MARK: - Logging

final class Logger {
    let verbose: Bool
    init(verbose: Bool) { self.verbose = verbose }
    func info(_ msg: String) {
        FileHandle.standardError.write("[sim-mirror] \(msg)\n".data(using: .utf8)!)
    }
    func debug(_ msg: String) {
        guard verbose else { return }
        FileHandle.standardError.write("[sim-mirror] \(msg)\n".data(using: .utf8)!)
    }
}

// MARK: - JPEG encoding

/// Crop a CGImage by pixel insets. Returns the original if the insets are
/// zero or invalid (negative dimensions). Insets are in CGImage pixel space.
func cropCGImage(_ image: CGImage, top: Int, bottom: Int, left: Int, right: Int) -> CGImage {
    if top <= 0 && bottom <= 0 && left <= 0 && right <= 0 {
        return image
    }
    let newWidth = image.width - left - right
    let newHeight = image.height - top - bottom
    if newWidth <= 0 || newHeight <= 0 {
        return image
    }
    let rect = CGRect(x: left, y: top, width: newWidth, height: newHeight)
    return image.cropping(to: rect) ?? image
}

func encodeJPEG(_ image: CGImage, quality: Float, maxWidth: Int) -> Data? {
    let scaled: CGImage
    if image.width > maxWidth {
        let scale = Double(maxWidth) / Double(image.width)
        let newWidth = maxWidth
        let newHeight = Int(Double(image.height) * scale)
        guard let ctx = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let resized = ctx.makeImage() else { return nil }
        scaled = resized
    } else {
        scaled = image
    }

    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        return nil
    }
    let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// MARK: - Frame buffer (single-slot, latest-wins)

actor FrameStore {
    private var latest: Data? = nil
    private var lastUpdate: Date = .distantPast
    private var subscribers: [UUID: AsyncStream<Data>.Continuation] = [:]

    func update(_ data: Data) {
        latest = data
        lastUpdate = Date()
        for (_, cont) in subscribers {
            cont.yield(data)
        }
    }

    func currentFrame() -> Data? { latest }

    func ageSeconds() -> TimeInterval { Date().timeIntervalSince(lastUpdate) }

    func subscribe() -> (UUID, AsyncStream<Data>) {
        let id = UUID()
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { cont in
            continuation = cont
        }
        subscribers[id] = continuation
        // Push the latest frame immediately so the new client gets a
        // first paint without waiting for the next capture tick.
        if let l = latest { continuation.yield(l) }
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers.removeValue(forKey: id)
    }
}

// MARK: - ScreenCaptureKit capture

@available(macOS 12.3, *)
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let store: FrameStore
    private let logger: Logger
    private let config: Config
    private var stream: SCStream?

    init(store: FrameStore, logger: Logger, config: Config) {
        self.store = store
        self.logger = logger
        self.config = config
    }

    func start() async throws {
        // onScreenWindowsOnly: false → also include windows on other
        // Spaces and minimized windows. We need this because demo users
        // often Cmd-Tab away from the simulator while looking at the
        // browser, putting it in another Space or minimizing it.
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        if config.verbose {
            logger.debug("SCShareableContent saw \(content.windows.count) windows, \(content.applications.count) apps")
            let sims = content.applications.filter { $0.applicationName.lowercased().contains("simulator") }
            for app in sims {
                logger.debug("  Simulator app: pid=\(app.processID) name=\"\(app.applicationName)\" bundle=\(app.bundleIdentifier)")
            }
            for w in content.windows.prefix(60) {
                let title = w.title ?? "(no title)"
                let app = w.owningApplication?.applicationName ?? "(no app)"
                let pid = w.owningApplication?.processID ?? -1
                logger.debug("  - id=\(w.windowID) pid=\(pid) app=\"\(app)\" title=\"\(title)\" frame=\(Int(w.frame.width))x\(Int(w.frame.height))")
            }
        }
        guard let window = pickWindow(from: content.windows) else {
            throw NSError(
                domain: "SimMirror",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No matching window found (\(content.windows.count) windows scanned)"]
            )
        }
        logger.info("Capturing window: title=\"\(window.title ?? "")\" id=\(window.windowID) size=\(Int(window.frame.width))x\(Int(window.frame.height))")

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(window.frame.width * 2)  // retina
        cfg.height = Int(window.frame.height * 2)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        cfg.queueDepth = 3
        cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        do {
            try await stream?.stopCapture()
        } catch {
            logger.info("stopCapture error: \(error)")
        }
    }

    private func pickWindow(from windows: [SCWindow]) -> SCWindow? {
        // Filter out chrome (windows without owners, tiny windows, our
        // own helper windows). The Simulator app's actual phone window
        // has the title "iPhone XX (...)".
        let candidates = windows.filter { w in
            let title = w.title ?? ""
            let appName = w.owningApplication?.applicationName ?? ""
            return !title.isEmpty
                && w.frame.width > 100
                && w.frame.height > 100
                && (appName == "Simulator"
                    || appName.lowercased().contains("simulator"))
        }

        if let id = config.windowId,
           let match = windows.first(where: { $0.windowID == id }) {
            return match
        }
        if let pid = config.pid,
           let match = candidates.first(where: { $0.owningApplication?.processID == pid }) {
            return match
        }
        if let needle = config.windowTitleSubstring {
            if let match = candidates.first(where: { ($0.title ?? "").contains(needle) }) {
                return match
            }
        }
        // Default: any Simulator window
        return candidates.first
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let cropped = cropCGImage(
            cgImage,
            top: config.cropTop,
            bottom: config.cropBottom,
            left: config.cropLeft,
            right: config.cropRight
        )

        guard let jpeg = encodeJPEG(cropped, quality: config.quality, maxWidth: config.maxWidth) else { return }

        Task { await store.update(jpeg) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.info("stream stopped with error: \(error)")
    }
}

// MARK: - HTTP server

final class MJPEGServer {
    private let store: FrameStore
    private let logger: Logger
    private let port: UInt16
    private var listenerSocket: Int32 = -1
    private var running = true

    init(store: FrameStore, logger: Logger, port: UInt16) {
        self.store = store
        self.logger = logger
        self.port = port
    }

    func start() throws {
        listenerSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard listenerSocket >= 0 else {
            throw NSError(domain: "SimMirror", code: 10, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }
        var yes: Int32 = 1
        setsockopt(listenerSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: "SimMirror", code: 11, userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(String(cString: strerror(errno)))"])
        }
        guard listen(listenerSocket, 32) == 0 else {
            throw NSError(domain: "SimMirror", code: 12, userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        logger.info("HTTP server listening on 0.0.0.0:\(port)")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            while self.running {
                var clientAddr = sockaddr()
                var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                let clientSocket = accept(self.listenerSocket, &clientAddr, &clientLen)
                if clientSocket < 0 {
                    if self.running { self.logger.debug("accept() failed") }
                    continue
                }
                Task.detached { [weak self] in
                    await self?.handle(clientSocket: clientSocket)
                }
            }
        }
    }

    func stop() {
        running = false
        close(listenerSocket)
    }

    private func handle(clientSocket: Int32) async {
        defer { close(clientSocket) }

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(clientSocket, &buf, buf.count, 0)
        guard n > 0 else { return }
        let request = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let path = String(parts[1])

        switch path {
        case "/", "/stream.mjpg":
            await serveMJPEG(clientSocket: clientSocket)
        case "/health":
            await serveHealth(clientSocket: clientSocket)
        case "/snapshot.jpg":
            await serveSnapshot(clientSocket: clientSocket)
        default:
            sendString(clientSocket, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        }
    }

    private func serveMJPEG(clientSocket: Int32) async {
        let header = """
        HTTP/1.1 200 OK\r
        Cache-Control: no-cache, no-store, must-revalidate\r
        Pragma: no-cache\r
        Access-Control-Allow-Origin: *\r
        Content-Type: multipart/x-mixed-replace; boundary=frame\r
        \r

        """
        sendString(clientSocket, header)

        let (id, stream) = await store.subscribe()
        defer { Task { await store.unsubscribe(id) } }

        for await frame in stream {
            let part = """
            --frame\r
            Content-Type: image/jpeg\r
            Content-Length: \(frame.count)\r
            \r

            """
            if !sendString(clientSocket, part) { break }
            if !sendData(clientSocket, frame) { break }
            if !sendString(clientSocket, "\r\n") { break }
        }
    }

    private func serveHealth(clientSocket: Int32) async {
        let age = await store.ageSeconds()
        let body = age < 5.0 ? "ok" : "stale"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain\r
        Content-Length: \(body.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        \r
        \(body)
        """
        sendString(clientSocket, response)
    }

    private func serveSnapshot(clientSocket: Int32) async {
        guard let frame = await store.currentFrame() else {
            sendString(clientSocket, "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
            return
        }
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: image/jpeg\r
        Content-Length: \(frame.count)\r
        Cache-Control: no-cache\r
        Access-Control-Allow-Origin: *\r
        \r

        """
        sendString(clientSocket, header)
        _ = sendData(clientSocket, frame)
    }

    @discardableResult
    private func sendString(_ socket: Int32, _ s: String) -> Bool {
        guard let data = s.data(using: .utf8) else { return false }
        return sendData(socket, data)
    }

    private func sendData(_ socket: Int32, _ data: Data) -> Bool {
        var sent = 0
        let total = data.count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < total {
                let n = send(socket, base.advanced(by: sent), total - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

// MARK: - main

// CoreGraphics requires WindowServer initialization. Plain command-line
// binaries don't get this for free — we have to instantiate NSApplication
// before any CG window/image call, or ImageIO crashes with
// "Assertion failed: (did_initialize), function CGS_REQUIRE_INIT".
// We must NOT call setActivationPolicy(.accessory) — that's been observed
// to make ScreenCaptureKit return an empty window list because the
// process becomes invisible to the WindowServer's "shareable content"
// query.
_ = NSApplication.shared

let config = parseArgs()
let logger = Logger(verbose: config.verbose)

if config.windowTitleSubstring == nil && config.windowId == nil && config.pid == nil {
    logger.info("No window selector given — defaulting to first Simulator window.")
}

guard #available(macOS 12.3, *) else {
    logger.info("ScreenCaptureKit requires macOS 12.3 or later.")
    exit(3)
}

let store = FrameStore()
let capture = WindowCapture(store: store, logger: logger, config: config)
let server = MJPEGServer(store: store, logger: logger, port: config.port)

let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        try await capture.start()
        try server.start()
    } catch {
        logger.info("Startup error: \(error)")
        semaphore.signal()
        exit(1)
    }
}

// Graceful shutdown on SIGINT/SIGTERM
let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSource.setEventHandler {
    logger.info("Shutting down…")
    Task {
        await capture.stop()
        server.stop()
        semaphore.signal()
    }
}
sigSource.resume()
signal(SIGINT, SIG_IGN)

semaphore.wait()
exit(0)
