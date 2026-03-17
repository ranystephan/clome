import AppKit

let app = NSApplication.shared
@MainActor func createDelegate() -> ClomeAppDelegate { ClomeAppDelegate() }
let delegate = createDelegate()
app.delegate = delegate
app.run()
