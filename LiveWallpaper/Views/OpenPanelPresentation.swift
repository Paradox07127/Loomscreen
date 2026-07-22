import AppKit

@MainActor
extension NSOpenPanel {
    /// Presents as a sheet on the key/main window when one exists, falling back to an app-modal session (e.g.
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
