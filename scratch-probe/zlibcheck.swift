import Foundation
// Each sync-flushed piece must inflate to all of its own bytes at once, as a ZRLE rectangle needs.
func hex(_ s: Substring) -> [UInt8] { var o = [UInt8](); var i = s.startIndex; while i < s.endIndex { let j = s.index(i, offsetBy: 2); o.append(UInt8(s[i..<j], radix: 16)!); i = j }; return o }
let stream = ZlibStream()
var ok = true
for (n, line) in try String(contentsOfFile: "zlib-pieces.txt", encoding: .utf8).split(separator: "\n").enumerated() {
    let parts = line.split(separator: " ")
    let expected = Int(parts[0])!
    let started = Date()
    let out = try stream.inflate(hex(parts[1]))
    let ms = Date().timeIntervalSince(started) * 1000
    print("piece \(n): \(parts[1].count / 2) bytes in, \(out.count) out, expected \(expected), \(String(format: "%.1f", ms)) ms")
    if out.count != expected { ok = false }
}
print(ok ? "ZLIB PER-PIECE OK" : "ZLIB PER-PIECE DELAYED OUTPUT")
