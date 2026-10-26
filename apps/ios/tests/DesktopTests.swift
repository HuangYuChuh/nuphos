import Foundation

/// The desktop viewer's protocol pieces, without UIKit: zlib, ZRLE, the RFB
/// handshake and update loop against a scripted server, the Diffie-Hellman
/// arithmetic and keysyms.
@main
struct DesktopTests {
    static func main() async throws {
        try inflate()
        try zrle()
        try await handshake()
        try await limits()
        power()
        group()
        keysyms()
        print("Desktop viewer tests passed")
    }

    static func hex(_ text: some StringProtocol) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    /// One zlib stream with sync and partial flushes, fed in uneven pieces that ignore the flush points.
    static func inflate() throws {
        let lines = try String(contentsOfFile: "tests/fixtures/desktop-zlib.txt", encoding: .utf8).split(separator: "\n")
        let expected = lines[0].split(separator: " ")
        let stream = lines.dropFirst().flatMap(hex)
        let inflater = ZlibStream()
        var output: [UInt8] = []
        var offset = 0
        var size = 1
        while offset < stream.count {
            let end = min(stream.count, offset + size)
            output += try inflater.inflate(Array(stream[offset..<end]))
            offset = end
            size = size * 7 % 1013 + 1
        }
        let fnv = output.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        precondition(output.count == Int(expected[0])! && fnv == UInt64(expected[1])!, "inflated bytes differ")
    }

    static let red: UInt32 = 0xFF0000, blue: UInt32 = 0x0000FF, green: UInt32 = 0x00FF00

    /// A 70×3 rectangle: a 64-wide palette-RLE tile, then a 6-wide packed palette tile.
    static let zrleRect = hex("789c6a6260f8ff9f81a12185b1219289e13f1032ac08f903000000ffff")

