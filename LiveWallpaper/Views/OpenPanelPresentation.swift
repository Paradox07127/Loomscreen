import AppKit

@MainActor
extension NSOpenPanel {
    /// Presents as a sheet on the key/main window when one exists, falling back
    /// to an app-modal session (e.g. invoked with no settings window open).
    /// `completion` runs only on OK, with the panel's selected URLs.
    func presentSheetOrModal(completion: @escaping ([URL]) -> Void) {
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            beginSheetModal(for: parent) { response in
                guard response == .OK else { return }
                completion(self.urls)
            }
        } else {
            guard runModal() == .OK else { return }
            completion(urls)
        }
    }
}
