import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

private let inspectorSplitAutosaveName = "LiveWallpaper.ScreenDetail.InspectorSplit"
private let inspectorSplitAutosaveDefaultsKey = "NSSplitView Subview Frames \(inspectorSplitAutosaveName)"

/// Xcode-style trailing inspector built on a real AppKit `NSSplitViewController`
/// instead of SwiftUI's `.inspector()`. SwiftUI's modifier inserts a
/// window-level column whose generated `NSSplitViewItem` we cannot control, so
/// opening it grows the window and overflows the toolbar to `>>`. Hosting our
/// own split view inside the detail column lets us pin the split width and
/// resize only the editor sibling — the window never grows and the toolbar
/// region is untouched.
struct InspectorSplit<Editor: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding private var isPresented: Bool
    private let editor: Editor
    private let inspector: Inspector

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        isPresented: Binding<Bool>,
        @ViewBuilder editor: () -> Editor,
        @ViewBuilder inspector: () -> Inspector
    ) {
        _isPresented = isPresented
        self.editor = editor()
        self.inspector = inspector()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSViewController(context: Context) -> InspectorSplitViewController<Editor, Inspector> {
        let controller = InspectorSplitViewController(
            editor: hostedEditor,
            inspector: hostedInspector,
            isPresented: isPresented
        )
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateNSViewController(
        _ nsViewController: InspectorSplitViewController<Editor, Inspector>,
        context: Context
    ) {
        context.coordinator.parent = self
        context.coordinator.attach(to: nsViewController)

        nsViewController.updateRootViews(
            editor: hostedEditor,
            inspector: hostedInspector
        )
        nsViewController.setInspectorPresented(isPresented, animated: !reduceMotion)
    }

    private var hostedEditor: InspectorSplitRoot<Editor> {
        InspectorSplitRoot(
            content: editor,
            screenManager: screenManager,
            featureCatalog: featureCatalog
        )
    }

    private var hostedInspector: InspectorSplitRoot<Inspector> {
        InspectorSplitRoot(
            content: inspector,
            screenManager: screenManager,
            featureCatalog: featureCatalog
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: InspectorSplit
        private weak var controller: InspectorSplitViewController<Editor, Inspector>?
        private var collapsedObservation: NSKeyValueObservation?

        init(parent: InspectorSplit) {
            self.parent = parent
        }

        /// Mirror native collapse (divider drag / double-click) back into the
        /// SwiftUI binding so the toolbar toggle stays in sync. The value guard
        /// breaks the feedback loop when the change originated from SwiftUI.
        func attach(to controller: InspectorSplitViewController<Editor, Inspector>) {
            guard self.controller !== controller else { return }
            self.controller = controller
            collapsedObservation = controller.inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                // Extract the Sendable Bool before hopping; the NSSplitViewItem
                // itself is main-actor-isolated and must not cross the boundary.
                guard let collapsed = change.newValue else { return }
                // KVO for an AppKit UI property always fires on the main thread,
                // so it is safe to assume main-actor isolation here.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let presented = !collapsed
                    guard self.parent.isPresented != presented else { return }
                    self.parent.isPresented = presented
                }
            }
        }
    }
}

/// Re-injects the environment the hosted SwiftUI sub-tree needs. An
/// `NSHostingController` created inside a representable does not inherit the
/// parent SwiftUI environment, so nested views reading `@Environment` would
/// otherwise read defaults. (System values like `accessibilityReduceMotion` are
/// propagated automatically by NSHostingController and are read-only, so they
/// are not — and cannot be — re-injected here.)
struct InspectorSplitRoot<Content: View>: View {
    let content: Content
    let screenManager: ScreenManager
    let featureCatalog: FeatureCatalog

    var body: some View {
        content
            .environment(screenManager)
            .environment(\.featureCatalog, featureCatalog)
    }
}

final class InspectorSplitViewController<Editor: View, Inspector: View>: NSSplitViewController {
    let editorHostingController: NSHostingController<InspectorSplitRoot<Editor>>
    let inspectorHostingController: NSHostingController<InspectorSplitRoot<Inspector>>
    let editorItem: NSSplitViewItem
    let inspectorItem: NSSplitViewItem

