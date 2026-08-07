import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        var anyFailed = false
        for url in urls {
            let ok = Opener.openFile(at: url)
            if !ok { anyFailed = true }
        }
        if anyFailed {
            Self.showAlert("One or more files failed to open. Check Console.app for the OpenWithObsidian subsystem for details.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If no files arrive within ~1.5s (e.g. user opened the .app directly),
        // exit quietly. application(_:open:) is invoked AFTER didFinishLaunching
        // when files are present, so this delay must be long enough to catch
        // the file callback first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.terminate(nil)
        }
    }

    static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Open With Obsidian"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
