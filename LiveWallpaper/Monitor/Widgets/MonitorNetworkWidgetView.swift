import SwiftUI

/// Network widget — a 1:1 native replica of the mock's `net_s` / `net_m`
/// (`.claude/plan/monitor-design/index.html`). A mirrored dual-area scope where
/// ↓RX (amber) grows up from the midline and ↑TX (steel) grows down on a synced
/// scale, framed by current rates, peak, session totals, and — on M — the folded
/// interface / IP / connectivity / errors detail the design source folded in from
/// the cut L. Pure function of `MonitorWidgetContext`; charts read pre-accumulated
/// history, never sample.
///
/// The mock marks Net-L `CUT` ("M's shrunk chart already holds the full detail;
/// no L template needed") — but `MonitorWidgetKind.network.allowedSizes` still
/// lets a user park Network at L on the board, so the same M content has to fill
/// that taller cell on purpose rather than sit top-hugged over dead space. L
/// reuses every M row verbatim and un-shrinks the scope back toward the window
/// the pre-cut L used to show (mock's dormant `net120` — 120 samples, exactly
/// `MonitorHistoryStore`'s default capacity), letting the chart grow to fill
/// whatever height M's shrink step freed up.
struct MonitorNetworkWidgetView: View {
    let context: MonitorWidgetContext

    // NET_UP = amber (RX, grows up) / NET_DN = steel (TX, grows down) — the mock's
    // hue assignment, distinct from Disk's sage/violet so the two scopes never blur.
    private static let rxColor = MonitorDesign.signalAmber
    private static let txColor = MonitorDesign.signalSteel

    // Mirrored-scope sample windows — M stays the "shrunk" 60s the network-verdict
    // update chose; L un-shrinks toward the mock's dormant 120-sample `net120`
    // window (== history capacity, so this is "show everything kept", not new data).
    private static let mediumChartWindowSamples = 60
    private static let largeChartWindowSamples = 120

    private var snapshot: MonitorSnapshot { context.snapshot }
    private var system: MonitorSystemSnapshot? { snapshot.system }
    private var history: MonitorHistorySnapshot { context.history }

    var body: some View {
        GeometryReader { geo in
            let cellHeight = geo.size.height
            MonitorWidgetContainer(
                label: "Network",
                systemImage: headerSymbol,
                cellHeight: cellHeight,
                status: { headerStatus(cellHeight: cellHeight) },
                content: {
                    switch context.placement.size {
                    case .small: smallBody(cellHeight: cellHeight)
                    case .medium: mediumBody(cellHeight: cellHeight)
                    case .large: largeBody(cellHeight: cellHeight)
                    }
                }
            )
        }
    }

    // MARK: - Header

    /// Active-interface type drives the glyph; falls back to a generic network dot.
    private var headerSymbol: String {
        switch activeInterfaceType {
        case "wifi": return "wifi"
        case "wiredEthernet", "wired": return "cable.connector"
        case "cellular": return "antenna.radiowaves.left.and.right"
        default: return "network"
        }
    }

