import CoreGraphics
import Foundation
import Observation

/// One conversation's desktop on this device: a Mac's own screen or a Box
/// display. It opens the desktop, relays RFB through the backend's WebSocket
/// and turns gestures into pointer and key events. It starts watching; input
/// only goes out after Take over, which the relay also enforces.
@Observable
final class DesktopSession {
    enum Phase: Equatable {
        case connecting
        case signIn(failed: Bool)
        case live
        case failed(String)
    }

    enum Button: UInt8 { case left = 1, middle = 2, right = 4 }

    let teamId: String
    let sessionId: String
    private let token: String

    private(set) var phase = Phase.connecting
    /// The remote screen in pixels.
    private(set) var screenSize = CGSize.zero
    private(set) var controlling = false
    /// The display the runtime gave this session; a Mac's own screen is always 0.
    private(set) var display: Int?
    /// Debug builds show where time goes: the last update's size and how long
    /// it took after being asked for, and how much has arrived unread.
    private(set) var stats = ""
    var isMacScreen: Bool { display == 0 }
    /// Modifiers tapped on the key row, held for the next key or click.
    private(set) var latched: [UInt32] = []

    /// The pointer in screen pixels, pushed to the canvas rather than observed:
    /// it changes at touch rate.
    @ObservationIgnored private(set) var pointer = CGPoint.zero
    /// The latest picture and pointer shape, for a canvas made after they
    /// arrived: the server only sends what changes.
    @ObservationIgnored private(set) var lastFrame: CGImage?
    @ObservationIgnored private(set) var lastCursor: RFBCursor?
    @ObservationIgnored var onFrame: ((CGImage) -> Void)?
    @ObservationIgnored var onCursor: ((RFBCursor) -> Void)?
    @ObservationIgnored var onPointer: ((CGPoint) -> Void)?
    /// The part of the screen the canvas shows, in pixels; the trackpad's speed follows it.
    @ObservationIgnored var visibleRect = CGRect.zero

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var buttons: UInt8 = 0
    @ObservationIgnored private var movePending = false
    @ObservationIgnored private var wheel = CGSize.zero
    @ObservationIgnored private var keyQueue: [(keysym: UInt32, down: Bool)] = []
    @ObservationIgnored private var typing = false
    @ObservationIgnored private var accountRequest: CheckedContinuation<(user: String, password: String), Error>?
    @ObservationIgnored private let frames = FrameMailbox()

    /// Mac accounts the screen accepted, for this app run only: never written anywhere.
    private static var accounts: [String: (user: String, password: String)] = [:]
    static func forgetAccounts() { accounts = [:] }

    init(teamId: String, sessionId: String, token: String) {
        self.teamId = teamId
        self.sessionId = sessionId
        self.token = token
        frames.show = { [weak self] image in self?.show(image) }
    }

    private func show(_ image: CGImage) {
        let size = CGSize(width: image.width, height: image.height)
        if screenSize != size { screenSize = size } // The remote screen changed resolution.
        lastFrame = image
        onFrame?(image)
    }

    // MARK: - Connection

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    /// Closing the stream also hands the desktop back to the agent.
    func stop() {
        runTask?.cancel()
        runTask = nil
        accountRequest?.resume(throwing: CancellationError())
        accountRequest = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        ready = false
        controlling = false
        latched = []
    }

