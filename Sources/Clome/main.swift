import AppKit

let app = NSApplication.shared

let delegate = MainActor.assumeIsolated {
    CrashReporter.shared.install()
    return ClomeAppDelegate()
}
app.delegate = delegate
app.run()
