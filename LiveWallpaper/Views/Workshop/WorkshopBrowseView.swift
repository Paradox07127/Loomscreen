#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// Sheet shell for the online Workshop browser, entered from Settings. The
/// actual grid / filters / states live in the reusable `WorkshopBrowsePane`
/// (shared with the in-app `WorkshopPaneView`); this wrapper only adds the
/// modal frame, a title row, and a Done button.
struct WorkshopBrowseView: View {
    let services: WorkshopServices
    let doctor: SteamCMDDoctorService
    let onRequestKeyEntry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: WorkshopBrowseViewModel

    init(services: WorkshopServices, doctor: SteamCMDDoctorService, onRequestKeyEntry: @escaping () -> Void) {
        self.services = services
        self.doctor = doctor
        self.onRequestKeyEntry = onRequestKeyEntry
        _viewModel = State(initialValue: WorkshopBrowseViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            WorkshopBrowsePane(viewModel: viewModel, doctor: doctor, onRequestKeyEntry: onRequestKeyEntry)
                .environment(services)
        }
        .frame(minWidth: 880, idealWidth: 960, minHeight: 600, idealHeight: 700)
        .background(DesignTokens.Colors.pageBackground)
    }

    private var topBar: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Steam Workshop · Browse")
                    .font(.system(size: 14, weight: .semibold))
                Text("Online metadata from Valve. Requires your own Steam Web API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
    }
}
#endif