    @ViewBuilder
    private func headerStatus(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        HStack(spacing: 5) {
            if let name = headerInterfaceLabel {
                Text(verbatim: name)
                    .font(MonitorDesign.subFont(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkMuted)
            }
            connectivityDot
        }
    }

    /// S shows the short interface label ("Wi-Fi"); M shows "en0 · Wi-Fi".
    private var headerInterfaceLabel: String? {
        switch context.placement.size {
        case .small:
            let typeLabel = MonitorFormat.interfaceTypeLabel(activeInterfaceType)
            if !typeLabel.isEmpty { return typeLabel }
            return activeInterface?.name
        case .medium, .large:
            guard let iface = activeInterface else {
                let typeLabel = MonitorFormat.interfaceTypeLabel(activeInterfaceType)
                return typeLabel.isEmpty ? nil : typeLabel
            }
            let typeLabel = MonitorFormat.interfaceTypeLabel(activeInterfaceType)
            return typeLabel.isEmpty ? iface.name : "\(iface.name) · \(typeLabel)"
        }
    }

    private var connectivityDot: some View {
        Circle()
            .fill(isOnline ? MonitorDesign.signalSage : MonitorDesign.signalCoral)
            .frame(width: 6, height: 6)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            .shadow(color: (isOnline ? MonitorDesign.signalSage : MonitorDesign.signalCoral)
                .opacity(0.6), radius: 3)
    }

    // MARK: - Small (2×2)

    @ViewBuilder
    private func smallBody(cellHeight: CGFloat) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            Spacer(minLength: 0)
            dualRate(scale: scale, heroScale: 0.62)
            microStrip
                .frame(height: max(10, cellHeight * 0.18))
                .padding(.top, scale.label * 0.15)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The RX 20-sample micro bar strip (mock `.mcols`, amber bars). Each bar
    /// fills to its share of the window max, anchored to the bottom.
    @ViewBuilder
    private var microStrip: some View {
        let samples = tail(history.netRx, count: 20)
        let mx = max(samples.max() ?? 0, .ulpOfOne)
        if samples.count >= 2 {
            GeometryReader { g in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, v in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Self.rxColor.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(1, g.size.height * CGFloat(min(1, v / mx))))
                    }
                }
                .frame(height: g.size.height, alignment: .bottom)
            }
        }
    }

    // MARK: - Medium (4×2) / Large (4×4)

    /// M's row order and content, chart pinned to the shrunk fixed height the
    /// network-verdict update chose (frees vertical room for the folded-in detail).
    @ViewBuilder
    private func mediumBody(cellHeight: CGFloat) -> some View {
        scopeBody(cellHeight: cellHeight, chartMode: .compact)
    }

    /// Same rows as M (mock: "no L template needed") but the chart un-shrinks —
    /// a wider sample window, grown to fill whatever height L's extra cell rows
    /// free up instead of leaving it blank under a fixed-height chart.
    @ViewBuilder
    private func largeBody(cellHeight: CGFloat) -> some View {
        scopeBody(cellHeight: cellHeight, chartMode: .expanded)
    }

    private enum ChartMode: Equatable { case compact, expanded }

    @ViewBuilder
    private func scopeBody(cellHeight: CGFloat, chartMode: ChartMode) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let rowSpacing = scale.label * (chartMode == .expanded ? 0.75 : 0.55)
        VStack(alignment: .leading, spacing: rowSpacing) {
            // current pair row
            HStack(alignment: .firstTextBaseline) {
                currentPairLabel(scale: scale)
                Spacer(minLength: 6)
                Text(verbatim: "\(MonitorFormat.rate(rxRate)) · \(MonitorFormat.rate(txRate))")
                    .font(MonitorDesign.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkPrimary)
            }

            mirroredScope(cellHeight: cellHeight, chartMode: chartMode)

            // peak + session Σ
            HStack(alignment: .firstTextBaseline) {
                peakTag(scale: scale)
                Spacer(minLength: 6)
                Text(verbatim: "Σ \(MonitorFormat.bytes(sessionTotalBytes))")
                    .font(MonitorDesign.captionFont(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }

            // interface / IP / connectivity detail (folded in from the cut L)
            if activeInterface != nil {
                interfaceDetail(scale: scale)
            }

            // errors/drops health line — whispered when clean, coral when non-zero
            if let errN = errorCount {
                healthCorner(errorCount: errN, scale: scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func mirroredScope(cellHeight: CGFloat, chartMode: ChartMode) -> some View {
        let windowSamples = chartMode == .expanded ? Self.largeChartWindowSamples : Self.mediumChartWindowSamples
        let chart = MirroredAreaChart(
            up: tail(history.netRx, count: windowSamples),
            down: tail(history.netTx, count: windowSamples),
            upColor: Self.rxColor,
            downColor: Self.txColor
        )
        switch chartMode {
        case .compact:
            chart.frame(height: max(28, cellHeight * 0.26))
        case .expanded:
            chart
                .frame(minHeight: max(28, cellHeight * 0.26))
                .frame(maxHeight: .infinity)
        }
    }

    private func currentPairLabel(scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: "↓").foregroundStyle(Self.rxColor)
            Text(verbatim: " RX  ").foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: "↑").foregroundStyle(Self.txColor)
            Text(verbatim: " TX").foregroundStyle(MonitorDesign.inkFaint)
        }
        .font(MonitorDesign.labelFont(size: scale.label))
        .tracking(MonitorDesign.labelTracking(size: scale.label))
    }

    private func peakTag(scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(MonitorDesign.oklch(0.72, 0.09, 60).opacity(0.85))
                .frame(width: 5, height: 5)
            Text(verbatim: "↓ PEAK")
                .tracking(MonitorDesign.labelTracking(size: scale.label))
                .foregroundStyle(MonitorDesign.inkFaint)
            Text(verbatim: MonitorFormat.rate(history.netRxPeak))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
        }
        .font(MonitorDesign.labelFont(size: scale.label))
    }

    @ViewBuilder
    private func interfaceDetail(scale: MonitorDesign.TypeScale) -> some View {
        VStack(alignment: .leading, spacing: scale.caption * 0.34) {
            if let ip = privateIPv4 {
                // "IPv4" is notation; the "Status" key is a localized word.
                interfaceRow(key: "IPv4", value: ip, scale: scale)
            }
            interfaceRow(
                key: String(localized: "Status", comment: "Network widget: connectivity status row label."),
                value: statusLine, scale: scale, chips: pathChips)
        }
        .padding(.top, scale.caption * 0.35)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MonitorDesign.hairline.opacity(0.4))
                .frame(height: MonitorDesign.hairlineWidth)
        }
    }

    @ViewBuilder
    private func interfaceRow(
        key: String, value: String, scale: MonitorDesign.TypeScale, chips: [String] = []
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: key.uppercased())
                .font(MonitorDesign.labelFont(size: scale.caption * 0.86))
                .tracking(scale.caption * 0.10)
                .foregroundStyle(MonitorDesign.inkFaint)
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Text(verbatim: value)
                    .font(MonitorDesign.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    warnChip(chip, scale: scale)
                }
            }
        }
    }

    private func warnChip(_ text: String, scale: MonitorDesign.TypeScale) -> some View {
        Text(verbatim: text.uppercased())
            .font(MonitorDesign.labelFont(size: scale.label * 0.92))
            .tracking(scale.label * 0.10)
            .foregroundStyle(MonitorDesign.oklch(0.9, 0.03, 44))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(MonitorDesign.oklch(0.3, 0.05, 44, alpha: 0.28))
            )
            .overlay(
                Capsule().strokeBorder(MonitorDesign.oklch(0.5, 0.11, 40, alpha: 0.75), lineWidth: 1)
            )
    }

    private func healthCorner(errorCount: Int, scale: MonitorDesign.TypeScale) -> some View {
        let clean = errorCount == 0
        return HStack(spacing: 5) {
            Circle()
                .fill(clean ? MonitorDesign.signalSage : MonitorDesign.signalCoral)
                .frame(width: 5, height: 5)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                .shadow(color: (clean ? MonitorDesign.signalSage : MonitorDesign.signalCoral)
                    .opacity(0.6), radius: 2)
            if clean {
                Text("no errors · no drops")
            } else {
                // The count is data (verbatim); "errors/drops" is a phrase (localized).
                (Text(verbatim: "\(errorCount)").font(MonitorDesign.subFont(size: scale.label))
                    .foregroundStyle(MonitorDesign.inkMuted)
                 + Text(verbatim: " ") + Text("errors/drops"))
            }
        }
        .font(MonitorDesign.labelFont(size: scale.label * 0.98))
        .tracking(scale.label * 0.04)
        .foregroundStyle(clean ? MonitorDesign.inkFaint : MonitorDesign.oklch(0.86, 0.06, 40))
    }

    // MARK: - Shared rate readout

    private func dualRate(scale: MonitorDesign.TypeScale, heroScale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.35) {
            rateRow(label: "↓", labelColor: Self.rxColor,
                    text: MonitorFormat.rate(rxRate),
                    font: MonitorDesign.heroFont(size: scale.hero * heroScale),
                    unitSize: scale.hero * heroScale * 0.4)
            rateRow(label: "↑", labelColor: Self.txColor,
                    text: MonitorFormat.rate(txRate),
                    font: MonitorDesign.subFont(size: scale.sub),
                    unitSize: scale.sub * 0.62)
        }
    }

    /// Splits "6.2 MB/s" into a bold numeral and a whispered unit, like `rateHero`.
    private func rateRow(
        label: String, labelColor: Color, text: String, font: Font, unitSize: CGFloat
    ) -> some View {
        let parts = splitRate(text)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: label)
                .font(font)
                .foregroundStyle(labelColor)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: parts.value)
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkPrimary)
                if !parts.unit.isEmpty {
                    Text(verbatim: parts.unit)
                        .font(MonitorDesign.microFont(size: unitSize))
                        .foregroundStyle(MonitorDesign.inkFaint)
                }
            }
        }
    }

    // MARK: - Derived data

    private var rxRate: Double { system?.netRxBytesPerSec ?? 0 }
    private var txRate: Double { system?.netTxBytesPerSec ?? 0 }

    private var isOnline: Bool { (system?.netPath?.status ?? "unknown") == "satisfied" }

    private var sessionTotalBytes: Double {
        history.netRxSessionBytes + history.netTxSessionBytes
    }

    /// Active interface: first `isActive`, else highest rx+tx traffic.
    private var activeInterface: MonitorNetworkInterface? {
        Self.pickActiveInterface(system?.netInterfaces)
    }

    private var activeInterfaceType: String? { system?.netPath?.interfaceType }

    private var privateIPv4: String? {
        activeInterface?.addresses?.first(where: Self.isIPv4)
    }

    /// Connectivity word — localized (rendered verbatim as an already-localized
    /// value, since the same row helper also carries data like the IPv4 address).
    private var statusLine: String {
        isOnline
            ? String(localized: "connected", comment: "Network widget: the active interface has connectivity.")
            : String(localized: "offline", comment: "Network widget: the active interface has no connectivity.")
    }

    /// Path condition chips — localized words (constrained / expensive).
    private var pathChips: [String] {
        guard let path = system?.netPath else { return [] }
        var chips: [String] = []
        if path.isConstrained == true {
            chips.append(String(localized: "constrained", comment: "Network widget: the network path is constrained (Low Data Mode)."))
        }
        if path.isExpensive == true {
            chips.append(String(localized: "expensive", comment: "Network widget: the network path is expensive (cellular/metered)."))
        }
        return chips
    }

    /// Sum of the active interface's cumulative error/drop counters. `nil` when no
    /// interface detail exists at all (block absent); the health line renders only
    /// when this is non-nil, and whispers "no errors" when it is 0.
    private var errorCount: Int? {
        guard let iface = activeInterface else { return nil }
        let rxErr = iface.rxErrors ?? 0
        let txErr = iface.txErrors ?? 0
        let rxDrop = iface.rxDrops ?? 0
        return Int(min(rxErr + txErr + rxDrop, UInt64(Int.max)))
    }

    // MARK: - Pure helpers (nonisolated for tests)

    /// First `isActive == true`; else the interface with the highest rx+tx traffic;
    /// else the first. `nil` for an empty/absent list.
    nonisolated static func pickActiveInterface(
        _ interfaces: [MonitorNetworkInterface]?
    ) -> MonitorNetworkInterface? {
        guard let interfaces, !interfaces.isEmpty else { return nil }
        if let active = interfaces.first(where: { $0.isActive == true }) { return active }
        return interfaces.max {
            ($0.rxBytesPerSec + $0.txBytesPerSec) < ($1.rxBytesPerSec + $1.txBytesPerSec)
        }
    }

    /// A private-address string is IPv4 when it has a dot and no colon (IPv6).
    nonisolated static func isIPv4(_ address: String) -> Bool {
        address.contains(".") && !address.contains(":")
    }

    /// Splits a formatted rate ("6.2 MB/s") into ("6.2", "MB/s").
    nonisolated static func splitRate(_ text: String) -> (value: String, unit: String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[text.startIndex..<space]),
                String(text[text.index(after: space)...]))
    }

    private func splitRate(_ text: String) -> (value: String, unit: String) {
        Self.splitRate(text)
    }

    /// Last `count` samples of a series (never fewer than the series has).
    nonisolated static func tail(_ series: [Double], count: Int) -> [Double] {
        guard series.count > count else { return series }
        return Array(series.suffix(count))
    }

    private func tail(_ series: [Double], count: Int) -> [Double] {
        Self.tail(series, count: count)
    }
}

