import AppKit

let app = NSApplication.shared
let delegate = { @MainActor in ClomeAppDelegate() }()
app.delegate = delegate
app.run()
