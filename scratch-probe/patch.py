# Copies RFBClient.swift with a hook that records each rectangle's encoding, for the probe only.
import sys
s = open(sys.argv[1]).read()
anchor = "            let encoding = try await input.s32()\n"
assert anchor in s
s = s.replace(anchor, anchor + "            RFBProbe.note(encoding, w, h)\n", 1)
if "PROBE_ENCODINGS" in __import__("os").environ:
    s = s.replace("    static let encodings: [Int32] = [16, 1, 0, -239, -232, -223, -224]",
                  "    static let encodings: [Int32] = ProcessInfo.processInfo.environment[\"PROBE_ENCODINGS\"]!.split(separator: \",\").map { Int32($0)! }")
s += '''
nonisolated enum RFBProbe {
    nonisolated(unsafe) static var seen: [Int: Int] = [:]
    static func note(_ encoding: Int, _ w: Int, _ h: Int) { seen[encoding, default: 0] += w * h }
    static func take() -> String { defer { seen = [:] }; return seen.sorted { $0.key < $1.key }.map { "\\($0.key):\\($0.value)px" }.joined(separator: " ") }
}
'''
open(sys.argv[2], "w").write(s)
