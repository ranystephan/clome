import AppKit

let app = NSApplication.shared
nonisolated(unsafe) let delegate = ClomeAppDelegate()
app.delegate = delegate
app.run()
