import Darwin
import Foundation

// Connects to the Mac's own Screen Sharing and reports what it negotiates and
// how large and slow each framebuffer update is. Credentials come from the environment.
setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let fd = socket(AF_INET, SOCK_STREAM, 0)
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = in_port_t(5900).bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
precondition(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0, "no server on 5900")

final class Counter: @unchecked Sendable { let lock = NSLock(); var received = 0; var lastReport = 0; var updates = 0; var start = Date() }
let counter = Counter()
let (stream, input) = AsyncThrowingStream<[UInt8], Error>.makeStream()
Thread.detachNewThread {
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { input.finish(); return }
        counter.lock.lock(); counter.received += n; counter.lock.unlock()
        input.yield(Array(buffer[0..<n]))
    }
}
func send(_ bytes: [UInt8]) { _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) } }
func stamp() -> String { String(format: "%7.2fs @%.3f", Date().timeIntervalSince(counter.start), Date().timeIntervalSince1970) }

let client = RFBClient(send: send, handlers: .init(
    credentials: { print(stamp(), "credentials asked (ARD)"); return (env["PROBE_USER"]!, env["PROBE_PASS"]!) },
    ready: { w, h in print(stamp(), "ready \(w)x\(h)") },
    frame: { fb in
        counter.lock.lock()
        let bytes = counter.received - counter.lastReport
        counter.lastReport = counter.received
        counter.updates += 1
        let n = counter.updates
        counter.lock.unlock()
        if true { print(stamp(), "update #\(n): \(bytes) bytes, encodings \(RFBProbe.take())") }
        if n == 1 || n % 5 == 0 {
            var out = Array("P6\n\(fb.width) \(fb.height)\n255\n".utf8)
            for p in fb.pixels { out += [UInt8(p >> 16 & 255), UInt8(p >> 8 & 255), UInt8(p & 255)] }
            FileManager.default.createFile(atPath: "frame-\(env["PROBE_TAG"] ?? "x")-\(n).ppm", contents: Data(out))
        }
    },
    cursor: { c in print(stamp(), "cursor \(c.width)x\(c.height)") },
    pointer: { _, _ in },
    clipboard: { _ in }
))
Task {
    do { try await client.run(RFBByteStream(stream)) } catch { print(stamp(), "client ended:", error, "encodings", RFBProbe.take()) }
    exit(0)
}
let seconds = Double(env["PROBE_SECONDS"] ?? "60")!
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    counter.lock.lock()
    print(stamp(), "total \(counter.received) bytes in \(counter.updates) updates")
    counter.lock.unlock()
    exit(0)
}
dispatchMain()
