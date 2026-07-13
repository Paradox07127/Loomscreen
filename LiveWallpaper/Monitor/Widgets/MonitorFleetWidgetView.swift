import SwiftUI
import LiveWallpaperCore

/// The Fleet instrument — the Pro centrepiece. A native port of the mock's fleet
/// renderers (`.claude/plan/monitor-design/index.html`, section 12). Every row
/// answers the engineer's three questions at a glance (SPEC §3.2.4):
/// **谁等我 / 谁在空转烧钱 / 谁在产出** — who is waiting on me, who is idling and
/// burning budget, who is producing.
///
/// Two live footprints (`allowedSizes == [.medium, .large]`):
///   • **M** (2×1, ≈378×196) — mock `fleet_m`: Action Strip + up to 3 non-idle
///     lanes side by side (dot·name·tool·timer·track + warning/context inline).
///   • **L** (2×2, ≈378×392) — mock `fleet_l`, densified with the `fleet_xl` rail's
///     extra readouts: Action Strip + up to 6 sorted rows stacked vertically, each
///     carrying tokens/$ · context-pressure bar · warning chip · recent-tool
///     sequence (names only). needsInput widens+brightens (coral edge + ask +
///     wait duration); idle/ended collapse to a calm subset.
/// S is retained as a defensive `fleet_s` port but is not in `allowedSizes`.
///
/// Privacy invariant (SPEC §3.4): only names / counts / times / tool-NAMES that
/// already live in the contract are rendered — never prompt text, tool arguments,
/// command output, or diffs.
///
/// Time: the in-status timers and the tick track's `now` are driven by
/// `context.now`, which the single board-level 1 Hz `TimelineView` advances (no
/// per-widget Timer). Isolated `#Preview`s wrap the view in their own TimelineView
/// so they stay live without the board.
struct MonitorFleetWidgetView: View {
    let context: MonitorWidgetContext

    private var reduceMotion: Bool { context.reduceMotion }

    /// Sessions the module actually has, or nil when the AI-Fleet module is off.
    /// The module hard-gates on the Pro `agentFleet` entitlement; when it is off
    /// `agents` is nil (contract), so a disabled module and an empty session list
    /// both fall through to the honest quiet state.
    private var sessions: [MonitorAgentSessionState]? { context.snapshot.agents }

    /// Per-placement tuning bag (read-only here; the settings popover writes it).
    private var options: [String: MonitorWidgetOptionValue] { context.placement.options }

    /// Sessions after the provider filter — the set every count / row derives from
    /// so a filtered board's aggregate matches its rows.
    private var visibleSessions: [MonitorAgentSessionState] {
        Self.filtered(sessions ?? [], provider: Self.providerFilter(options))
    }

    var body: some View {
        GeometryReader { geo in
            // The type scale is cell-derived. M is one board row tall, L is two;
            // dividing by the mock's row span (2 / 4) keeps M and L text at the
            // same density instead of doubling L's sizes.
            let rowSpan: CGFloat = context.placement.size == .large ? 4 : 2
            let cellHeight = geo.size.height / rowSpan
            content(cellHeight: cellHeight, now: context.now.timeIntervalSince1970)
        }
    }

    @ViewBuilder
    private func content(cellHeight: CGFloat, now: Double) -> some View {
        switch context.placement.size {
        case .small:
            smallBody(cellHeight: cellHeight, now: now)
        case .medium:
            mediumBody(cellHeight: cellHeight, now: now)
        case .large:
            largeBody(cellHeight: cellHeight, now: now)
        }
    }

    // MARK: - Derived fleet state

    private var ordered: [MonitorAgentSessionState] {
        Self.sorted(visibleSessions, mode: Self.sortMode(options))
    }

    private var counts: Self.Counts { Self.counts(visibleSessions) }

    private func totals(now: Double) -> Self.Totals { Self.totals(visibleSessions, now: now) }

    // MARK: - S (2×2) — defensive fleet_s port (not in allowedSizes)

