#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Workshop Doctor — vertical probe checklist matching the mockup at
/// `docs/mockups/workshop-ui.html` section 7. Presented as a modal sheet
/// from `WorkshopSettingsView`.
struct WorkshopDoctorView: View {
    @Environment(SteamCMDDoctorService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var showingToast = false
    @State private var setupError: String?

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    headerCard
                    setupSection
                    diagnosticsSection
                    footerBar
                }
                .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                .padding(.vertical, DesignTokens.Spacing.lg)
            }
            .background(DesignTokens.Colors.pageBackground)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 640)
        .overlay(alignment: .bottom) {
            DiagnosticExportToast(isPresented: $showingToast)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .allowsHitTesting(false)
        }
        // Auto-detect SteamCMD + default the working directory on open, so a
        // first-time user usually lands on an already-configured Doctor.
        .task { await service.autoConfigureIfNeeded() }
    }

    // MARK: - Sections

    private var navigationBar: some View {
        HStack {
            Text("SteamCMD Doctor")
                .font(DesignTokens.Typography.sectionTitle)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.bar)
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Diagnostics")
                    .font(DesignTokens.Typography.sectionTitle)
                Text(lastRunText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: DesignTokens.Spacing.xs) {
                if greenCount > 0 {
                    BadgeChip(text: "\(greenCount) OK", tint: DesignTokens.Colors.Status.active, systemImage: "checkmark.circle.fill")
                }
                if yellowCount > 0 {
                    BadgeChip(text: "\(yellowCount) warning", tint: DesignTokens.Colors.Status.warning, systemImage: "exclamationmark.triangle.fill")
                }
                if redCount > 0 {
                    BadgeChip(text: "\(redCount) error", tint: DesignTokens.Colors.Status.danger, systemImage: "xmark.circle.fill")
                }
                if greenCount + yellowCount + redCount == 0 {
                    Text("Not yet run")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
        }
    }

    private var setupSection: some View {
        Card(title: "Setup") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                BinaryPickerRow(
                    path: service.binaryDisplayPath,
                    status: service.probes[.binaryIdentity]?.status ?? .notRun,
                    onPick: { url in
                        setupError = nil
                        Task {
                            do { try await service.bindBinary(url) } catch { await MainActor.run { setupError = error.localizedDescription } }
                        }
                    },
                    onAutoDetect: {
                        setupError = nil
                        return await service.autoDetectBinary()
                    }
                )
                Divider()
                WorkdirRadioRow(
                    currentPath: service.workdirDisplayPath,
                    onPickShared: {
                        setupError = nil
                        let home = FileManager.default.homeDirectoryForCurrentUser
                        let steamURL = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
                        Task {
                            do { try await service.bindWorkdir(steamURL, isSharedSteamLibrary: true) } catch { await MainActor.run { setupError = error.localizedDescription } }
                        }
                    },
                    onPickSeparate: { url in
                        setupError = nil
                        Task {
                            do { try await service.bindWorkdir(url, isSharedSteamLibrary: false) } catch { await MainActor.run { setupError = error.localizedDescription } }
                        }
                    }
                )
                Divider()
                UsernameRow(
                    currentUsername: service.username,
                    onSave: { name in
                        do { try service.setUsername(name) } catch { setupError = error.localizedDescription }
                    }
                )
                Divider()
                downloadsRow
                if let setupError {
                    Label(setupError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .font(.caption)
                        .padding(.top, DesignTokens.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text("Setup error: \(setupError)"))
                }
            }
        }
    }

    /// Reveals the real on-disk location where SteamCMD saves Workshop items —
    /// the sandbox-redirected container Steam tree, which is otherwise buried in
    /// `~/Library/Containers/…` and hard to reach by hand.
    private var downloadsRow: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Downloads")
                    .font(DesignTokens.Typography.bodyEmphasized)
                Text("Where SteamCMD saves Workshop items inside this app's container.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Show in Finder") { revealDownloadsFolder() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opens the SteamCMD download folder in Finder, falling back to its deepest
    /// existing ancestor when nothing has been downloaded yet (the
    /// `content/431960` folder only appears after the first download).
    private func revealDownloadsFolder() {
        let fileManager = FileManager.default
        guard let contentRoot = WPEDownloadArchiveReclaimer.containerSteamContentRoot(fileManager: fileManager) else {
            return
        }
        var target = contentRoot
        while !fileManager.fileExists(atPath: target.path) {
            let parent = target.deletingLastPathComponent()
            if parent.path == target.path { return }
            target = parent
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private var diagnosticsSection: some View {
        Card(title: "Probes") {
            VStack(spacing: 0) {
                ForEach(Array(DoctorProbeKind.allCases.enumerated()), id: \.element.id) { index, kind in
                    let report = service.probes[kind] ?? DoctorProbeReport(id: kind, status: .notRun, lastRun: .distantPast)
                    ProbeRow(
                        report: report,
                        service: service,
                        onCopied: { showingToast = true }
                    )
                    if index < DoctorProbeKind.allCases.count - 1 {
                        Divider().padding(.vertical, DesignTokens.Spacing.xs)
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button(action: exportDiagnostics) {
                Label("Export diagnostics", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(Text("Copy all probe reports as redacted JSON to clipboard"))

            Spacer()

            Button(action: { Task { await service.runAll() } }) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if service.state == .probing {
                        ProgressView().controlSize(.small)
                    }
                    Text(hasEverRunProbe ? "Re-run all probes" : "Run all probes")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(service.state == .probing)
            .help(Text("Run every diagnostic check against the bound SteamCMD install."))
        }
    }

    // MARK: - Header metrics

    private var hasEverRunProbe: Bool {
        service.probes.values.contains { $0.lastRun > .distantPast }
    }

    private var greenCount: Int {
        service.probes.values.filter { if case .green = $0.status { return true } else { return false } }.count
    }
    private var yellowCount: Int {
        service.probes.values.filter { if case .yellow = $0.status { return true } else { return false } }.count
    }
    private var redCount: Int {
        service.probes.values.filter { if case .red = $0.status { return true } else { return false } }.count
    }

    private var lastRunText: String {
        let reports = service.probes.values.filter { $0.lastRun > .distantPast }
        guard let mostRecent = reports.map(\.lastRun).max() else { return "Never run" }
        let elapsed = Int(Date().timeIntervalSince(mostRecent))
        if elapsed < 5 { return "Last run just now" }
        if elapsed < 60 { return "Last run \(elapsed)s ago" }
        let minutes = elapsed / 60
        return "Last run \(minutes)m ago"
    }

    // MARK: - Export

    private func exportDiagnostics() {
        var probesPayload: [String: Any] = [:]
        for kind in DoctorProbeKind.allCases {
            let report = service.probes[kind]
            var info: [String: Any] = ["status": statusKey(report?.status ?? .notRun)]
            switch report?.status {
            case .green(let detail)?:
                info["detail"] = sanitizeForExport(detail)
            case .yellow(let msg, let cmd)?:
                info["message"] = sanitizeForExport(msg)
                info["command"] = sanitizeForExport(cmd)
            case .red(let msg, let cmd)?:
                info["message"] = sanitizeForExport(msg)
                info["command"] = sanitizeForExport(cmd)
            default: break
            }
            if let lastRun = report?.lastRun, lastRun > .distantPast {
                info["lastRun"] = ISO8601DateFormatter().string(from: lastRun)
            }
            probesPayload[kind.rawValue] = info
        }

        let payload: [String: Any] = [
            "phase": "doctor",
            "ts": ISO8601DateFormatter().string(from: Date()),
            "binaryPath": service.binaryDisplayPath != nil ? "<bound>" : "<unbound>",
            "workdirPath": service.workdirDisplayPath != nil ? "<bound>" : "<unbound>",
            "hasUsername": service.username != nil,
            "state": String(describing: service.state),
            "probes": probesPayload
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(json, forType: .string)
            showingToast = true
        }
    }

    private func sanitizeForExport(_ value: String?) -> String {
        guard var output = value, !output.isEmpty else { return "" }
        if let workdir = service.workdirDisplayPath, !workdir.isEmpty {
            output = output.replacingOccurrences(of: workdir, with: "<workdir>")
        }
        if let binary = service.binaryDisplayPath, !binary.isEmpty {
            output = output.replacingOccurrences(of: binary, with: "<steamcmd>")
        }
        output = WorkshopDiagnosticRedactor.redact(output)
        if let username = service.username, !username.isEmpty {
            output = output.replacingOccurrences(of: username, with: "<steam_username>")
        }
        return output
    }

    private func statusKey(_ status: DoctorProbeStatus) -> String {
        switch status {
        case .notRun: return "notRun"
        case .running: return "running"
        case .green: return "green"
        case .yellow: return "yellow"
        case .red: return "red"
        }
    }
}

// MARK: - Card

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            content()
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
        }
    }
}

// MARK: - Picker rows

private struct BinaryPickerRow: View {
    let path: String?
    let status: DoctorProbeStatus
    let onPick: (URL) -> Void
    let onAutoDetect: () async -> Bool

    @State private var isDetecting = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Label("Binary", systemImage: "terminal.fill")
                .font(DesignTokens.Typography.bodyEmphasized)
                .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                if let path {
                    Text(path)
                        .font(DesignTokens.Typography.codeCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    statusBadge
                } else {
                    Text("Not selected")
                        .italic()
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.tertiary)
                    Text("Auto-detect finds a Homebrew or tarball install; otherwise pick SteamCMD's executable or its `steamcmd.sh` wrapper.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DesignTokens.Spacing.xs) {
                if isDetecting {
                    ProgressView().controlSize(.small)
                }
                Button("Auto-detect") { autoDetect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDetecting)
                    .help(Text("Scan the standard SteamCMD install locations"))
                Button(path == nil ? "Select…" : "Re-select") { pickFile() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDetecting)
            }
        }
    }

    private func autoDetect() {
        isDetecting = true
        Task {
            let found = await onAutoDetect()
            isDetecting = false
            // Fall back to the manual picker when nothing was found.
            if !found { pickFile() }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch status {
        case .green(let detail):
            BadgeChip(text: detail ?? "Verified", tint: DesignTokens.Colors.Status.active, systemImage: "checkmark.seal.fill")
        case .yellow:
            BadgeChip(text: "Unverified build", tint: DesignTokens.Colors.Status.warning, systemImage: "exclamationmark.shield.fill")
        case .red:
            BadgeChip(text: "Invalid binary", tint: DesignTokens.Colors.Status.danger, systemImage: "xmark.shield.fill")
        default:
            EmptyView()
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = String(localized: "Pick the SteamCMD executable or its steamcmd.sh wrapper.", comment: "Open-panel message when choosing the SteamCMD binary in the Workshop diagnostics sheet.")
        panel.prompt = String(localized: "Use Binary", comment: "Open-panel confirm button when choosing the SteamCMD binary.")
        // Pre-position the panel at the most plausible install location so
        // users don't have to navigate the filesystem when SteamCMD is in
        // its canonical Homebrew / Valve-tarball spot.
        if let candidate = SteamCMDBinaryResolver.autoDetectCandidates().first {
            panel.directoryURL = candidate.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url)
        }
    }
}

private struct WorkdirRadioRow: View {
    let currentPath: String?
    let onPickShared: () -> Void
    let onPickSeparate: (URL) -> Void

    @State private var showingAdvanced = false

    private var selectionIsShared: Bool {
        guard let currentPath else { return false }
        return currentPath.contains("Library/Application Support/Steam")
    }

    private var summaryText: String {
        guard currentPath != nil else { return "Setting up…" }
        return selectionIsShared ? "Shared Steam library" : "App-managed folder"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Default is auto-picked (shared if the Steam GUI is set up, else an
            // app-managed folder); the two choices live under "Change location".
            HStack(spacing: DesignTokens.Spacing.sm) {
                Label("Working directory", systemImage: "folder")
                    .font(DesignTokens.Typography.bodyEmphasized)
                Spacer(minLength: 0)
                Text(summaryText)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            if let currentPath, !selectionIsShared {
                Text(currentPath)
                    .font(DesignTokens.Typography.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            DisclosureGroup(isExpanded: $showingAdvanced) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    workdirOption(
                        title: "Use shared Steam library",
                        detail: "Reuses your existing Steam install's downloads + cached sign-in. Anything anyone using this Mac has downloaded for Wallpaper Engine becomes available without re-checking ownership.",
                        isSelected: currentPath != nil && selectionIsShared,
                        action: onPickShared
                    )
                    workdirOption(
                        title: "Use a separate folder",
                        detail: currentPath != nil && !selectionIsShared
                            ? currentPath ?? ""
                            : "Pick a folder. SteamCMD manages its own sign-in and download cache inside that folder.",
                        isSelected: currentPath != nil && !selectionIsShared,
                        action: pickSeparateDirectory,
                        isPath: currentPath != nil && !selectionIsShared
                    )
                }
                .padding(.top, DesignTokens.Spacing.xs)
            } label: {
                Text("Change location")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func workdirOption(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        isPath: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    .font(.system(size: 16))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(title)
                        .font(DesignTokens.Typography.bodyEmphasized)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 11, design: isPath ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isPath ? 1 : 3)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(.windowBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 1.2 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func pickSeparateDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Pick a folder for SteamCMD's downloads.", comment: "Open-panel message when choosing the SteamCMD download folder.")
        panel.prompt = String(localized: "Use Folder", comment: "Open-panel confirm button when choosing the SteamCMD download folder.")
        if panel.runModal() == .OK, let url = panel.url {
            onPickSeparate(url)
        }
    }
}

private struct UsernameRow: View {
    let currentUsername: String?
    let onSave: (String) -> Void
    @State private var draft: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Label("Username", systemImage: "person")
                .font(DesignTokens.Typography.bodyEmphasized)
                .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                TextField("Steam account name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280, alignment: .leading)
                    .font(DesignTokens.Typography.body)
                    .onSubmit { commit() }
                Text("A–Z, 0–9, underscore only. We never store your password.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Save") { commit() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(draft == (currentUsername ?? "") || draft.isEmpty)
        }
        .onAppear { draft = currentUsername ?? "" }
        .onChange(of: currentUsername) { _, newValue in draft = newValue ?? "" }
    }

    private func commit() {
        guard !draft.isEmpty else { return }
        onSave(draft)
    }
}

// MARK: - Probe row

private struct ProbeRow: View {
    let report: DoctorProbeReport
    let service: SteamCMDDoctorService
    let onCopied: () -> Void

    @State private var commandRevealed = false
    @State private var showingSignOutConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            statusIcon
                .frame(width: 20, height: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    Text(report.id.displayName)
                        .font(DesignTokens.Typography.bodyEmphasized)
                    Spacer()
                    if let value = inlineValue {
                        Text(value)
                            .font(DesignTokens.Typography.code)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                if let description = descriptionText {
                    Text(description)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if report.id == .cachedLogin, revealedCommand != nil {
                    securityGuaranteeCard
                }
                if let cmd = revealedCommand {
                    TerminalCommandPanel(command: cmd, redactedPreview: false, onCopied: onCopied)
                        .padding(.top, DesignTokens.Spacing.xs)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if hasActionRow {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        actionButtons
                        Spacer()
                        rerunButton
                    }
                    .padding(.top, DesignTokens.Spacing.xs)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .animation(.easeInOut(duration: 0.18), value: report.status)
        .animation(.easeInOut(duration: 0.18), value: commandRevealed)
    }

    @ViewBuilder private var statusIcon: some View {
        switch report.status {
        case .green:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.Colors.Status.active)
                .accessibilityLabel(Text("Passed"))
        case .yellow:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .accessibilityLabel(Text("Warning"))
        case .red:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.Colors.Status.danger)
                .accessibilityLabel(Text("Failed"))
        case .running:
            ProgressView().controlSize(.small).accessibilityLabel("Running")
        case .notRun:
            Image(systemName: "circle.dotted")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
                .accessibilityLabel(Text("Not run"))
        }
    }

    private var inlineValue: String? {
        // Surface the signed-in account on the cached-login row (the redacted
        // probe detail never carries the username).
        if report.id == .cachedLogin, case .green = report.status, let user = service.username {
            return user
        }
        switch report.status {
        case .green(let detail): return detail
        default: return nil
        }
    }

    private var descriptionText: String? {
        switch report.status {
        case .notRun: return "Not run yet."
        case .running: return "Running…"
        case .green: return nil
        case .yellow(let msg, _): return msg
        case .red(let msg, _): return msg
        }
    }

    private var commandFromStatus: String? {
        switch report.status {
        case .yellow(_, let cmd): return cmd
        case .red(_, let cmd): return cmd
        default: return nil
        }
    }

    private var revealedCommand: String? {
        commandRevealed ? commandFromStatus : nil
    }

    private var hasActionRow: Bool {
        guard report.status != .notRun, report.status != .running else { return false }
        switch report.status {
        case .green: return report.id == .cachedLogin  // green cached-login → "Sign out"
        default: return true
        }
    }

    @ViewBuilder private var actionButtons: some View {
        switch (report.id, report.status) {
        case (.binaryIdentity, .red):
            Button("Re-select SteamCMD") { pickBinary() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

        case (.rosetta, .yellow):
            Button("Install Rosetta") {
                Task { await service.installRosetta() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            showCommandButton()

        case (.gatekeeperQuarantine, .yellow), (.gatekeeperQuarantine, .red):
            if commandFromStatus != nil {
                Button(commandRevealed ? "Hide command" : "Show command") { commandRevealed.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

        case (.cachedLogin, .yellow):
            Button("I've signed in — re-check") {
                Task { await service.runProbe(.cachedLogin) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            showCommandButton()

        case (.cachedLogin, .green):
            Button("Sign out", role: .destructive) { showingSignOutConfirm = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .confirmationDialog(
                    Text("Sign out of SteamCMD?"),
                    isPresented: $showingSignOutConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Sign out", role: .destructive) {
                        Task { await service.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clears the cached Steam session on this Mac. You'll sign in again in Terminal to download. To sign out everywhere, deauthorize this device in Steam → Settings → Security.")
                }

        case (.wallpaperEngineOwnership, .red):
            Button("Open WE Store") {
                if let url = URL(string: "steam://store/431960") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            if commandFromStatus != nil {
                showCommandButton(label: "Sign in command")
            }

        case (.codeSignature, .yellow):
            // Informational; only show the codesign command if the user wants
            // to inspect manually.
            if commandFromStatus != nil {
                showCommandButton(label: "Show codesign command")
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder private func showCommandButton(label: String = "Show command") -> some View {
        if commandFromStatus != nil {
            Button(commandRevealed ? "Hide command" : label) {
                commandRevealed.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var rerunButton: some View {
        Button(action: { Task { await service.runProbe(report.id) } }) {
            Label("Re-run", systemImage: "arrow.clockwise")
                .font(DesignTokens.Typography.caption)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(Text("Re-run this probe"))
    }

    /// Reassures the user before they run the Terminal sign-in command that the
    /// app never touches their credentials — the whole point of the out-of-app
    /// login.
    private var securityGuaranteeCard: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(DesignTokens.Colors.Status.active)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your credentials stay in Terminal")
                    .font(DesignTokens.Typography.caption.weight(.bold))
                Text("You enter your password and Steam Guard code directly into Valve's official SteamCMD. This app never sees, requests, or stores them.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Colors.Status.active.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
        .padding(.top, DesignTokens.Spacing.xs)
    }

    private func pickBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let candidate = SteamCMDBinaryResolver.autoDetectCandidates().first {
            panel.directoryURL = candidate.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            Task { try? await service.bindBinary(url) }
        }
    }
}

// MARK: - Helpers

private struct BadgeChip: View {
    let text: String
    let tint: Color
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(DesignTokens.Typography.badge)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

#endif
