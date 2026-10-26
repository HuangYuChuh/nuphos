import AppKit
// A full-screen window that flips colour every 2 s and prints when, so update latency can be measured.
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!.frame
let window = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .screenSaver
window.backgroundColor = .systemRed
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
var red = true
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    red.toggle()
    window.backgroundColor = red ? .systemRed : .systemBlue
    window.display()
    print(String(format: "flip %.3f %@", Date().timeIntervalSince1970, red ? "red" : "blue"))
}
app.run()