    private func run() async {
        var failures = 0
        var signInFailed = false
        while !Task.isCancelled {
            phase = .connecting
            let started = Date()
            do {
                try await connect(signInFailed: signInFailed)
                signInFailed = false
            } catch RFBClient.Failure.signInFailed {
                Self.accounts[sessionId] = nil
                signInFailed = true
                continue
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                if Date().timeIntervalSince(started) > 10 { failures = 0 }
                failures += 1
                if failures > 6 || error is RFBClient.Failure || error is OpenFailure {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
            ready = false
            controlling = false
            try? await Task.sleep(for: .seconds(min(15, 1 << max(0, failures - 1))))
        }
    }

    /// Asks the runtime again after a failure the user can fix, such as Screen Sharing turned off.
    func retry() {
        stop()
        start()
    }

    private func connect(signInFailed: Bool) async throws {
        let display = try await Self.open(token: token, teamId: teamId, sessionId: sessionId)
        self.display = display
        var components = URLComponents(url: NuphosAPI.baseURL.appending(path: "teams/\(teamId)/runtime-desktop/\(sessionId)/\(display)"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AccountAPI.aiConsentVersion, forHTTPHeaderField: "x-nuphos-ai-consent-version")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        self.socket = socket
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        let (chunks, input) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        let received = ByteCount()
        let receiver = Task.detached {
            do {
                while true {
                    guard case .string(let text) = try await socket.receive() else { continue }
                    guard let data = Data(base64Encoded: text) else { throw RFBClient.Failure.unexpected("frame") }
                    received.add(data.count)
                    input.yield(Array(data))
                }
            } catch { input.finish(throwing: error) }
        }
        defer { receiver.cancel() }

        let key = sessionId
        let mailbox = frames
        // The handlers hold the session until the connection ends, which stop() makes happen.
        let handlers = RFBClient.Handlers(
            credentials: { try await self.account(for: key, failed: signInFailed) },
            ready: { width, height in
                Task { @MainActor in self.began(width: width, height: height) }
            },
            frame: { mailbox.post($0) },
            cursor: { cursor in
                Task { @MainActor in
                    self.lastCursor = cursor
                    self.onCursor?(cursor)
                }
            },
            pointer: { x, y in
                Task { @MainActor in self.serverMoved(to: CGPoint(x: x, y: y)) }
            },
            clipboard: { _ in },
            update: { bytes, seconds, consumed in
                let line = String(format: "%.0f KB in %.2f s · %.0f KB unread", Double(bytes) / 1024, seconds, Double(received.value - consumed) / 1024)
                Task { @MainActor in self.stats = line }
            }
        )
        try await withTaskCancellationHandler {
            try await Task.detached {
                let client = RFBClient(send: { Self.transmit($0, on: socket) }, handlers: handlers)
                try await client.run(RFBByteStream(chunks))
            }.value
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func account(for key: String, failed: Bool) async throws -> (user: String, password: String) {
        if let account = Self.accounts[key] { return account }
        phase = .signIn(failed: failed)
        let account = try await withCheckedThrowingContinuation { accountRequest = $0 }
        Self.accounts[key] = account
        phase = .connecting
        return account
    }

    /// Answers the Mac's sign-in with an account of that Mac.
    func signIn(user: String, password: String) {
        accountRequest?.resume(returning: (user, password))
        accountRequest = nil
    }

    private func began(width: Int, height: Int) {
        ready = true
        screenSize = CGSize(width: width, height: height)
        if pointer == .zero { pointer = CGPoint(x: width / 2, y: height / 2) }
        phase = .live
    }

    private func serverMoved(to point: CGPoint) {
        guard buttons == 0 else { return }
        pointer = point
        onPointer?(point)
    }

    /// Takes the desktop from the agent, or hands it back.
    func setControlling(_ human: Bool) {
        guard ready, let socket else { return }
        socket.send(.string(human ? #"{"t":"control","owner":"human"}"# : #"{"t":"control","owner":"agent"}"#)) { _ in }
        controlling = human
        if !human { latched = [] }
    }

    private func send(_ bytes: [UInt8]) {
        guard ready, controlling, let socket else { return }
        Self.transmit(bytes, on: socket)
    }

    /// RFB bytes go as base64 text frames, which the relay caps at 64 Ki characters.
    nonisolated private static func transmit(_ bytes: [UInt8], on socket: URLSessionWebSocketTask) {
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + 48 * 1024)
            socket.send(.string(Data(bytes[offset..<end]).base64EncodedString())) { _ in }
            offset = end
        }
    }

    // MARK: - Pointer

    func movePointer(to point: CGPoint) {
        pointer = CGPoint(
            x: min(max(point.x, 0), max(screenSize.width - 1, 0)),
            y: min(max(point.y, 0), max(screenSize.height - 1, 0))
        )
        onPointer?(pointer)
        guard !movePending else { return }
        // At most one move per 8 ms, always the latest; a button flushes it first.
        movePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in self?.flushMove() }
    }

    func movePointer(by delta: CGSize) {
        movePointer(to: CGPoint(x: pointer.x + delta.width, y: pointer.y + delta.height))
    }

    private func flushMove() {
        guard movePending else { return }
        movePending = false
        send(RFBClient.pointer(buttons: buttons, x: Int(pointer.x), y: Int(pointer.y)))
    }

    func press(_ button: Button) {
        if buttons == 0 { pressLatched() }
        flushMove()
        buttons |= button.rawValue
        send(RFBClient.pointer(buttons: buttons, x: Int(pointer.x), y: Int(pointer.y)))
    }

    func release(_ button: Button) {
        flushMove()
        buttons &= ~button.rawValue
        send(RFBClient.pointer(buttons: buttons, x: Int(pointer.x), y: Int(pointer.y)))
        if buttons == 0 { releaseLatched() }
    }

    func click(_ button: Button = .left) {
        press(button)
        release(button)
    }

    /// Scrolls by a finger's travel in points, natural direction, as wheel clicks.
    func scroll(by delta: CGSize) {
        flushMove()
        wheel.width += delta.width
        wheel.height += delta.height
        let step: CGFloat = 12
        while abs(wheel.height) >= step {
            let mask: UInt8 = wheel.height > 0 ? 8 : 16
            wheel.height -= wheel.height > 0 ? step : -step
            send(RFBClient.pointer(buttons: buttons | mask, x: Int(pointer.x), y: Int(pointer.y)))
            send(RFBClient.pointer(buttons: buttons, x: Int(pointer.x), y: Int(pointer.y)))
        }
        while abs(wheel.width) >= step {
            let mask: UInt8 = wheel.width > 0 ? 32 : 64
            wheel.width -= wheel.width > 0 ? step : -step
            send(RFBClient.pointer(buttons: buttons | mask, x: Int(pointer.x), y: Int(pointer.y)))
            send(RFBClient.pointer(buttons: buttons, x: Int(pointer.x), y: Int(pointer.y)))
        }
    }

    // MARK: - Keys

    func toggleLatch(_ modifier: UInt32) {
        if let index = latched.firstIndex(of: modifier) { latched.remove(at: index) } else { latched.append(modifier) }
    }

    /// Types committed text. With ⌃, ⌥ or ⌘ latched, each character goes as
    /// that shortcut instead.
    func type(_ text: String) {
        let shortcut = latched.contains { $0 != RFBKeysym.shift }
        let shifted = latched.contains(RFBKeysym.shift)
        let text = shifted && !shortcut ? text.uppercased() : shortcut ? text.lowercased() : text
        for scalar in text.unicodeScalars { key(RFBKeysym.character(scalar), modifiers: shortcut) }
    }

    /// Presses and releases one key, wrapped in the latched modifiers.
    func key(_ keysym: UInt32, modifiers: Bool = true) {
        let held = modifiers ? latched : []
        enqueue(held.map { ($0, true) } + [(keysym, true), (keysym, false)] + held.reversed().map { ($0, false) })
        if modifiers { latched = [] }
    }

    /// A hardware key, whose release follows its own press.
    func key(_ keysym: UInt32, down: Bool) {
        enqueue([(keysym, down)])
    }

    private func pressLatched() {
        enqueue(latched.map { ($0, true) })
    }

    private func releaseLatched() {
        enqueue(latched.reversed().map { ($0, false) })
        latched = []
    }

    /// Keys go out in order. A Unicode keysym waits 40 ms after it: a Box's
    /// server lends one spare key code to each new character, and a quicker
    /// next character takes it over before the app has read the first.
    private func enqueue(_ keys: [(keysym: UInt32, down: Bool)]) {
        keyQueue += keys
        if !typing { drainKeys() }
    }

    private func drainKeys() {
        while !keyQueue.isEmpty {
            let next = keyQueue.removeFirst()
            flushMove()
            send(RFBClient.key(next.keysym, down: next.down))
            if !next.down, next.keysym >= 0x0100_0000, !keyQueue.isEmpty {
                typing = true
                Task {
                    try? await Task.sleep(for: .milliseconds(40))
                    typing = false
                    drainKeys()
                }
                return
            }
        }
    }

    // MARK: - Opening

    struct OpenFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `POST /teams/:teamId/runtime-desktop/:sessionId` — claims the session's
    /// desktop on its runtime, or answers the display it already holds.
    private static func open(token: String, teamId: String, sessionId: String) async throws -> Int {
        var request = URLRequest(url: NuphosAPI.baseURL.appending(path: "teams/\(teamId)/runtime-desktop/\(sessionId)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AccountAPI.aiConsentVersion, forHTTPHeaderField: "x-nuphos-ai-consent-version")
        request.timeoutInterval = 40
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        if (200..<300).contains(status), let display = json?["display"]?.numberValue { return Int(display) }
        if status == 401 { throw NuphosAPI.Failure.unauthorized }
        if status == 404 { throw OpenFailure(message: "This agent's computer can't show a desktop. Update Nuphos on it, or check that it is online.") }
        throw OpenFailure(message: json?["error"]?["message"]?.stringValue ?? "The desktop could not be opened (\(status)).")
    }
}

/// Bytes the socket has delivered, counted on the receiving task.
nonisolated private final class ByteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var value: Int { lock.withLock { total } }
    func add(_ count: Int) { lock.withLock { total += count } }
}

/// Hands the newest screen to the main thread as an image. While one image
/// is on its way, a newer screen only replaces the waiting snapshot, so the
/// pixels are copied once per picture shown rather than once per update, and
/// a slow device shows the present instead of a queue.
nonisolated private final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.nuphos.desktop.frames", qos: .userInteractive)
    private var delivering = false
    private var waiting: RFBFramebuffer?
    var show: (@MainActor (CGImage) -> Void)?

    func post(_ screen: RFBFramebuffer) {
        lock.lock()
        if delivering {
            waiting = screen
            lock.unlock()
            return
        }
        delivering = true
        lock.unlock()
        deliver(screen)
    }

    private func deliver(_ screen: RFBFramebuffer) {
        guard let image = screen.image() else { return finish() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.show?(image) }
            self.finish()
        }
    }

    private func finish() {
        lock.lock()
        let next = waiting
        waiting = nil
        delivering = next != nil
        lock.unlock()
        if let next { queue.async { self.deliver(next) } }
    }
}

nonisolated extension RFBFramebuffer {
    /// A copy of the pixels as an image Core Animation can show.
    func image() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

nonisolated extension RFBCursor {
    var image: CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
