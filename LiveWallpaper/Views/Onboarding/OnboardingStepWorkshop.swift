#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Optional onboarding step (Pro only). Surfaces live
/// SteamCMD / Web API key status and opens the existing Doctor / key-entry
/// sheets in-window. Both the "Import a file" and "Steam Workshop" picker
/// cards lead here, so it is always skippable.
struct OnboardingStepWorkshop: View {
    let continueStep: () -> Void
    let skip: () -> Void

    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopServices.self) private var workshopServices

    @State private var showingDoctor = false
    @State private var showingKeyEntry = false

    private static let steamCMDGuide = URL(string: "https://developer.valvesoftware.com/wiki/SteamCMD")!
    private static let apiKeyPage = URL(string: "https://steamcommunity.com/dev/apikey")!

    var body: some View {
        VStack(spacing: 16) {
            header

            VStack(spacing: 12) {
                steamCMDRow
                apiKeyRow
            }

            Text("Uses your own Steam account. Credentials stay in this Mac's Keychain.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: continueStep) {
                    Text("Continue")
                        .frame(minWidth: 150)
                }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 14, horizontalPadding: 24, verticalPadding: 10))
                .keyboardShortcut(.defaultAction)

                Button(action: skip) {
                    Text("Skip for Now", comment: "Defer Steam Workshop setup during onboarding.")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 20)
        .sheet(isPresented: $showingDoctor) {
            WorkshopDoctorView().environment(doctor)
        }
        .sheet(isPresented: $showingKeyEntry) {
            SteamWebAPIKeyEntrySheet(services: workshopServices) {
                Task { await workshopServices.refreshAPIKeyStatus() }
            }
        }
        .task { await workshopServices.refreshAPIKeyStatus() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Optional", comment: "Badge marking the Steam Workshop onboarding step as skippable.")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
            Text("Set Up Steam Workshop")
                .font(DesignTokens.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Two one-time steps, then browse and download community scenes.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 30)
    }

    private var steamCMDRow: some View {
        SetupRow(
            icon: "stethoscope",
            tint: .teal,
            title: "SteamCMD",
            subtitle: "Steam's official downloader for Workshop wallpapers",
            guideURL: Self.steamCMDGuide,
            status: steamCMDStatus,
            actionTitle: "Set up",
            action: { showingDoctor = true }
        )
    }

    private var apiKeyRow: some View {
        SetupRow(
            icon: "key",
            tint: .orange,
            title: "Steam Web API key",
            subtitle: "Your own free key — needed to browse online",
            guideURL: Self.apiKeyPage,
            status: workshopServices.hasWebAPIKey ? .ready : .notSet,
            actionTitle: workshopServices.hasWebAPIKey ? "Replace" : "Add key",
            action: { showingKeyEntry = true }
        )
    }

    private var steamCMDStatus: SetupRow.Status {
        switch doctor.state {
        case .idle: return .notSet
        case .probing: return .checking
        case .done(let allGreen, let blockingFailures):
            if allGreen { return .ready }
            return blockingFailures == 0 ? .warning : .notSet
        }
    }
}

private struct SetupRow: View {
    enum Status { case notSet, checking, warning, ready }

    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let guideURL: URL
    let status: Status
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DesignTokens.Typography.sectionTitle)
                Text(subtitle)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: guideURL) {
                    HStack(spacing: 2) {
                        Text("Official guide", comment: "Link to the official Steam setup documentation.")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(DesignTokens.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 6) {
                statusBadge
                Button(action: action) {
                    Text(actionTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .notSet:
            badge("Not set", color: DesignTokens.Colors.Status.warning)
        case .checking:
            ProgressView().controlSize(.small)
        case .warning:
            badge("Check", color: DesignTokens.Colors.Status.warning)
        case .ready:
            badge("Ready", color: DesignTokens.Colors.Status.active)
        }
    }

    private func badge(_ text: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
