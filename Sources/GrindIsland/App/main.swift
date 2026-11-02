import AppKit

// `--permission-hook`: act as Claude Code's hook command (no UI) and exit.
ApprovalHook.runIfRequested()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
