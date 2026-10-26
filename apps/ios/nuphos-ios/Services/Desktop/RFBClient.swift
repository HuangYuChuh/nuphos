import Foundation

/// Reads exactly the byte counts the protocol asks for from chunks that
/// arrive split anywhere.
nonisolated final class RFBByteStream {
    struct Closed: Error {}

    private var iterator: AsyncThrowingStream<[UInt8], Error>.Iterator
    private var buffer: [UInt8] = []
    private var offset = 0
    /// Every byte the protocol has read so far.
    private(set) var consumed = 0

    init(_ chunks: AsyncThrowingStream<[UInt8], Error>) {
        iterator = chunks.makeAsyncIterator()
    }

    func read(_ count: Int) async throws -> [UInt8] {
        while buffer.count - offset < count {
            guard let chunk = try await iterator.next() else { throw Closed() }
            buffer.removeFirst(offset)
            offset = 0
            buffer += chunk
        }
        defer { offset += count; consumed += count }
        return Array(buffer[offset..<(offset + count)])
    }

    func u8() async throws -> Int { Int(try await read(1)[0]) }
    func u16() async throws -> Int { let b = try await read(2); return Int(b[0]) << 8 | Int(b[1]) }
    func u32() async throws -> Int { let b = try await read(4); return b.reduce(0) { $0 << 8 | Int($1) } }
    func s32() async throws -> Int { Int(Int32(truncatingIfNeeded: try await u32())) }
}

