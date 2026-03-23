import AppKit

let app = NSApplication.shared

let delegate = MainActor.assumeIsolated {
    ClomeAppDelegate()
}
app.delegate = delegate
app.run()
