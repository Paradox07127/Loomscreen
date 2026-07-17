#if !LITE_BUILD
import LiveWallpaperSharedUI
import SwiftUI

extension WPECacheManagementView {
    /// DEBUG-only: temp directories left in the container by test runs. Compiled
    /// out of Release entirely — a shipping build has no producer for them.
    @ViewBuilder
    var testArtifactsSection: some View {
        #if DEBUG
        if testArtifacts.itemCount > 0 {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(byteFormatter.string(fromByteCount: Int64(testArtifacts.totalBytes)))
                            .font(DesignTokens.Typography.pageTitle)
                        Text("\(testArtifacts.itemCount) temporary items left in the container by test runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        confirmPurgeTestArtifacts()
                    } label: {
                        Label("Delete test artifacts", systemImage: "hammer")
                    }
                    .controlSize(.small)
                    StorageInfoButton {
                        infoNote("Scratch directories created by the test suites under the container's tmp folder. Debug builds only — no shipping code path writes them. Deleting them affects nothing but disk usage.")
                    }
                }
            } header: {
                Text("Test Artifacts (Debug)")
            } footer: {
                if let last = lastTestArtifactFreedBytes, last > 0 {
                    Text("Freed \(Int64(last), format: .byteCount(style: .file)).", comment: "Test-artifact cleanup footer after freeing space. Placeholder is the freed byte total.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        #endif
    }

    #if DEBUG
    func refreshTestArtifacts() async {
        testArtifacts = await Task.detached { TestTempArtifacts.scan() }.value
    }

    func confirmPurgeTestArtifacts() {
        let size = byteFormatter.string(fromByteCount: Int64(testArtifacts.totalBytes))
        pendingDestructive = PendingDestructive(
            .clearTestTempArtifacts(itemCount: testArtifacts.itemCount, formattedSize: size)
        ) {
            Task { await purgeTestArtifacts() }
        }
    }

    private func purgeTestArtifacts() async {
        let freed = await Task.detached { TestTempArtifacts.purge() }.value
        lastTestArtifactFreedBytes = freed
        await refreshTestArtifacts()
    }
    #endif
}
#endif
