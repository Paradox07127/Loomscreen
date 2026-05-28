#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Modal sheet for first-time Steam Web API key setup. Live-validates the
/// 32-hex shape, probes Valve's `GetSupportedAPIList`, and stores the key
/// in the Workshop Keychain slot — `WhenUnlockedThisDeviceOnly`, no iCloud
/// sync — on save.
struct SteamWebAPIKeyEntrySheet: View {
    let services: WorkshopServices
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var hasReadTOU: Bool = false
    @State private var isShowingKey: Bool = false
    @State private var validation: Validation = .empty
    @State private var validationTask: Task<Void, Never>?
    @State private var validatedAPIKey: String?
    @State private var savingError: String?

    enum Validation: Equatable {
        case empty
        case wrongShape
        case validating
        case valid
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            header
            disclosurePanel
            Toggle(isOn: $hasReadTOU) {
                Text("I have read the Steam Web API Terms of Use.")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            keyField
            validationHint
            if let savingError {
                Text(savingError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.regular)
                    .help("Discard changes")
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(validation != .valid)
                    .help("Save key to Keychain and close")
            }
            dataFlowFooter
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 460)
        .onAppear {
            Task {
                if let stored = try? await services.keychain.loadWebAPIKey() {
                    apiKey = stored
                    hasReadTOU = true
                    triggerValidation()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set your Steam Web API key")
                    .font(.system(size: 15, weight: .semibold))
                Text("Get a free key from Valve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var disclosurePanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Loomscreen uses Valve's Steam Web API to fetch Workshop metadata.")
                .font(.system(size: 12))
            Text("[Get a key](https://steamcommunity.com/dev/apikey)  ·  [Steam Web API TOU](https://steamcommunity.com/dev/apiterms)")
                .font(.system(size: 12))
                .tint(Color.accentColor)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
    }

    private var keyField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Group {
                if isShowingKey {
                    TextField("Paste your 32-character key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    SecureField("Paste your 32-character key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .disabled(!hasReadTOU)
            .onChange(of: apiKey) { _, _ in triggerValidation() }
            .onSubmit(save)

            Button {
                isShowingKey.toggle()
            } label: {
                Image(systemName: isShowingKey ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasReadTOU)
            .help(isShowingKey ? "Hide key" : "Show key")
            .accessibilityLabel(isShowingKey ? "Hide key" : "Show key")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .strokeBorder(Color.primary.opacity(hasReadTOU ? 0.15 : 0.05), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var validationHint: some View {
        switch validation {
        case .empty:
            Text("Paste your 32-character hexadecimal API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .wrongShape:
            label(text: "Key must be 32 hexadecimal characters.", tint: .red, system: "xmark.circle.fill")
        case .validating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking with Steam…").font(.caption).foregroundStyle(.secondary)
            }
        case .valid:
            label(text: "Key validated.", tint: .green, system: "checkmark.circle.fill")
        case .error(let message):
            label(text: message, tint: .red, system: "exclamationmark.triangle.fill")
        }
    }

    private var dataFlowFooter: some View {
        Text("Stored on your Mac (Keychain, no iCloud sync) and sent directly to Valve's Steam Web API over HTTPS. Loomscreen never proxies your key.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func label(text: String, tint: Color, system: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: system).foregroundStyle(tint).imageScale(.small)
            Text(text).font(.caption).foregroundStyle(tint)
        }
    }

    // MARK: - Validation + save

    private func triggerValidation() {
        savingError = nil
        validatedAPIKey = nil
        validationTask?.cancel()
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validation = .empty
            return
        }
        guard isHex32(trimmed) else {
            validation = .wrongShape
            return
        }
        validation = .validating
        let service = services.queryService
        validationTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                let ok = try await service.validateAPIKey(trimmed)
                if Task.isCancelled { return }
                guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                if ok {
                    validation = .valid
                    validatedAPIKey = trimmed
                } else {
                    validation = .error("Steam rejected the key.")
                }
            } catch is CancellationError {
                return
            } catch let error as WorkshopQueryError {
                if Task.isCancelled { return }
                guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                validation = .error(Self.message(for: error))
            } catch {
                if Task.isCancelled { return }
                guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                validation = .error("Validation failed: \(error.localizedDescription)")
            }
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validation == .valid, validatedAPIKey == trimmed else {
            triggerValidation()
            return
        }
        Task {
            do {
                try await services.keychain.setWebAPIKey(trimmed)
                await services.refreshAPIKeyStatus()
                onSaved()
                dismiss()
            } catch {
                savingError = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private func isHex32(_ key: String) -> Bool {
        key.count == 32 && key.allSatisfy(\.isHexDigit)
    }

    private static func message(for error: WorkshopQueryError) -> String {
        switch error {
        case .unauthorized: return "Steam rejected the key."
        case .keyDisabled: return "Your Steam API key was disabled by Valve."
        case .rateLimited: return "Steam is rate-limiting right now. Retry in a moment."
        case .networkUnreachable: return "Couldn't reach Steam. Check your connection."
        case .timeout: return "Steam took too long to respond."
        default: return "Validation failed."
        }
    }
}
#endif
