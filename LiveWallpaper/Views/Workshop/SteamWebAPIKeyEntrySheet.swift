#if !LITE_BUILD
import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// Validates the 32-hex shape, probes Valve's `GetSupportedAPIList`, and stores
/// the key in the Workshop Keychain slot (`WhenUnlockedThisDeviceOnly`, no
/// iCloud sync).
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
            antiPhishingCard
            Text("[Get a key](https://steamcommunity.com/dev/apikey)  ·  [Steam Web API TOU](https://steamcommunity.com/dev/apiterms)  ·  [About Limited Accounts](https://help.steampowered.com/en/faqs/view/71D3-35C2-AD96-AA3A)")
                .font(DesignTokens.Typography.body)
                .tint(Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $hasReadTOU) {
                Text("I have read the Steam Web API Terms of Use.")
                    .font(DesignTokens.Typography.body)
            }
            .toggleStyle(.checkbox)
            keyField
            validationHint
            if let savingError {
                Text(savingError)
                    .font(.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.regular)
                    .help(Text("Discard changes"))
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(validation != .valid)
                    .help(Text("Save key to Keychain and close"))
            }
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
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text("Set your Steam Web API key")
                .font(.headline)
            InfoTooltipButton(text: "Loomscreen uses your own Steam account's Web API key to read Workshop metadata — free, but it needs Mobile Steam Guard and a non-limited Steam account. Calls go directly to Valve over HTTPS; the key is stored only in this Mac's Keychain (no iCloud sync) and is never proxied through Loomscreen.")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var antiPhishingCard: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(DesignTokens.Colors.Status.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Official source only")
                    .font(DesignTokens.Typography.caption.weight(.bold))
                Text("Generate your key only at steamcommunity.com/dev/apikey. Never paste a key from a third-party site or installer. If a key may be compromised, [revoke it on Steam](https://steamcommunity.com/dev/apikey).")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .tint(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Colors.Status.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
    }

    private var keyField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Group {
                if isShowingKey {
                    TextField("Paste your 32-character key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.code)
                        .textSelection(.enabled)
                } else {
                    SecureField("Paste your 32-character key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.Typography.code)
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
            .help(isShowingKey ? Text("Hide key") : Text("Show key"))
            .accessibilityLabel(isShowingKey ? Text("Hide key") : Text("Show key"))
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
            label(text: "Key must be 32 hexadecimal characters.", tint: DesignTokens.Colors.Status.danger, system: "xmark.circle.fill")
        case .validating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking with Steam…").font(.caption).foregroundStyle(.secondary)
            }
        case .valid:
            label(text: "Key validated.", tint: DesignTokens.Colors.Status.active, system: "checkmark.circle.fill")
        case .error(let message):
            label(text: message, tint: DesignTokens.Colors.Status.danger, system: "exclamationmark.triangle.fill")
        }
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