// MARK: - Previews

#if DEBUG
private func networkPreviewContext(size: MonitorWidgetSize) -> MonitorWidgetContext {
    var system = MonitorSystemSnapshot()
    system.netRxBytesPerSec = 6.2 * 1_048_576
    system.netTxBytesPerSec = 0.74 * 1_048_576
    system.netInterfaces = [
        MonitorNetworkInterface(
            name: "en0",
            rxBytesPerSec: 6.2 * 1_048_576,
            txBytesPerSec: 0.74 * 1_048_576,
            rxErrors: 3, txErrors: 0, rxDrops: 1,
            addresses: ["192.168.1.24", "fe80::14b2:9c3f:8e1a:22d7"],
            isActive: true
        ),
        MonitorNetworkInterface(name: "en1", rxBytesPerSec: 0, txBytesPerSec: 0, isActive: false)
    ]
    system.netPath = MonitorNetworkPath(
        status: "satisfied", interfaceType: "wifi", isConstrained: false, isExpensive: false
    )

    var history = MonitorHistorySnapshot()
    // 120 samples (history capacity) so the L preview's un-shrunk window has
    // real variance to show, not just the 60s tail M already uses.
    let rx: [Double] = (0..<120).map { 1_048_576 * (2 + 5 * abs(sin(Double($0) / 7))) }
    let tx: [Double] = (0..<120).map { 1_048_576 * (0.2 + 0.7 * abs(cos(Double($0) / 9))) }
    history.netRx = rx
    history.netTx = tx
    history.netRxPeak = 88 * 1_048_576
    history.netTxPeak = 12 * 1_048_576
    history.netRxSessionBytes = 41.7 * 1_073_741_824
    history.netTxSessionBytes = 6.3 * 1_073_741_824

    return MonitorWidgetContext(
        snapshot: MonitorSnapshot(timestamp: 0, system: system),
        history: history,
        placement: MonitorWidgetPlacement(kind: .network, size: size),
        isEditing: false,
        isAgentFleetEnabled: false,
        reduceMotion: false,
        now: Date()
    )
}

#Preview("Network S") {
    MonitorNetworkWidgetView(context: networkPreviewContext(size: .small))
        .frame(width: 150, height: 150)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Network M") {
    MonitorNetworkWidgetView(context: networkPreviewContext(size: .medium))
        .frame(width: 320, height: 150)
        .padding(32)
        .background(MonitorDesign.boardWash)
}

#Preview("Network L") {
    // L's board footprint is the same width as M but ~2× the height (2×2 vs
    // 2×1 cells) — the case that used to leave dead space under M's shrunk chart.
    MonitorNetworkWidgetView(context: networkPreviewContext(size: .large))
        .frame(width: 320, height: 300)
        .padding(32)
        .background(MonitorDesign.boardWash)
}
#endif