    private var didCompleteInitialPresentationSync = false
    private var didApplyInitialInspectorWidth = false

    init(
        editor: InspectorSplitRoot<Editor>,
        inspector: InspectorSplitRoot<Inspector>,
        isPresented: Bool
    ) {
        editorHostingController = NSHostingController(rootView: editor)
        inspectorHostingController = NSHostingController(rootView: inspector)
        editorItem = NSSplitViewItem(viewController: editorHostingController)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHostingController)

        super.init(nibName: nil, bundle: nil)

        let managedSplitView = InspectorSplitView()
        managedSplitView.isVertical = true
        managedSplitView.dividerStyle = .thin
        managedSplitView.autosaveName = inspectorSplitAutosaveName
        configureContainerView(managedSplitView)
        splitView = managedSplitView

        configureHostingController(editorHostingController)
        configureHostingController(inspectorHostingController)
        configureSplitItems(isPresented: isPresented)

        addSplitViewItem(editorItem)
        addSplitViewItem(inspectorItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureContainerView(view)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialInspectorWidthIfNeeded()
    }

    func updateRootViews(
        editor: InspectorSplitRoot<Editor>,
        inspector: InspectorSplitRoot<Inspector>
    ) {
        editorHostingController.rootView = editor
        inspectorHostingController.rootView = inspector
    }

    func setInspectorPresented(_ presented: Bool, animated: Bool) {
        let shouldCollapse = !presented
        guard inspectorItem.isCollapsed != shouldCollapse else {
            didCompleteInitialPresentationSync = true
            return
        }

        if animated && didCompleteInitialPresentationSync && view.window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.allowsImplicitAnimation = true
                inspectorItem.animator().isCollapsed = shouldCollapse
            }
        } else {
            inspectorItem.isCollapsed = shouldCollapse
        }

        if presented {
            view.needsLayout = true
        }
        didCompleteInitialPresentationSync = true
    }

    private func configureSplitItems(isPresented: Bool) {
        editorItem.canCollapse = false
        editorItem.minimumThickness = DesignTokens.PreviewArea.minWidth
        editorItem.holdingPriority = .defaultLow

        inspectorItem.canCollapse = true
        // Critical no-window-grow lever: keep this NSSplitView fixed and resize
        // the editor sibling when the inspector collapses or uncollapses.
        inspectorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspectorItem.minimumThickness = DesignTokens.Inspector.minWidth
        inspectorItem.maximumThickness = DesignTokens.Inspector.maxWidth
        inspectorItem.automaticMaximumThickness = DesignTokens.Inspector.maxWidth
        inspectorItem.holdingPriority = .defaultHigh
        inspectorItem.isCollapsed = !isPresented
    }

    private func applyInitialInspectorWidthIfNeeded() {
        guard !didApplyInitialInspectorWidth, !inspectorItem.isCollapsed else { return }
        didApplyInitialInspectorWidth = true
        guard UserDefaults.standard.object(forKey: inspectorSplitAutosaveDefaultsKey) == nil else { return }

        let totalWidth = splitView.bounds.width
        let minimumTotalWidth = DesignTokens.PreviewArea.minWidth + DesignTokens.Inspector.minWidth
        guard totalWidth >= minimumTotalWidth else { return }

        let unclampedDividerPosition = totalWidth - DesignTokens.Inspector.idealWidth
        let minimumDividerPosition = DesignTokens.PreviewArea.minWidth
        let maximumDividerPosition = totalWidth - DesignTokens.Inspector.minWidth
        let dividerPosition = min(max(unclampedDividerPosition, minimumDividerPosition), maximumDividerPosition)
        splitView.setPosition(dividerPosition, ofDividerAt: 0)
    }

    private func configureHostingController<Content: View>(_ controller: NSHostingController<Content>) {
        // Do not export SwiftUI min/intrinsic sizes through AppKit. The split
        // items own the editor/inspector floors, so opening the inspector cannot
        // inflate the NSViewControllerRepresentable's fitting width.
        controller.sizingOptions = []
        configureContainerView(controller.view)
    }

    private func configureContainerView(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
}

/// Reports no intrinsic size so the hosted split never pushes a minimum width
/// up into the SwiftUI layout (which would grow the detail column / window).
final class InspectorSplitView: NSSplitView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