/// An RFB 3.8 viewer: the handshake, then framebuffer updates applied to a
/// local copy of the screen. It speaks only what the backend's relay lets
/// through: security None or Apple Remote Desktop, and the ordinary client
/// messages.
nonisolated final class RFBClient {
    enum Failure: LocalizedError {
        case notVNC
        case refused(String)
        case unsupportedSecurity([Int])
        case signInFailed(String)
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .notVNC: "The computer did not answer as a VNC server."
            case .refused(let reason): reason
            case .unsupportedSecurity: "This computer asks for a sign-in method Nuphos does not support."
            case .signInFailed(let reason): reason.isEmpty ? "The Mac did not accept that account." : reason
            case .unexpected(let what): "The desktop stream broke off (\(what))."
            }
        }
    }

    struct Handlers {
        /// Asked for a Mac account when the server wants Apple Remote Desktop sign-in.
        var credentials: @Sendable () async throws -> (user: String, password: String)
        /// The handshake finished; input may be sent from now on.
        var ready: @Sendable (_ width: Int, _ height: Int) -> Void
        /// After each complete update. Keeping the value is a cheap snapshot:
        /// the next update copies the pixels before it writes.
        var frame: @Sendable (RFBFramebuffer) -> Void
        var cursor: @Sendable (RFBCursor) -> Void
        /// Where the server's pointer went when something else moved it.
        var pointer: @Sendable (_ x: Int, _ y: Int) -> Void
        var clipboard: @Sendable (String) -> Void
        /// After each update: its bytes, the seconds since it was asked for, and all bytes read so far.
        var update: (@Sendable (_ bytes: Int, _ seconds: Double, _ consumed: Int) -> Void)? = nil
    }

    /// The largest screen and pointer shape accepted, and the longest text or
    /// compressed rectangle: the server chooses these sizes, and anything
    /// beyond them would only exhaust memory.
    static let maxScreen = 8192
    static let maxCursor = 256
    static let maxLength = 64 << 20

    /// ZRLE, CopyRect, Raw, then the pseudo-encodings Cursor, PointerPos, DesktopSize and LastRect.
    static let encodings: [Int32] = [16, 1, 0, -239, -232, -223, -224]

    private let send: @Sendable ([UInt8]) -> Void
    private let handlers: Handlers
    private var framebuffer = RFBFramebuffer(width: 0, height: 0)
    private let zlib = ZlibStream()
    private var requested = Date()
    private var consumedBefore = 0

    init(send: @escaping @Sendable ([UInt8]) -> Void, handlers: Handlers) {
        self.send = send
        self.handlers = handlers
    }

    func run(_ input: RFBByteStream) async throws {
        try await handshake(input)
        while true {
            switch try await input.u8() {
            case 0:
                try await update(input)
                handlers.update?(input.consumed - consumedBefore, Date().timeIntervalSince(requested), input.consumed)
                consumedBefore = input.consumed
                requested = Date()
                send(Self.updateRequest(incremental: true, width: framebuffer.width, height: framebuffer.height))
            case 1:
                _ = try await input.read(3)
                _ = try await input.read(try await input.u16() * 6)
            case 2:
                break
            case 3:
                _ = try await input.read(3)
                let text = try await input.read(try await length(input))
                handlers.clipboard(String(decoding: text.map { UInt16($0) }, as: UTF16.self))
            case let type:
                throw Failure.unexpected("message \(type)")
            }
        }
    }

    private func handshake(_ input: RFBByteStream) async throws {
        guard String(decoding: try await input.read(12), as: UTF8.self).hasPrefix("RFB 003.") else { throw Failure.notVNC }
        send(Array("RFB 003.008\n".utf8))
        let count = try await input.u8()
        if count == 0 { throw Failure.refused(try await reason(input)) }
        let types = try await input.read(count).map(Int.init)
        if types.contains(1) {
            send([1])
        } else if types.contains(30) {
            send([30])
            let generator = try await input.read(2)
            let keyLength = try await input.u16()
            let prime = try await input.read(keyLength)
            let serverKey = try await input.read(keyLength)
            // Checked before asking for the account, which a bad group could not protect.
            guard (try? AppleRemoteDesktopAuth.validate(generator: generator, prime: prime, serverKey: serverKey)) != nil else {
                throw Failure.unexpected("key exchange")
            }
            let account = try await handlers.credentials()
            send(try AppleRemoteDesktopAuth.response(
                generator: generator, prime: prime, serverKey: serverKey, user: account.user, password: account.password
            ))
        } else {
            throw Failure.unsupportedSecurity(types)
        }
        if try await input.u32() != 0 { throw Failure.signInFailed(try await reason(input)) }

        send([1]) // ClientInit: shared, so the agent and other viewers keep the screen.
        let width = try await input.u16(), height = try await input.u16()
        try check(width: width, height: height)
        _ = try await input.read(16)
        _ = try await input.read(try await length(input)) // The desktop's name.
        framebuffer.resize(width: width, height: height)
        send(Self.pixelFormat)
        send([2, 0] + be16(Self.encodings.count) + Self.encodings.flatMap { be32(Int(UInt32(bitPattern: $0))) })
        consumedBefore = input.consumed
        requested = Date()
        send(Self.updateRequest(incremental: false, width: width, height: height))
        handlers.ready(width, height)
    }

    private func reason(_ input: RFBByteStream) async throws -> String {
        String(decoding: try await input.read(try await length(input)), as: UTF8.self)
    }

    private func length(_ input: RFBByteStream) async throws -> Int {
        let length = try await input.u32()
        guard length <= Self.maxLength else { throw Failure.unexpected("length \(length)") }
        return length
    }

    private func check(width: Int, height: Int) throws {
        guard width <= Self.maxScreen, height <= Self.maxScreen else { throw Failure.unexpected("a \(width)×\(height) screen") }
    }

    private func update(_ input: RFBByteStream) async throws {
        _ = try await input.read(1)
        let count = try await input.u16()
        var index = 0
        rects: while index < count {
            index += 1
            let x = try await input.u16(), y = try await input.u16()
            let w = try await input.u16(), h = try await input.u16()
            let encoding = try await input.s32()
            switch encoding {
            case -224:
                break rects
            case -223:
                try check(width: w, height: h)
                framebuffer.resize(width: w, height: h)
                continue
            case -232:
                handlers.pointer(x, y)
                continue
            case -239:
                guard w <= Self.maxCursor, h <= Self.maxCursor else { throw Failure.unexpected("a \(w)×\(h) pointer") }
                let colors = try await input.read(w * h * 4)
                let mask = try await input.read((w + 7) / 8 * h)
                if w > 0, h > 0 { handlers.cursor(RFBCursor(width: w, height: h, hotX: x, hotY: y, colors: colors, mask: mask)) }
                continue
            default:
                break
            }
            guard framebuffer.contains(x: x, y: y, width: w, height: h) else { throw Failure.unexpected("rectangle outside the screen") }
            switch encoding {
            case 0:
                framebuffer.put(x: x, y: y, width: w, height: h, RFBDecode.raw(try await input.read(w * h * 4), count: w * h))
            case 1:
                let sx = try await input.u16(), sy = try await input.u16()
                guard framebuffer.contains(x: sx, y: sy, width: w, height: h) else { throw Failure.unexpected("copy outside the screen") }
                framebuffer.copy(fromX: sx, fromY: sy, toX: x, toY: y, width: w, height: h)
            case 16:
                // The most one rectangle can take: a subencoding byte and a full
                // palette per 64×64 tile, then four bytes (a pixel and a run) per pixel.
                let tiles = ((w + 63) / 64) * ((h + 63) / 64)
                let data = try zlib.inflate(try await input.read(try await length(input)), limit: tiles * 49 + w * h * 4)
                framebuffer.put(x: x, y: y, width: w, height: h, try RFBDecode.zrle(data, width: w, height: h))
            default:
                throw Failure.unexpected("encoding \(encoding)")
            }
        }
        handlers.frame(framebuffer)
    }

    // MARK: - Client messages

    /// 32 bits per pixel, depth 24, little-endian true colour with red at bit 16.
    static let pixelFormat: [UInt8] = [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]

    static func updateRequest(incremental: Bool, width: Int, height: Int) -> [UInt8] {
        [3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(width) + be16(height)
    }

    /// Buttons: bit 0 left, 1 middle, 2 right, 3/4 wheel up/down, 5/6 wheel left/right.
    static func pointer(buttons: UInt8, x: Int, y: Int) -> [UInt8] {
        [5, buttons & 0x7F] + be16(max(0, x)) + be16(max(0, y))
    }

    static func key(_ keysym: UInt32, down: Bool) -> [UInt8] {
        [4, down ? 1 : 0, 0, 0] + be32(Int(keysym))
    }

    /// The server's clipboard takes Latin-1; anything else is dropped from the text.
    static func clipboard(_ text: String) -> [UInt8] {
        let latin1 = text.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : nil }
        return [6, 0, 0, 0] + be32(latin1.count) + latin1
    }
}

nonisolated private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
nonisolated private func be32(_ value: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(value >> $0 & 0xFF) } }
