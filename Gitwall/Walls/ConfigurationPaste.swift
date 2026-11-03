import AppKit
import GitwallCore

/// Edit › Paste Configuration…, Settings › Presets › Paste Presets… and the empty Walls window all paste the same
/// way: read the clipboard, say what would change, write only after the user agrees (docs/adr/0014). The rules are
/// `GitwallFile`'s; this only shows the alerts.
@MainActor
enum ConfigurationPaste {
    /// Returns the pasted file when something was written, nil when nothing was.
    @discardableResult
    static func run(environment: AppEnvironment) -> GitwallFile? {
        switch environment.configurationOnPasteboard() {
        case .failure(let error):
            inform("The configuration could not be pasted", error.message)
            return nil
        case .success(let file):
            let preview = environment.pastePreview(file)
            guard preview.hasChanges else {
                inform("Nothing to paste", "The presets and walls on the clipboard are already set up exactly like this.")
                return nil
            }
            let alert = NSAlert()
            alert.messageText = "Paste configuration?"
            alert.informativeText = "\(preview.summary). A replaced preset keeps its accounts and repositories, notifications and menu bar count; its other filters give way to the pasted query. A replaced wall takes the pasted name and tiles. Nothing is deleted."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            environment.pasteConfiguration(file)
            return file
        }
    }

    /// Copy Wall as JSON, with a note when the copy had to leave something out.
    static func copy(_ wall: Wall, environment: AppEnvironment) {
        if let warning = environment.copyWallAsJSON(wall) {
            inform("Copied, with some settings left out", warning)
        }
    }

    private static func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
