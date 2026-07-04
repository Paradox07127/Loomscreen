import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsNavigation?
    @Binding var searchText: String
    let onBack: () -> Void

    @Environment(\.featureCatalog) private var featureCatalog

    private var items: [SettingsNavigationItem] {
        SettingsNavigation.filteredItems(
            matching: searchText,
            capabilities: featureCatalog.capabilities,
            includeWorkshopOnline: featureCatalog.isEnabled(.workshopOnline)
        )
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                backButton
                SettingsSidebarSearchField(text: $searchText)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm)

            List(selection: $selection) {
                Section {
                    if items.isEmpty {
                        emptySearchRow
                    } else {
                        ForEach(items) { item in
                            NavigationLink(value: item.destination) {
                                SettingsSidebarRow(item: item, searchText: searchText)
                            }
                            .accessibilityHint(Text("Open settings category"))
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: isSearching ? "Search Results" : "Settings")
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(
            min: SettingsWindowMetrics.sidebarColumnWidth,
            ideal: SettingsWindowMetrics.sidebarColumnWidth,
            max: SettingsWindowMetrics.sidebarColumnMaxWidth
        )
        .onAppear {
            if selection == nil {
                selection = items.first?.destination ?? .general
            }
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            Label("Back to App", systemImage: "chevron.left")
                .font(DesignTokens.Typography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .accessibilityHint(Text("Return to the wallpaper browser sidebar"))
    }

    private var emptySearchRow: some View {
        Label("No settings found", systemImage: "magnifyingglass")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private struct SettingsSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: SettingsSidebarMetrics.searchContentSpacing) {
            Image(systemName: "magnifyingglass")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search Settings", text: $text)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .accessibilityLabel(Text("Search Settings"))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DesignTokens.Typography.captionEmphasized)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Clear search"))
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: SettingsSidebarMetrics.searchMinHeight)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 1)
        }
    }
}

private struct SettingsSidebarRow: View {
    let item: SettingsNavigationItem
    let searchText: String

    private var matchHint: String? {
        item.searchMatchHint(matching: searchText)
    }

    var body: some View {
        HStack(spacing: SettingsSidebarMetrics.rowContentSpacing) {
            Image(systemName: item.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: SettingsSidebarMetrics.rowIconWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(LocalizedStringKey(item.title))
                    .lineLimit(1)

                if let matchHint {
                    Text("Matched: \(matchHint)")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

private enum SettingsSidebarMetrics {
    static let searchContentSpacing: CGFloat = 7
    static let searchMinHeight: CGFloat = 30
    static let rowContentSpacing: CGFloat = 7
    static let rowIconWidth: CGFloat = 18
}