    @ViewBuilder
    private func smallBody(cellHeight: CGFloat, now: Double) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        MonitorWidgetContainer(
            label: FleetStrings.title,
            systemImage: "point.3.filled.connected.trianglepath.dotted",
            cellHeight: cellHeight,
            status: { headerStatus(scale: scale) }
        ) {
            if let urgent = Self.mostUrgent(visibleSessions), !visibleSessions.isEmpty {
                VStack(alignment: .leading, spacing: scale.label * 0.6) {
                    actionStrip(scale: scale, now: now)
                    countCluster(scale: scale)
                    urgentRow(urgent, scale: scale, now: now)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if !visibleSessions.isEmpty {
                // Sessions present but none running/blocked (all idle/ended) — the
                // Action Strip + count cluster still answer "what's the fleet doing".
                VStack(alignment: .leading, spacing: scale.label * 0.6) {
                    actionStrip(scale: scale, now: now)
                    countCluster(scale: scale)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                quietState(scale: scale)
            }
        }
    }

    // MARK: - M (2×1) — Action Strip + up to 3 non-idle lanes

    @ViewBuilder
    private func mediumBody(cellHeight: CGFloat, now: Double) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        // The mock shows the top non-idle rows; a "+N more" whisper accounts for
        // everything the strip leaves off (idle rows + any overflow).
        let cap = Self.rowCap(options, fallback: 3)
        let rows = Self.mediumRows(ordered, cap: cap)
        let hiddenCount = visibleSessions.count - rows.count
        MonitorWidgetContainer(
            label: FleetStrings.title,
            systemImage: "point.3.filled.connected.trianglepath.dotted",
            cellHeight: cellHeight,
            status: { headerStatus(scale: scale) }
        ) {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: scale.label * 0.45) {
                    actionStrip(scale: scale, now: now)
                    HStack(alignment: .top, spacing: scale.label * 0.45) {
                        ForEach(rows) { session in
                            FleetCompactRow(session: session, now: now,
                                            reduceMotion: reduceMotion, scale: scale)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if hiddenCount > 0 {
                        moreWhisper(hiddenCount, scale: scale)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if !visibleSessions.isEmpty {
                // Sessions exist but all idle — no live row to show, yet the fleet
                // isn't empty; keep the aggregate (strip + counts), not "no sessions".
                VStack(alignment: .leading, spacing: scale.label * 0.5) {
                    actionStrip(scale: scale, now: now)
                    countCluster(scale: scale)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                quietState(scale: scale)
            }
        }
    }

    // MARK: - L (2×2) — Action Strip + up to 6 stacked rows (fleet_l + xl density)

    @ViewBuilder
    private func largeBody(cellHeight: CGFloat, now: Double) -> some View {
        let scale = MonitorDesign.TypeScale(cellHeight: cellHeight)
        let cap = Self.rowCap(options, fallback: 6)
        let rows = Self.largeRows(ordered, cap: cap)
        let hiddenCount = visibleSessions.count - rows.count
        MonitorWidgetContainer(
            label: FleetStrings.title,
            systemImage: "point.3.filled.connected.trianglepath.dotted",
            cellHeight: cellHeight,
            status: { headerStatus(scale: scale) }
        ) {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: scale.label * 0.4) {
                    actionStrip(scale: scale, now: now)
                    VStack(alignment: .leading, spacing: scale.label * 0.4) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                            // The lead row gets the full rail treatment (recent-tool
                            // sequence); deeper rows stay lean so up to 6 rows fit 2×2.
                            FleetFullRow(session: session, now: now, isLead: index == 0,
                                         reduceMotion: reduceMotion, scale: scale)
                        }
                    }
                    if hiddenCount > 0 {
                        moreWhisper(hiddenCount, scale: scale)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if !visibleSessions.isEmpty {
                VStack(alignment: .leading, spacing: scale.label * 0.5) {
                    actionStrip(scale: scale, now: now)
                    countCluster(scale: scale)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                quietState(scale: scale)
            }
        }
    }

    // MARK: - Header status (chd right slot: "N agents" + state dot)

    @ViewBuilder
    private func headerStatus(scale: MonitorDesign.TypeScale) -> some View {
        let n = visibleSessions.count
        HStack(spacing: scale.label * 0.5) {
            Text(verbatim: FleetStrings.agentCount(n))
                .font(MonitorDesign.subFont(size: scale.label))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
            // warm normally, coral when someone is waiting (mock `counts.needsInput?"crit":"warm"`).
            Circle()
                .fill(counts.needsInput > 0 ? MonitorDesign.signalCoral : MonitorDesign.signalAmber)
                .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                .shadow(color: (counts.needsInput > 0 ? MonitorDesign.signalCoral : MonitorDesign.signalAmber).opacity(0.6),
                        radius: 3)
        }
    }

    // MARK: - Action Strip (aggregate one-liner)

    /// "1 等你 · 3 跑 · 5h 42m · $12.4" — the aggregate action line (mock
    /// `fleetActionStrip`). Coral-alert border+glow when someone waits or a warning
    /// is live; dimmed calm otherwise.
    @ViewBuilder
    private func actionStrip(scale: MonitorDesign.TypeScale, now: Double) -> some View {
        let c = counts
        let t = totals(now: now)
        let alert = c.needsInput > 0 || t.anyWarn
        HStack(spacing: scale.label * 0.5) {
            if c.needsInput > 0 {
                actionSeg(dot: MonitorDesign.signalCoral, count: c.needsInput,
                          keyword: FleetStrings.awaitingYou, emphatic: true, scale: scale)
                actionDot(scale: scale)
            }
            if c.running > 0 {
                actionSeg(dot: MonitorDesign.signalAmber, count: c.running,
                          keyword: FleetStrings.runningKeyword, emphatic: false, scale: scale)
                actionDot(scale: scale)
            }
            if t.longest > 0 {
                Text(verbatim: MonitorFormat.mmss(t.longest))
                    .font(MonitorDesign.subFont(size: scale.caption))
                    .monospacedDigit()
                    .foregroundStyle(MonitorDesign.inkMuted)
                actionDot(scale: scale)
            }
            Text(verbatim: MonitorFormat.usd(t.cost))
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
            if t.anyWarn && c.needsInput == 0 {
                actionDot(scale: scale)
                HStack(spacing: scale.label * 0.34) {
                    Circle()
                        .fill(MonitorDesign.signalCoral)
                        .frame(width: scale.label * 0.5, height: scale.label * 0.5)
                        .shadow(color: MonitorDesign.signalCoral.opacity(0.6), radius: 3)
                    Text(FleetStrings.warnKeyword)
                        .font(MonitorDesign.labelFont(size: scale.caption * 0.86))
                        .tracking(scale.caption * 0.04)
                        .foregroundStyle(MonitorDesign.signalCoral)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, scale.label * 0.6)
        .padding(.vertical, scale.label * 0.55)
        .background(
            RoundedRectangle(cornerRadius: max(6, cellRadius - 4), style: .continuous)
                .fill(actionStripFill(alert: alert))
                .overlay(
                    RoundedRectangle(cornerRadius: max(6, cellRadius - 4), style: .continuous)
                        .strokeBorder(alert ? MonitorDesign.signalCoral.opacity(0.85)
                                            : MonitorDesign.panelStroke,
                                      lineWidth: 1)
                )
        )
        .shadow(color: alert ? MonitorDesign.signalCoral.opacity(0.35) : .clear, radius: alert ? 8 : 0)
        .opacity(alert ? 1 : 0.72)
    }

    private var cellRadius: CGFloat { max(MonitorDesign.cornerRadiusMin, 10.9) }

    private func actionStripFill(alert: Bool) -> LinearGradient {
        if alert {
            return LinearGradient(
                colors: [MonitorDesign.oklch(0.30, 0.05, 34, alpha: 0.92),
                         MonitorDesign.oklch(0.235, 0.03, 34, alpha: 0.86)],
                startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(
            colors: [MonitorDesign.oklch(0.24, 0.013, 74, alpha: 0.9),
                     MonitorDesign.oklch(0.20, 0.012, 74, alpha: 0.8)],
            startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private func actionSeg(dot: Color, count: Int, keyword: LocalizedStringKey,
                           emphatic: Bool, scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.label * 0.34) {
            Circle()
                .fill(dot)
                .frame(width: scale.caption * 0.55, height: scale.caption * 0.55)
                .shadow(color: dot.opacity(0.6), radius: 3)
            Text(verbatim: "\(count)")
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(emphatic ? MonitorDesign.oklch(0.94, 0.05, 40) : MonitorDesign.inkMuted)
            Text(keyword)
                .font(MonitorDesign.labelFont(size: scale.caption * 0.86))
                .tracking(scale.caption * 0.04)
                .foregroundStyle(MonitorDesign.inkFaint)
        }
    }

    private func actionDot(scale: MonitorDesign.TypeScale) -> some View {
        Circle()
            .fill(MonitorDesign.inkFaint)
            .frame(width: 3, height: 3)
            .opacity(0.5)
    }

    // MARK: - S: status-count cluster + most-urgent row

    /// Status count dots (mock `.fcounts`): "3 running · 1 waiting · 2 idle · 1 done".
    @ViewBuilder
    private func countCluster(scale: MonitorDesign.TypeScale) -> some View {
        let c = counts
        HStack(spacing: scale.caption * 0.55) {
            if c.running > 0 { countChip(MonitorDesign.signalAmber, c.running, FleetStrings.runningKeyword, scale) }
            if c.needsInput > 0 { countChip(MonitorDesign.signalCoral, c.needsInput, FleetStrings.waitingKeyword, scale) }
            if c.idle > 0 { countChip(MonitorDesign.signalIdle, c.idle, FleetStrings.idleKeyword, scale) }
            if c.ended > 0 { countChip(MonitorDesign.signalSage, c.ended, FleetStrings.doneKeyword, scale) }
        }
    }

    @ViewBuilder
    private func countChip(_ color: Color, _ count: Int, _ word: LocalizedStringKey,
                           _ scale: MonitorDesign.TypeScale) -> some View {
        HStack(spacing: scale.caption * 0.4) {
            Circle()
                .fill(color)
                .frame(width: scale.caption * 0.6, height: scale.caption * 0.6)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            (Text(verbatim: "\(count) ") + Text(word))
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(MonitorDesign.inkMuted)
        }
    }

    /// The single most-urgent session — name + a 等你 pill (if blocked) + its
    /// in-status timer + a slim tick track (mock `.furgent`).
    @ViewBuilder
    private func urgentRow(_ session: MonitorAgentSessionState,
                           scale: MonitorDesign.TypeScale, now: Double) -> some View {
        let blocked = session.status == .needsInput
        VStack(alignment: .leading, spacing: scale.label * 0.4) {
            HStack(spacing: scale.label * 0.45) {
                BreathingDot(color: blocked ? MonitorDesign.signalCoral : MonitorDesign.signalAmber,
                             size: scale.caption * 0.66,
                             animated: !reduceMotion && (blocked || session.status == .running))
                Text(verbatim: session.projectName)
                    .font(MonitorDesign.subFont(size: scale.caption))
                    .foregroundStyle(MonitorDesign.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if blocked {
                    Text(FleetStrings.awaitingYou)
                        .font(MonitorDesign.labelFont(size: scale.caption * 0.82))
                        .tracking(scale.caption * 0.02)
                        .foregroundStyle(MonitorDesign.oklch(0.16, 0.02, 34))
                        .padding(.horizontal, scale.caption * 0.38)
                        .padding(.vertical, scale.caption * 0.1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(LinearGradient(colors: [MonitorDesign.signalCoral,
                                                              MonitorDesign.oklch(0.64, 0.16, 34)],
                                                     startPoint: .top, endPoint: .bottom))
                        )
                }
                Spacer(minLength: scale.label * 0.4)
                if let timer = Self.timerText(for: session, now: now) {
                    Text(verbatim: timer.text)
                        .font(MonitorDesign.subFont(size: scale.caption))
                        .monospacedDigit()
                        .foregroundStyle(blocked ? MonitorDesign.oklch(0.9, 0.06, 40) : MonitorDesign.signalAmber)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            TickTrack(events: session.recentEventTimes ?? [], now: now, span: 180,
                      tint: blocked ? MonitorDesign.signalCoral : MonitorDesign.signalAmber)
                .frame(height: 14)
                .padding(.top, scale.label * 0.15)
        }
        .padding(.top, scale.label * 0.55)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MonitorDesign.hairline.opacity(0.5))
                .frame(height: 1)
        }
    }

    // MARK: - Quiet state

    /// Module off, or on but with no active sessions — the honest quiet whisper
    /// (mock: "no active sessions"). No fabricated rows.
    @ViewBuilder
    private func quietState(scale: MonitorDesign.TypeScale) -> some View {
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            Spacer(minLength: 0)
            HStack(spacing: scale.label * 0.5) {
                Circle()
                    .fill(MonitorDesign.signalIdle)
                    .frame(width: scale.caption * 0.6, height: scale.caption * 0.6)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                Text(FleetStrings.noActiveSessions)
                    .font(MonitorDesign.captionFont(size: scale.caption))
                    .foregroundStyle(MonitorDesign.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - "+N more" whisper

    @ViewBuilder
    private func moreWhisper(_ count: Int, scale: MonitorDesign.TypeScale) -> some View {
        Text(verbatim: FleetStrings.moreCount(count))
            .font(MonitorDesign.labelFont(size: scale.label))
            .tracking(MonitorDesign.labelTracking(size: scale.label))
            .foregroundStyle(MonitorDesign.inkFaint)
            .opacity(0.8)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Compact row (M column)

/// One agent lane in the M board (mock `fleetStrip(a, "compact")`): a vertical
/// card — header (dot · project · timer) → ask (needsInput) → tool chip → warning
/// + context → tick track. `idle`/`ended` collapse to a calm subset.
private struct FleetCompactRow: View {
    let session: MonitorAgentSessionState
    let now: Double
    let reduceMotion: Bool
    let scale: MonitorDesign.TypeScale

    private var status: MonitorAgentStatus { session.status }
    private var accentColor: Color { MonitorFleetWidgetView.accentColor(status) }
    private var isBlocked: Bool { status == .needsInput }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.label * 0.5) {
            header
            if isBlocked {
                FleetAskLine(session: session, scale: scale)
            }
            if !isBlocked, status != .idle, let detail = session.statusDetail, !detail.isEmpty {
                FleetToolChip(text: detail, scale: scale)
            }
            if status == .running || isBlocked {
                utilityLine
                TickTrack(events: session.recentEventTimes ?? [], now: now, span: 180,
                          tint: isBlocked ? MonitorDesign.signalCoral : MonitorDesign.signalAmber)
                    .frame(height: 16)
            } else if status == .ended {
                FleetBudgetLabel(session: session, scale: scale, sizeScale: 0.88)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.label * 0.8)
        .padding(.vertical, scale.label * 0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FleetRowStyle.fill(isBlocked: isBlocked))
        .overlay(alignment: .leading) {
            FleetRowStyle.accentBar(color: accentColor, isBlocked: isBlocked, scale: scale)
        }
        .clipShape(RoundedRectangle(cornerRadius: FleetRowStyle.radius, style: .continuous))
        .overlay(FleetRowStyle.border(isBlocked: isBlocked))
        .opacity(status == .ended ? 0.55 : (status == .idle ? 0.6 : 1))
    }

    private var header: some View {
        HStack(spacing: scale.label * 0.45) {
            BreathingDot(color: accentColor, size: scale.caption * 0.62,
                         animated: !reduceMotion && (status == .running || isBlocked))
            FleetProviderBadge(provider: session.provider, isBlocked: isBlocked, scale: scale)
            Text(verbatim: session.projectName)
                .font(MonitorDesign.subFont(size: scale.caption))
                .foregroundStyle(status == .ended ? MonitorDesign.inkMuted
                                 : (isBlocked ? MonitorDesign.oklch(0.97, 0.02, 40) : MonitorDesign.inkPrimary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: scale.label * 0.3)
            FleetRowTimer(session: session, now: now, scale: scale)
        }
    }

    /// The tight utility line for M: warning chip (if any) + context-pressure bar.
    @ViewBuilder
    private var utilityLine: some View {
        let ctx = MonitorFleetWidgetView.contextBand(for: session)
        let warn = MonitorFleetWidgetView.warningLabel(for: session)
        if warn != nil || ctx != nil {
            HStack(spacing: scale.label * 0.5) {
                if let warn {
                    FleetWarningChip(warn: warn, scale: scale)
                }
                if let ctx {
                    FleetContextBar(ctx: ctx, scale: scale)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Full row (L column)

/// One agent row in the L board (mock `fleetStrip(a, "full")` densified with the
/// `fleet_xl` rail's readouts): header (dot · provider · name · timer) → ask
/// (needsInput) → meta (tool · model · branch) → recent-tool sequence → tick track
/// → footer (budget · context · warning). `idle` collapses to header only; `ended`
/// collapses to header + final budget.
private struct FleetFullRow: View {
    let session: MonitorAgentSessionState
    let now: Double
    /// The top row of the L stack — it alone carries the recent-tool sequence.
    var isLead: Bool = false
    let reduceMotion: Bool
    let scale: MonitorDesign.TypeScale

    private var status: MonitorAgentStatus { session.status }
    private var accentColor: Color { MonitorFleetWidgetView.accentColor(status) }
    private var isBlocked: Bool { status == .needsInput }
    private var isLive: Bool { status == .running || isBlocked }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.label * 0.4) {
            header
            if isBlocked {
                FleetAskLine(session: session, scale: scale)
            }
            if status == .running {
                metaLine
            }
            if isLead, isLive, let tools = session.recentTools, !tools.isEmpty {
                FleetRecentTools(tools: tools, max: 3, scale: scale)
            }
            if isLive {
                TickTrack(events: session.recentEventTimes ?? [], now: now, span: 180,
                          tint: isBlocked ? MonitorDesign.signalCoral : MonitorDesign.signalAmber)
                    .frame(height: scale.caption * 1.15)
                footer
            } else if status == .ended {
                footer
            }
        }
        .padding(.horizontal, scale.label * 0.7)
        .padding(.vertical, status == .idle ? scale.label * 0.42 : scale.label * 0.55)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(FleetRowStyle.fill(isBlocked: isBlocked))
        .overlay(alignment: .leading) {
            FleetRowStyle.accentBar(color: accentColor, isBlocked: isBlocked, scale: scale)
        }
        .clipShape(RoundedRectangle(cornerRadius: FleetRowStyle.radius, style: .continuous))
        .overlay(FleetRowStyle.border(isBlocked: isBlocked))
        .opacity(status == .ended ? 0.55 : (status == .idle ? 0.6 : 1))
    }

    private var header: some View {
        HStack(spacing: scale.label * 0.45) {
            BreathingDot(color: accentColor, size: scale.caption * 0.62,
                         animated: !reduceMotion && isLive)
            FleetProviderBadge(provider: session.provider, isBlocked: isBlocked, scale: scale)
            Text(verbatim: session.projectName)
                .font(MonitorDesign.subFont(size: scale.caption))
                .foregroundStyle(status == .ended ? MonitorDesign.inkMuted
                                 : (isBlocked ? MonitorDesign.oklch(0.97, 0.02, 40) : MonitorDesign.inkPrimary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: scale.label * 0.3)
            FleetRowTimer(session: session, now: now, scale: scale)
        }
    }

    /// Running rows carry the current tool (verbatim, redacted name only) plus a
    /// dim model·branch tail. needsInput leads with the ask, so it skips this.
    @ViewBuilder
    private var metaLine: some View {
        let hasTool = !(session.statusDetail ?? "").isEmpty
        let tail = modelBranchTail
        if hasTool || tail != nil {
            HStack(spacing: scale.label * 0.4) {
                if let detail = session.statusDetail, !detail.isEmpty {
                    FleetToolChip(text: detail, scale: scale)
                }
                if let tail {
                    Text(verbatim: tail)
                        .font(MonitorDesign.captionFont(size: scale.caption * 0.82))
                        .foregroundStyle(MonitorDesign.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// "sonnet · ⑂feat/agent-wallpaper" — both data, both expendable (truncate).
    private var modelBranchTail: String? {
        var parts: [String] = []
        if let model = session.model, !model.isEmpty { parts.append(model) }
        if let branch = session.gitBranch, !branch.isEmpty { parts.append("⑂" + branch) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Budget on the left, context + warning on the right (mock `.ffoot`).
    @ViewBuilder
    private var footer: some View {
        let ctx = isLive ? MonitorFleetWidgetView.contextBand(for: session) : nil
        let warn = isLive ? MonitorFleetWidgetView.warningLabel(for: session) : nil
        let hasBudget = session.costUSD != nil || session.tokens != .zero
        if hasBudget || ctx != nil || warn != nil {
            HStack(spacing: scale.label * 0.5) {
                if hasBudget {
                    FleetBudgetLabel(session: session, scale: scale, sizeScale: 0.86)
                }
                Spacer(minLength: scale.label * 0.3)
                if let warn {
                    FleetWarningChip(warn: warn, scale: scale)
                }
                if let ctx {
                    FleetContextBar(ctx: ctx, scale: scale)
                }
            }
        }
    }
}

// MARK: - Shared row pieces

/// Shared background / accent / border tokens so the M and L rows read as one
/// material (mock `.frow`), coral-tinted when a row is blocked on the engineer.
private enum FleetRowStyle {
    static var radius: CGFloat { max(6, MonitorDesign.cornerRadiusMin) }

    static func fill(isBlocked: Bool) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(isBlocked
                  ? LinearGradient(colors: [MonitorDesign.oklch(0.315, 0.055, 34, alpha: 0.94),
                                            MonitorDesign.oklch(0.235, 0.032, 34, alpha: 0.9)],
                                   startPoint: .top, endPoint: .bottom)
                  : LinearGradient(colors: [MonitorDesign.oklch(0.255, 0.014, 74, alpha: 0.92),
                                            MonitorDesign.oklch(0.205, 0.013, 74, alpha: 0.86)],
                                   startPoint: .top, endPoint: .bottom))
    }

    static func accentBar(color: Color, isBlocked: Bool, scale: MonitorDesign.TypeScale) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: 2.5)
            .padding(.vertical, scale.label * 0.6)
            .shadow(color: color.opacity(isBlocked ? 0.9 : 0.6), radius: isBlocked ? 6 : 4)
    }

    static func border(isBlocked: Bool) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(isBlocked ? MonitorDesign.signalCoral.opacity(0.85) : MonitorDesign.panelStroke,
                          lineWidth: 1)
    }
}

/// Provider chip ("CLAUDE" / "CODEX"), coral when the row is blocked (mock `.prov`).
private struct FleetProviderBadge: View {
    let provider: MonitorAgentProvider
    let isBlocked: Bool
    let scale: MonitorDesign.TypeScale

    var body: some View {
        Text(verbatim: provider.rawValue.uppercased())
            .font(MonitorDesign.labelFont(size: scale.caption * 0.7))
            .tracking(scale.caption * 0.06)
            .foregroundStyle(MonitorDesign.bg1)
            .padding(.horizontal, scale.caption * 0.34)
            .padding(.vertical, scale.caption * 0.12)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(fill)
            )
            .fixedSize()
    }

    private var fill: LinearGradient {
        if isBlocked {
            return LinearGradient(colors: [MonitorDesign.signalCoral, MonitorDesign.oklch(0.64, 0.16, 34)],
                                  startPoint: .top, endPoint: .bottom)
        }
        switch provider {
        case .claude:
            return LinearGradient(colors: [MonitorDesign.oklch(0.72, 0.02, 78), MonitorDesign.oklch(0.66, 0.02, 78)],
                                  startPoint: .top, endPoint: .bottom)
        case .codex:
            return LinearGradient(colors: [MonitorDesign.oklch(0.64, 0.014, 76), MonitorDesign.oklch(0.58, 0.014, 76)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The in-status timer, or a whispered status word for idle (mock `.timer`/`.fstat`).
private struct FleetRowTimer: View {
    let session: MonitorAgentSessionState
    let now: Double
    let scale: MonitorDesign.TypeScale

    var body: some View {
        if let timer = MonitorFleetWidgetView.timerText(for: session, now: now) {
            Text(verbatim: timer.text)
                .font(MonitorDesign.subFont(size: scale.caption))
                .monospacedDigit()
                .foregroundStyle(Self.color(for: session.status))
                .lineLimit(1)
                .layoutPriority(1)
        } else {
            Text(MonitorFleetWidgetView.statusWord(session.status))
                .font(MonitorDesign.labelFont(size: scale.caption * 0.82))
                .tracking(scale.caption * 0.12)
                .foregroundStyle(MonitorDesign.inkFaint)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    static func color(for status: MonitorAgentStatus) -> Color {
        switch status {
        case .needsInput: return MonitorDesign.oklch(0.9, 0.06, 40)
        case .running: return MonitorDesign.signalAmber
        default: return MonitorDesign.inkFaint
        }
    }
}

/// The needsInput ASK — the approval prompt the engineer must act on. `statusDetail`
/// is a redacted verb/tool name only, safe to render verbatim (mock `.ask`).
private struct FleetAskLine: View {
    let session: MonitorAgentSessionState
    let scale: MonitorDesign.TypeScale

    var body: some View {
        if let detail = session.statusDetail, !detail.isEmpty {
            Text(verbatim: detail)
                .font(MonitorDesign.captionFont(size: scale.caption * 0.98))
                .foregroundStyle(MonitorDesign.oklch(0.95, 0.028, 40))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(FleetStrings.needsYou)
                .font(MonitorDesign.subFont(size: scale.caption * 0.98))
                .foregroundStyle(MonitorDesign.signalCoral)
                .lineLimit(1)
        }
    }
}

/// The current-tool chip — a redacted, mono, name-only pill (mock `.chip`).
private struct FleetToolChip: View {
    let text: String
    let scale: MonitorDesign.TypeScale

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: scale.caption * 0.82, weight: .regular, design: .monospaced))
            .foregroundStyle(MonitorDesign.inkMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, scale.caption * 0.42)
            .padding(.vertical, scale.caption * 0.16)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(MonitorDesign.bg2.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(MonitorDesign.hairline.opacity(0.6), lineWidth: 1)
                    )
            )
    }
}

/// Recent-tool sequence — the last few tool NAMES (no arguments), arrow-joined and
/// status-tinted (mock `.rtools`). The `fleet_xl` density flourish carried into L.
private struct FleetRecentTools: View {
    let tools: [MonitorAgentToolEvent]
    let max: Int
    let scale: MonitorDesign.TypeScale

    var body: some View {
        let shown = Array(tools.suffix(max))
        HStack(spacing: scale.caption * 0.28) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, tool in
                if index > 0 {
                    Text(verbatim: "›")
                        .font(MonitorDesign.captionFont(size: scale.caption * 0.72))
                        .foregroundStyle(MonitorDesign.inkFaint.opacity(0.6))
                }
                Text(verbatim: tool.name)
                    .font(.system(size: scale.caption * 0.74, weight: .regular, design: .monospaced))
                    .foregroundStyle(MonitorFleetWidgetView.toolTint(tool.ok))
                    .lineLimit(1)
                    .padding(.horizontal, scale.caption * 0.3)
                    .padding(.vertical, scale.caption * 0.06)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(MonitorDesign.oklch(0.22, 0.011, 74, alpha: 0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(MonitorDesign.hairline.opacity(0.5), lineWidth: 1)
                            )
                    )
            }
            Spacer(minLength: 0)
        }
    }
}

/// context-pressure micro-bar (mock `.ctxbar`): "ctx ▮▮▮ 91%", coral near
/// compaction. `ContextBand.fraction` is 0…1.
private struct FleetContextBar: View {
    let ctx: MonitorFleetWidgetView.ContextBand
    let scale: MonitorDesign.TypeScale

    var body: some View {
        HStack(spacing: scale.caption * 0.4) {
            Text(FleetStrings.ctxLabel)
                .font(MonitorDesign.labelFont(size: scale.caption * 0.76))
                .tracking(scale.caption * 0.08)
                .foregroundStyle(MonitorDesign.inkFaint)
            GeometryReader { g in
                Capsule(style: .continuous)
                    .fill(MonitorDesign.track)
                    .overlay(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(ctx.fill)
                            .frame(width: g.size.width * CGFloat(min(max(ctx.fraction, 0), 1)))
                    }
            }
            .frame(width: scale.caption * 3.4, height: scale.caption * 0.4)
            Text(verbatim: ctx.percentText)
                .font(MonitorDesign.subFont(size: scale.caption * 0.82))
                .monospacedDigit()
                .foregroundStyle(ctx.band == .crit ? MonitorDesign.oklch(0.9, 0.06, 40) : MonitorDesign.inkMuted)
        }
        .fixedSize()
    }
}

/// Warning chip — the "burning budget" signal (mock `.wchip`): amber for `stale`,
/// coral for everything else (toolLoop / unknown tokens).
private struct FleetWarningChip: View {
    let warn: MonitorFleetWidgetView.WarningInfo
    let scale: MonitorDesign.TypeScale

    var body: some View {
        HStack(spacing: scale.caption * 0.35) {
            Circle()
                .fill(warn.isStale ? MonitorDesign.signalAmber : MonitorDesign.signalCoral)
                .frame(width: scale.caption * 0.5, height: scale.caption * 0.5)
                .shadow(color: (warn.isStale ? MonitorDesign.signalAmber : MonitorDesign.signalCoral).opacity(0.6),
                        radius: 3)
            Text(FleetStrings.warningLabel(warn.text))
                .font(MonitorDesign.labelFont(size: scale.caption * 0.76))
                .tracking(scale.caption * 0.04)
                .foregroundStyle(warn.isStale ? MonitorDesign.oklch(0.9, 0.07, 80)
                                              : MonitorDesign.oklch(0.92, 0.06, 44))
                .lineLimit(1)
        }
        .padding(.horizontal, scale.caption * 0.42)
        .padding(.vertical, scale.caption * 0.14)
        .background(
            Capsule(style: .continuous)
                .fill(warn.isStale ? MonitorDesign.oklch(0.3, 0.05, 78, alpha: 0.35)
                                   : MonitorDesign.oklch(0.34, 0.07, 38, alpha: 0.4))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(warn.isStale ? MonitorDesign.oklch(0.5, 0.1, 78, alpha: 0.7)
                                                   : MonitorDesign.oklch(0.5, 0.13, 40, alpha: 0.7),
                                      lineWidth: 1)
                )
        )
    }
}

/// Per-session budget readout — "$1.08 · 84K tok" (mock `.ubudget`); the dollar
/// figure leads in ink, the token count whispers. Renders nothing when neither is
/// known (the caller gates on that).
private struct FleetBudgetLabel: View {
    let session: MonitorAgentSessionState
    let scale: MonitorDesign.TypeScale
    /// Multiplier on the caption size (M ended footer uses 0.88; L footer 0.86).
    var sizeScale: CGFloat = 0.88

    var body: some View {
        let tok = session.tokens.input + session.tokens.output
        (
            Text(verbatim: session.costUSD != nil ? MonitorFormat.usd(session.costUSD) : "")
                .foregroundColor(MonitorDesign.inkMuted)
            + Text(verbatim: session.costUSD != nil && tok > 0 ? " · " : "")
                .foregroundColor(MonitorDesign.inkFaint)
            + Text(verbatim: tok > 0 ? MonitorFormat.tokens(tok) + " tok" : "")
                .foregroundColor(MonitorDesign.inkFaint)
        )
        .font(MonitorDesign.subFont(size: scale.caption * sizeScale))
        .monospacedDigit()
        .lineLimit(1)
    }
}

// MARK: - Localizable word literals (catalog keys)
//
// Every user-facing WORD the Fleet widget renders lives here as a
// `LocalizedStringKey`, so `Text(key)` resolves through the app's string catalog
// (all four languages). Reuses the strings already in the catalog where they
// exist. Data — project names, tool names, timers, counts — is NEVER localized:
// it is rendered via `Text(verbatim:)`.
private enum FleetStrings {
    /// The widget title feeds `MonitorWidgetContainer(label:)`, which renders it
    /// verbatim + uppercased on the wallpaper — a short instrument acronym.
    static let title = "Fleet"

    // Computed (not stored) so the enum stays Sendable under strict concurrency.
    static var noActiveSessions: LocalizedStringKey { "No active sessions" }

    // Action-Strip + count-cluster + row keywords (English source keys).
    static var awaitingYou: LocalizedStringKey { "needs you" }
    static var runningKeyword: LocalizedStringKey { "running" }
    static var warnKeyword: LocalizedStringKey { "warn" }
    static var waitingKeyword: LocalizedStringKey { "waiting" }
    static var idleKeyword: LocalizedStringKey { "idle" }
    static var doneKeyword: LocalizedStringKey { "done" }

    // Row copy.
    static var needsYou: LocalizedStringKey { "needs you" }
    static var ended: LocalizedStringKey { "ended" }
    static var ctxLabel: LocalizedStringKey { "ctx" }

    /// "3 agents" — count is data, so composed with a verbatim number at the call
    /// site rather than a format string. The word is the only localizable part.
    static func agentCount(_ n: Int) -> String {
        String(localized: "\(n) agents", comment: "Fleet widget header: number of tracked agent sessions.")
    }

    static func moreCount(_ n: Int) -> String {
        String(localized: "+\(n) more", comment: "Fleet widget: whisper for sessions not shown as rows.")
    }

    /// Localized display label for a raw warning token (the token itself is data).
    /// Known tokens have dedicated catalog keys; an unknown token surfaces verbatim.
    static func warningLabel(_ raw: String) -> LocalizedStringKey {
        LocalizedStringKey(raw)
    }
}

// MARK: - Pure fleet logic (tested)

extension MonitorFleetWidgetView {

    nonisolated static func accentColor(_ status: MonitorAgentStatus) -> Color {
        switch status {
        case .running: return MonitorDesign.signalAmber
        case .needsInput: return MonitorDesign.signalCoral
        case .ended: return MonitorDesign.signalSage
        case .idle, .unknown: return MonitorDesign.signalIdle
        }
    }

    /// The per-row status word (mock `STAT_LABEL`) as a catalog key. needsInput →
    /// "needs you". Rendered via `Text(_ key:)`, so it localizes at the call site.
    nonisolated static func statusWord(_ status: MonitorAgentStatus) -> LocalizedStringKey {
        switch status {
        case .running: return FleetStrings.runningKeyword
        case .needsInput: return FleetStrings.needsYou
        case .idle: return FleetStrings.idleKeyword
        case .ended: return FleetStrings.ended
        case .unknown: return FleetStrings.idleKeyword
        }
    }

    /// Recent-tool tint (mock `.rt.ok/.err`): a completed tool reads brighter, an
    /// errored tool coral, a still-pending one (`ok == nil`) neutral. Codex events
    /// carry no result flag yet, so they all read neutral (a data gap, not a bug).
    nonisolated static func toolTint(_ ok: Bool?) -> Color {
        switch ok {
        case .some(true): return MonitorDesign.inkMuted
        case .some(false): return MonitorDesign.oklch(0.86, 0.08, 40)
        case .none: return MonitorDesign.inkFaint
        }
    }

    // MARK: settings (read side; the popover writes these keys)

    enum Option {
        static let maxRows = "fleetMaxRows"
        static let provider = "fleetProvider"
        static let sort = "fleetSort"
    }

    enum SortMode: String, Equatable {
        case attention   // §3.2.4 default: needsInput > running > idle > ended, then recency
        case recent      // most-recent event first
        case cost        // highest live spend first
    }

    /// Provider filter from the option bag; nil == show all (the default).
    nonisolated static func providerFilter(_ options: [String: MonitorWidgetOptionValue]) -> MonitorAgentProvider? {
        switch options[Option.provider]?.stringValue {
        case MonitorAgentProvider.claude.rawValue: return .claude
        case MonitorAgentProvider.codex.rawValue: return .codex
        default: return nil
        }
    }

    nonisolated static func filtered(_ sessions: [MonitorAgentSessionState],
                                     provider: MonitorAgentProvider?) -> [MonitorAgentSessionState] {
        guard let provider else { return sessions }
        return sessions.filter { $0.provider == provider }
    }

    nonisolated static func sortMode(_ options: [String: MonitorWidgetOptionValue]) -> SortMode {
        SortMode(rawValue: options[Option.sort]?.stringValue ?? "") ?? .attention
    }

    /// Per-size row cap: the persisted value clamped to `1…fallback` (the mock max
    /// for that size), or `fallback` when unset.
    nonisolated static func rowCap(_ options: [String: MonitorWidgetOptionValue], fallback: Int) -> Int {
        guard let raw = options[Option.maxRows]?.numberValue, raw.isFinite else { return fallback }
        return min(max(Int(raw), 1), fallback)
    }

    // MARK: sorting

    /// SPEC §3.2.4 ordering: `needsInput > running > idle > ended` (by
    /// `attentionPriority` desc), then most-recent first (`lastEventAt` desc) so
    /// equal-status rows surface the freshest. `unknown` sorts below idle (its
    /// attentionPriority = 1), matching the enum contract.
    nonisolated static func sorted(_ sessions: [MonitorAgentSessionState]) -> [MonitorAgentSessionState] {
        sessions.sorted { lhs, rhs in
            let lp = lhs.status.attentionPriority, rp = rhs.status.attentionPriority
            if lp != rp { return lp > rp }
            return lhs.lastEventAt > rhs.lastEventAt
        }
    }

    /// Ordering under a user-chosen sort mode; `.attention` is the §3.2.4 default.
    nonisolated static func sorted(_ sessions: [MonitorAgentSessionState],
                                   mode: SortMode) -> [MonitorAgentSessionState] {
        switch mode {
        case .attention:
            return sorted(sessions)
        case .recent:
            return sessions.sorted { $0.lastEventAt > $1.lastEventAt }
        case .cost:
            return sessions.sorted { lhs, rhs in
                let lc = lhs.costUSD ?? -1, rc = rhs.costUSD ?? -1
                if lc != rc { return lc > rc }
                return lhs.lastEventAt > rhs.lastEventAt
            }
        }
    }

    /// M shows the top non-idle rows (mock `fleet_m`). idle rows fold into "+N more".
    nonisolated static func mediumRows(_ sorted: [MonitorAgentSessionState]) -> [MonitorAgentSessionState] {
        mediumRows(sorted, cap: 3)
    }

    nonisolated static func mediumRows(_ sorted: [MonitorAgentSessionState],
                                       cap: Int) -> [MonitorAgentSessionState] {
        Array(sorted.filter { $0.status != .idle }.prefix(max(cap, 0)))
    }

    /// L shows the top `cap` rows across all statuses (mock `fleet_l`: `slice(0,6)`);
    /// idle/ended stay in the list but collapse to a calm subset when rendered.
    nonisolated static func largeRows(_ sorted: [MonitorAgentSessionState],
                                      cap: Int) -> [MonitorAgentSessionState] {
        Array(sorted.prefix(max(cap, 0)))
    }

    /// The single most-urgent session for the S aggregate (mock `fleet_s`): the
    /// first needsInput, else the longest-running (earliest `startedAt`).
    nonisolated static func mostUrgent(_ sessions: [MonitorAgentSessionState]) -> MonitorAgentSessionState? {
        if let blocked = sessions.first(where: { $0.status == .needsInput }) {
            // Among blocked, the one waiting longest (earliest waitSince) leads.
            return sessions.filter { $0.status == .needsInput }
                .min { ($0.waitSince ?? .greatestFiniteMagnitude) < ($1.waitSince ?? .greatestFiniteMagnitude) }
                ?? blocked
        }
        return sessions.filter { $0.status == .running }
            .min { ($0.startedAt ?? .greatestFiniteMagnitude) < ($1.startedAt ?? .greatestFiniteMagnitude) }
    }

    // MARK: counts + totals

    struct Counts: Equatable {
        var running = 0
        var needsInput = 0
        var idle = 0
        var ended = 0
        var unknown = 0
    }

    nonisolated static func counts(_ sessions: [MonitorAgentSessionState]) -> Counts {
        var c = Counts()
        for s in sessions {
            switch s.status {
            case .running: c.running += 1
            case .needsInput: c.needsInput += 1
            case .idle: c.idle += 1
            case .ended: c.ended += 1
            case .unknown: c.unknown += 1
            }
        }
        return c
    }

    struct Totals: Equatable {
        /// Sum of per-session cost across non-ended sessions (live spend).
        var cost: Double = 0
        /// Longest active run in seconds (running sessions only).
        var longest: Double = 0
        var anyWarn = false
    }

    /// Fleet-wide aggregate (mock `fleetTotals`): live cost + longest active run +
    /// whether any session carries a warning. Ended sessions don't count toward
    /// live spend; only running sessions contribute to `longest`.
    nonisolated static func totals(_ sessions: [MonitorAgentSessionState], now: Double) -> Totals {
        var t = Totals()
        for s in sessions {
            if let cost = s.costUSD, s.status != .ended { t.cost += cost }
            if s.status == .running, let started = s.startedAt {
                let run = now - started
                if run > t.longest { t.longest = run }
            }
            if s.warning != nil { t.anyWarn = true }
        }
        return t
    }

    // MARK: in-status timer source

    struct TimerText: Equatable {
        enum Source: Equatable { case running, waiting, finished }
        var source: Source
        var text: String
    }

    /// In-status timer, sourced per the mock (`fleetStrip`):
    ///   • running    → counts up from `startedAt`  ("12:04")   — elapsed run.
    ///   • needsInput → counts up from `waitSince`   ("waiting 0:34").
    ///   • ended      → "finished <ago> ago" from `lastEventAt`.
    ///   • idle       → no timer (nil).
    /// startedAt (not lastEventAt) is the running source: the mock ticks the
    /// elapsed *session* time, and lastEventAt only feeds the tick track + ended age.
    nonisolated static func timerText(for session: MonitorAgentSessionState, now: Double) -> TimerText? {
        switch session.status {
        case .running:
            guard let started = session.startedAt else { return nil }
            return TimerText(source: .running, text: MonitorFormat.mmss(max(0, now - started)))
        case .needsInput:
            guard let since = session.waitSince else {
                return TimerText(source: .waiting, text: waitingText(0))
            }
            return TimerText(source: .waiting, text: waitingText(max(0, now - since)))
        case .ended:
            return TimerText(source: .finished, text: finishedText(max(0, now - session.lastEventAt)))
        case .idle, .unknown:
            return nil
        }
    }

    private nonisolated static func waitingText(_ seconds: Double) -> String {
        String(localized: "waiting \(MonitorFormat.mmss(seconds))",
               comment: "Fleet row timer: how long a session has been blocked waiting for the user; arg is mm:ss.")
    }

    private nonisolated static func finishedText(_ secondsAgo: Double) -> String {
        String(localized: "finished \(MonitorFormat.ago(secondsAgo)) ago",
               comment: "Fleet row: how long ago an ended session finished; arg is a compact age like 2m.")
    }

    // MARK: context-pressure band

    enum ContextPressure: Equatable { case normal, warn, crit }

    struct ContextBand: Equatable {
        var fraction: Double
        var band: ContextPressure
        var percentText: String
        var fill: Color {
            switch band {
            case .crit: return MonitorDesign.signalCoral
            case .warn: return MonitorDesign.signalAmber
            case .normal: return MonitorDesign.oklch(0.6, 0.05, 248)
            }
        }
    }

    /// Context-pressure band (mock `fleetCtx`): only meaningful for LIVE sessions
    /// (running / needsInput) — an idle/ended session's window isn't "about to
    /// compact", so suppress it there. warn ≥ 0.75, crit ≥ 0.90 (coral near
    /// compaction). Returns nil when `contextUsedPercent` is absent or the session
    /// isn't live.
    nonisolated static func contextBand(for session: MonitorAgentSessionState) -> ContextBand? {
        guard let ctx = session.contextUsedPercent,
              session.status == .running || session.status == .needsInput else { return nil }
        let clamped = min(max(ctx, 0), 1)
        let band: ContextPressure = clamped >= 0.90 ? .crit : (clamped >= 0.75 ? .warn : .normal)
        return ContextBand(fraction: clamped, band: band,
                           percentText: "\(Int((clamped * 100).rounded()))%")
    }

    // MARK: warning chip

    struct WarningInfo: Equatable {
        var text: String
        var isStale: Bool
    }

    /// Warning-chip mapping (mock `fleetWarn`): the raw `warning` token maps to a
    /// display label + a "stale" (amber) vs default (coral) styling. Known tokens:
    /// "toolLoop" → "tool loop", "stale" → "stale". Any other non-empty token is
    /// surfaced verbatim (forward-compatible with new deriver labels).
    nonisolated static func warningLabel(for session: MonitorAgentSessionState) -> WarningInfo? {
        guard let raw = session.warning, !raw.isEmpty else { return nil }
        switch raw {
        case "toolLoop": return WarningInfo(text: "tool loop", isStale: false)
        case "stale": return WarningInfo(text: "stale", isStale: true)
        default: return WarningInfo(text: raw, isStale: false)
        }
    }

    // MARK: budget

    /// Per-session budget readout (mock `fleetBudget`): "$1.08 · 84K tok". Renders
    /// nothing when neither cost nor tokens are known.
    nonisolated static func budgetText(for session: MonitorAgentSessionState) -> String {
        var parts: [String] = []
        if let cost = session.costUSD { parts.append(MonitorFormat.usd(cost)) }
        let tok = session.tokens.input + session.tokens.output
        if tok > 0 { parts.append(MonitorFormat.tokens(tok) + " tok") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Previews

#if DEBUG
private extension MonitorWidgetContext {
    /// Sample fleet mirroring the mock's FLEET data: a needsInput (blocked) +
    /// two running (one burning: toolLoop + 91% ctx, one producing) + idle + ended.
    static func fleetSample(size: MonitorWidgetSize) -> MonitorWidgetContext {
        let now = Date().timeIntervalSince1970
        func events(count: Int, step: Double, from offset: Double = 0) -> [Double] {
            (0..<count).map { now - offset - Double($0) * step }
        }
        func tools(_ pairs: [(String, Bool?)], step: Double, from offset: Double = 0) -> [MonitorAgentToolEvent] {
            pairs.enumerated().map { i, p in
                MonitorAgentToolEvent(name: p.0, at: now - offset - Double(pairs.count - 1 - i) * step, ok: p.1)
            }
        }

        let sessions: [MonitorAgentSessionState] = [
            // ① NEEDS ME — coral, waiting on an approval.
            {
                var s = MonitorAgentSessionState(
                    id: "codex:1", provider: .codex, projectName: "api-server",
                    status: .needsInput, lastEventAt: now - 34, processAlive: true)
                s.statusDetail = "approve DB migration 0042_add_sessions"
                s.model = "gpt-5"; s.gitBranch = "main"
                s.startedAt = now - 410; s.waitSince = now - 34
                s.costUSD = 1.08; s.turnCount = 31; s.contextUsedPercent = 0.47
                s.tokens = MonitorTokenTotals(input: 80000, output: 5000)
                s.recentEventTimes = events(count: 20, step: 3, from: 34)
                s.recentTools = tools([("Read", true), ("Bash", true), ("Write", true), ("Bash", nil)], step: 4, from: 34)
                return s
            }(),
            // ② BURNING — running, tool loop + context near compaction (91%).
            {
                var s = MonitorAgentSessionState(
                    id: "claude:1", provider: .claude, projectName: "LiveWallpaper",
                    status: .running, lastEventAt: now - 2, processAlive: true)
                s.statusDetail = "Bash: swift build"
                s.model = "sonnet"; s.gitBranch = "feat/agent-wallpaper"
                s.startedAt = now - 192; s.costUSD = 2.14; s.turnCount = 14
                s.contextUsedPercent = 0.91; s.warning = "toolLoop"
                s.tokens = MonitorTokenTotals(input: 120000, output: 8000)
                s.recentEventTimes = events(count: 40, step: 2.5)
                s.recentTools = tools([("Bash", false), ("Edit", true), ("Bash", false), ("Edit", true), ("Bash", false)], step: 3)
                return s
            }(),
            // ③ PRODUCING — healthy running session, moderate context.
            {
                var s = MonitorAgentSessionState(
                    id: "claude:2", provider: .claude, projectName: "docs-site",
                    status: .running, lastEventAt: now - 5, processAlive: true)
                s.statusDetail = "Edit: routing.md"
                s.model = "haiku"; s.gitBranch = "fix/links"
                s.startedAt = now - 47; s.costUSD = 0.38; s.turnCount = 6
                s.contextUsedPercent = 0.38
                s.tokens = MonitorTokenTotals(input: 20000, output: 1500)
                s.recentEventTimes = events(count: 12, step: 9)
                s.recentTools = tools([("Grep", true), ("Read", true), ("Edit", true), ("Edit", true)], step: 6)
                return s
            }(),
            // ④ IDLE — collapsed, calm.
            {
                var s = MonitorAgentSessionState(
                    id: "claude:4", provider: .claude, projectName: "infra",
                    status: .idle, lastEventAt: now - 300, processAlive: true)
                s.startedAt = now - 900; s.turnCount = 2
                return s
            }(),
            // ⑤ ENDED — dim, sage.
            {
                var s = MonitorAgentSessionState(
                    id: "claude:3", provider: .claude, projectName: "scratch",
                    status: .ended, lastEventAt: now - 130, processAlive: false)
                s.statusDetail = "summarised logs"
                s.model = "sonnet"; s.startedAt = now - 600
                s.costUSD = 0.51; s.turnCount = 9; s.contextUsedPercent = 0.22
                s.tokens = MonitorTokenTotals(input: 60000, output: 4000)
                s.recentEventTimes = events(count: 8, step: 6, from: 130)
                return s
            }(),
        ]

        var snapshot = MonitorSnapshot()
        snapshot.timestamp = now
        snapshot.agents = sessions

        return MonitorWidgetContext(
            snapshot: snapshot,
            history: MonitorHistorySnapshot(),
            placement: MonitorWidgetPlacement(kind: .fleet, size: size),
            isEditing: false,
            isAgentFleetEnabled: true,
            reduceMotion: false,
            now: Date(timeIntervalSince1970: now)
        )
    }

    /// Module off / no sessions → quiet state.
    static func fleetQuiet(size: MonitorWidgetSize) -> MonitorWidgetContext {
        var snapshot = MonitorSnapshot()
        snapshot.timestamp = Date().timeIntervalSince1970
        snapshot.agents = []
        return MonitorWidgetContext(
            snapshot: snapshot, history: MonitorHistorySnapshot(),
            placement: MonitorWidgetPlacement(kind: .fleet, size: size),
            isEditing: false, isAgentFleetEnabled: true, reduceMotion: false,
            now: Date())
    }
}

// The board supplies `context.now` in production; in isolated previews we wrap the
// widget in a TimelineView so timers stay live without the board.
#Preview("Fleet · M") {
    TimelineView(.periodic(from: .now, by: 1)) { t in
        VStack(spacing: 20) {
            MonitorFleetWidgetView(context: .fleetSample(size: .medium).at(t.date))
                .frame(width: 378, height: 196)
            MonitorFleetWidgetView(context: .fleetQuiet(size: .medium).at(t.date))
                .frame(width: 378, height: 196)
        }
        .padding(32)
        .background(MonitorDesign.boardWash)
    }
}

#Preview("Fleet · L") {
    TimelineView(.periodic(from: .now, by: 1)) { t in
        MonitorFleetWidgetView(context: .fleetSample(size: .large).at(t.date))
            .frame(width: 378, height: 392)
            .padding(32)
            .background(MonitorDesign.boardWash)
    }
}
#endif
