import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppExceptionsSheet: View {
    @Binding var rules: [ApplicationPerformanceRule]
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 340, idealHeight: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Application Exceptions")
                .font(.headline)
            Text("Pause wallpapers on all displays while these apps are in use, to free up the GPU.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if rules.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No apps added")
                    .foregroundStyle(.secondary)
                Text("Add apps like Xcode, Final Cut Pro, or a game.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    addApp()
                } label: {
                    Label("Add Application…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            List {
                ForEach($rules) { $rule in
                    ruleRow($rule)
                }
                .onDelete { offsets in
                    rules.remove(atOffsets: offsets)
                    onChange()
                }
            }
            .listStyle(.inset)
        }
    }

    private func ruleRow(_ rule: Binding<ApplicationPerformanceRule>) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.icon(forBundleID: rule.wrappedValue.bundleID))
                .resizable()
                .frame(width: 24, height: 24)
            Text(verbatim: rule.wrappedValue.displayName)
                .lineLimit(1)
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { rule.wrappedValue.trigger },
                set: { rule.wrappedValue.trigger = $0; onChange() }
            )) {
                Text("When frontmost").tag(ApplicationPerformanceRule.Trigger.frontmost)
                Text("While running").tag(ApplicationPerformanceRule.Trigger.running)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Pause trigger for \(rule.wrappedValue.displayName)"))
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Button {
                addApp()
            } label: {
                Image(systemName: "plus")
            }
            .help(Text("Add an application"))
            .accessibilityLabel(Text("Add an application"))

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add", comment: "Open-panel confirm button to add the chosen app to the exceptions list.")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              !rules.contains(where: { $0.bundleID == bundleID }) else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        rules.append(ApplicationPerformanceRule(bundleID: bundleID, displayName: name, trigger: .frontmost))
        onChange()
    }

    private static func icon(forBundleID id: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
