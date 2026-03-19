import AppKit

let app = NSApplication.shared

let delegate = (ClomeAppDelegate.self as NSObject.Type).init() as! ClomeAppDelegate
app.delegate = delegate
app.run()