    static func expectedRect() -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: 70 * 3)
        let tileA = [UInt32](repeating: red, count: 101) + [blue] + [UInt32](repeating: red, count: 90)
        let tileB: [UInt32] = [blue, green, blue, green, blue, green, green, blue, green, blue, green, blue] + [UInt32](repeating: blue, count: 6)
        for i in 0..<192 { pixels[(i / 64) * 70 + i % 64] = tileA[i] }
        for i in 0..<18 { pixels[(i / 6) * 70 + 64 + i % 6] = tileB[i] }
        return pixels
    }

    static func zrle() throws {
        let inflater = ZlibStream()
        let rect = try RFBDecode.zrle(try inflater.inflate(zrleRect), width: 70, height: 3)
        precondition(rect == expectedRect())
        let solid = try RFBDecode.zrle([1, 0x00, 0xFF, 0x00], width: 3, height: 2)
        precondition(solid == [UInt32](repeating: green, count: 6))
        let plainRLE = try RFBDecode.zrle([128, 0xFF, 0, 0, 2, 0, 0, 0xFF, 0], width: 4, height: 1)
        precondition(plainRLE == [blue, blue, blue, red])
        let raw = try RFBDecode.zrle([0, 0xFF, 0, 0, 0, 0xFF, 0], width: 2, height: 1)
        precondition(raw == [blue, green])
        precondition((try? RFBDecode.zrle([128, 0, 0, 0, 9], width: 2, height: 1)) == nil, "A run past the tile is corrupt")
        precondition((try? ZlibStream().inflate(zrleRect, limit: 10)) == nil, "More output than the rectangle can hold is refused")
    }

    final class Recorder: @unchecked Sendable {
        var sent: [UInt8] = []
        var frames: [RFBFramebuffer] = []
        var cursor: RFBCursor?
        var pointer: (Int, Int)?
        var size: (Int, Int)?
        var updates: [(bytes: Int, consumed: Int)] = []
    }

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    static func be32(_ value: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }
    static func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: Int) -> [UInt8] {
        be16(x) + be16(y) + be16(w) + be16(h) + be32(encoding)
    }

    /// A TigerVNC-like server: no security, an 80×4 screen, then one update
    /// with every encoding the client asks for, split across odd chunks.
    static func handshake() async throws {
        let recorder = Recorder()
        let client = RFBClient(send: { recorder.sent += $0 }, handlers: .init(
            credentials: { throw CancellationError() },
            ready: { w, h in recorder.size = (w, h) },
            frame: { recorder.frames.append($0) },
            cursor: { recorder.cursor = $0 },
            pointer: { recorder.pointer = ($0, $1) },
            clipboard: { _ in },
            update: { bytes, _, _, consumed in recorder.updates.append((bytes, consumed)) }
        ))
        var server = Array("RFB 003.008\n".utf8) + [1, 1] + be32(0)
        server += be16(80) + be16(4) + [UInt8](repeating: 0, count: 16) + be32(3) + Array("Box".utf8)
        server += [0, 0] + be16(5)
        server += rect(0, 0, 70, 3, 16) + be32(zrleRect.count) + zrleRect
        server += rect(70, 0, 2, 1, 0) + [0, 0, 0xFF, 0, 0, 0xFF, 0, 0]
        server += rect(0, 3, 70, 1, 1) + be16(0) + be16(0)
        server += rect(1, 1, 2, 2, -239) + [UInt8](repeating: 0xFF, count: 16) + [0x80, 0x40]
        server += rect(40, 2, 0, 0, -232)
        let (chunks, input) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        var offset = 0
        while offset < server.count {
            let end = min(server.count, offset + 5)
            input.yield(Array(server[offset..<end]))
            offset = end
        }
        input.finish()
        do {
            try await client.run(RFBByteStream(chunks))
            preconditionFailure("The stream ended, so the client must throw")
        } catch is RFBByteStream.Closed {}

        precondition(recorder.size! == (80, 4))
        precondition(recorder.updates.count == 1 && recorder.updates[0].consumed == server.count, "One update, reported once all its bytes were read")
        var expected = Array("RFB 003.008\n".utf8) + [1, 1] + RFBClient.pixelFormat
        expected += [2, 0] + be16(RFBClient.encodings.count) + RFBClient.encodings.flatMap { be32(Int($0)) }
        expected += RFBClient.updateRequest(incremental: false, width: 80, height: 4)
        expected += RFBClient.updateRequest(incremental: true, width: 80, height: 4)
        precondition(recorder.sent == expected, "client messages differ")

        let frame = recorder.frames.last!
        let rect = expectedRect()
        for y in 0..<3 {
            precondition(Array(frame.pixels[(y * 80)..<(y * 80 + 70)]) == Array(rect[(y * 70)..<(y * 70 + 70)]))
        }
        precondition(frame.pixels[70] == red && frame.pixels[71] == green)
        precondition(Array(frame.pixels[240..<310]) == Array(frame.pixels[0..<70]), "CopyRect copies row 0 to row 3")
        precondition(recorder.cursor!.pixels == [0xFFFF_FFFF, 0, 0, 0xFFFF_FFFF] && recorder.cursor!.hotX == 1)
        precondition(recorder.pointer! == (40, 2))
    }

    /// A server that announces a screen larger than the cap is refused before any allocation.
    static func limits() async throws {
        let client = RFBClient(send: { _ in }, handlers: .init(
            credentials: { throw CancellationError() }, ready: { _, _ in }, frame: { _ in },
            cursor: { _ in }, pointer: { _, _ in }, clipboard: { _ in }
        ))
        let server = Array("RFB 003.008\n".utf8) + [1, 1] + be32(0) + be16(65535) + be16(65535)
        let (chunks, input) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        input.yield(server)
        input.finish()
        do {
            try await client.run(RFBByteStream(chunks))
            preconditionFailure("A 65535×65535 screen must be refused")
        } catch RFBClient.Failure.unexpected {}
    }

    /// The Diffie-Hellman group comes from the server and is checked before any arithmetic.
    static func group() {
        let prime = [0xC3] + [UInt8](repeating: 0x5A, count: 126) + [0x0B]
        let key = [0x11] + [UInt8](repeating: 0x22, count: 127)
        func valid(_ prime: [UInt8], _ key: [UInt8], generator: [UInt8] = [0, 2]) -> Bool {
            (try? AppleRemoteDesktopAuth.validate(generator: generator, prime: prime, serverKey: key)) != nil
        }
        precondition(valid(prime, key))
        precondition(!valid([], []), "An empty group")
        precondition(!valid([0] + prime.dropFirst(), key), "A zero-padded prime")
        precondition(!valid(prime.dropLast() + [0x0A], key), "An even prime")
        precondition(!valid(prime + [UInt8](repeating: 1, count: 385), key + [UInt8](repeating: 1, count: 385)), "A prime over 512 bytes")
        precondition(!valid(prime, prime), "A key that is not below the prime")
        precondition(!valid(prime, [UInt8](repeating: 0, count: 127) + [1]), "A key of 1")
        precondition(!valid(prime, key, generator: [0, 1]), "A generator of 1")
    }

    static func power() {
        let vectors = [
            ("2fa73207237751aa4462ebfc", "1a5ba50ad38835eddd6ff55", "df915ef09cfbac6e7687a66f", "371a4bbc9ec76283b341b10e"),
            ("2", "5", "b", "a"),
        ]
        for (base, exponent, modulus, result) in vectors {
            let pad = { (text: String) in hex(text.count % 2 == 1 ? "0" + text : text) }
            let value = BigUInt(bytes: pad(base)).power(BigUInt(bytes: pad(exponent)), modulus: BigUInt(bytes: pad(modulus)))
            precondition(value == BigUInt(bytes: pad(result)), "modular power differs")
        }
        precondition(BigUInt(bytes: [0, 0, 1, 2]).bytes(count: 4) == [0, 0, 1, 2])
    }

    static func keysyms() {
        precondition(RFBKeysym.character("a") == 0x61 && RFBKeysym.character("é") == 0xE9)
        precondition(RFBKeysym.character("中") == 0x0100_4E2D)
        precondition(RFBKeysym.character("\n") == RFBKeysym.return && RFBKeysym.character("\u{8}") == RFBKeysym.backspace)
        precondition(RFBKeysym.function(12) == 0xFFC9)
        precondition(RFBClient.pointer(buttons: 0xFF, x: -3, y: 9) == [5, 0x7F, 0, 0, 0, 9], "Bit 7 would make the relay read an extended pointer event")
    }
}
