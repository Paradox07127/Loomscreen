import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var aboutTab: some View {
        ScrollView {
            VStack(spacing: 28) {
                aboutHero
                #if LITE_BUILD
                UpdateBannerView()
                #endif
                aboutTagline
                aboutActionGrid
                aboutFooter
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
    }

    private var aboutHero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 128, height: 128)
                    .blur(radius: 18)

                Image(systemName: "play.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(verbatim: BundleIdentity.productDisplayName)
                    .font(DesignTokens.Typography.hero)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(verbatim: versionString)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(versionString, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(Text("Copy version to clipboard"))
                    .accessibilityLabel(Text("Copy version"))
                }
            }
        }
    }

    private var aboutTagline: some View {
        Text("Live wallpapers for macOS: videos, web pages, and compatible imported scenes across every connected display.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
    }

    private var aboutActionGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                aboutTile(
                    title: "View on GitHub",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    accent: .blue,
                    url: URL(string: "https://github.com/Paradox07127/Loomscreen")
                )
                aboutTile(
                    title: "Discussions",
                    systemImage: "bubble.left.and.bubble.right",
                    accent: .indigo,
                    url: URL(string: "https://github.com/Paradox07127/Loomscreen/discussions")
                )
            }
            GridRow {
                aboutTile(
                    title: "Report a Bug",
                    systemImage: "ladybug",
                    accent: .red,
                    action: presentBugReport
                )
                aboutTile(
                    title: "Welcome Tour",
                    systemImage: "sparkles",
                    accent: .purple,
                    action: {
                        // Can't cast `NSApplication.shared.delegate` to our AppDelegate:
                        // it's SwiftUI's internal wrapper around `@NSApplicationDelegateAdaptor`.
                        // AppDelegate observes `.showOnboarding` instead.
                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                    }
                )
            }
        }
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private func aboutTile(
        title: LocalizedStringKey,
        systemImage: String,
        accent: Color,
        url: URL? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            if let action {
                action()
            } else if let url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(height: 26)

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == nil && url == nil)
    }

    private var aboutFooter: some View {
        VStack(spacing: 4) {
            Text("Made by Paradox07127")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(verbatim: "© 2026 Loomscreen contributors · MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .padding(.top, 4)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(version) (\(build))"
    }
}
