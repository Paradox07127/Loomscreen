import Testing
import Foundation
@testable import LiveWallpaper

/// Pure-logic coverage for the Power widget's view-model — the parts that decide
/// wording, hiding rules, thresholds and icon mapping (the visual layout is
/// exercised by the SwiftUI previews, not here).
@Suite("Monitor power widget")
struct MonitorPowerWidgetTests {

    private func system(_ mutate: (inout MonitorSystemSnapshot) -> Void) -> MonitorSystemSnapshot {
        var s = MonitorSystemSnapshot()
        mutate(&s)
        return s
    }

    // MARK: - hasBattery / hero honesty

    @Test("No battery level → plug/AC hero, never a fabricated percent")
    func desktopHasNoFakePercent() {
        let m = MonitorPowerModel(system: system { $0.batteryLevel = nil; $0.powerSource = nil })
        #expect(m.hasBattery == false)
        #expect(m.heroPercent == nil)
        #expect(m.status == "Power Adapter")
    }

    @Test("Battery level rounds to a whole-number hero percent")
    func heroPercentRounds() {
        let m = MonitorPowerModel(system: system { $0.batteryLevel = 0.626; $0.powerSource = "ac" })
        #expect(m.hasBattery)
        #expect(m.heroPercent == 63)
    }

    // MARK: - Status wording (mock powStatus order)

    @Test("Status precedence: charged > charging > adapter > battery")
    func statusWording() {
        let charged = MonitorPowerModel(system: system {
            $0.batteryLevel = 1.0; $0.batteryIsCharged = true; $0.batteryCharging = true; $0.powerSource = "ac"
        })
        #expect(charged.status == "Charged")

        let charging = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.62; $0.batteryCharging = true; $0.powerSource = "ac"
        })
        #expect(charging.status == "Charging")

        let onAdapter = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.80; $0.batteryCharging = false; $0.powerSource = "ac"
        })
        #expect(onAdapter.status == "Power Adapter")

        let onBattery = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.55; $0.batteryCharging = false; $0.powerSource = "battery"
        })
        #expect(onBattery.status == "Battery")
    }

    // MARK: - Time line hiding rules

    @Test("Charging shows 'to full'; discharging shows 'remaining'")
    func timeLineWording() {
        let charging = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.62; $0.batteryCharging = true; $0.batteryMinutesToFull = 48; $0.powerSource = "ac"
        })
        #expect(charging.timeLine?.value == "48m")
        #expect(charging.timeLine?.suffix == "to full")

        let discharging = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.40; $0.batteryCharging = false; $0.batteryMinutesRemaining = 130; $0.powerSource = "battery"
        })
        #expect(discharging.timeLine?.value == "2h 10m")
        #expect(discharging.timeLine?.suffix == "remaining")
    }

    @Test("Unknown / non-positive time hides the whole line")
    func timeLineHidden() {
        // nil (calculating) → hidden
        let calculating = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.62; $0.batteryCharging = true; $0.batteryMinutesToFull = nil
        })
        #expect(calculating.timeLine == nil)

        // charging but only a remaining figure present → still hidden (wrong axis)
        let mismatched = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.62; $0.batteryCharging = true; $0.batteryMinutesRemaining = 90
        })
        #expect(mismatched.timeLine == nil)

        // zero minutes → hidden
        let zero = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.40; $0.batteryCharging = false; $0.batteryMinutesRemaining = 0
        })
        #expect(zero.timeLine == nil)
    }

    // MARK: - Chips (LPM always; thermal only serious/critical)

    @Test("Thermal chip only appears at serious/critical, LPM whenever on")
    func chipThresholds() {
        let fair = MonitorPowerModel(system: system { $0.thermalState = "fair"; $0.lowPowerMode = false })
        #expect(fair.chips.isEmpty)

        let serious = MonitorPowerModel(system: system { $0.thermalState = "serious" })
        #expect(serious.chips == [.thermal("serious")])

        let critical = MonitorPowerModel(system: system { $0.thermalState = "critical" })
        #expect(critical.chips == [.thermal("critical")])

        let both = MonitorPowerModel(system: system { $0.lowPowerMode = true; $0.thermalState = "critical" })
        #expect(both.chips == [.lowPower, .thermal("critical")])
    }

    // MARK: - Accessory icon mapping + tint thresholds

    @Test("Accessory kind maps to the right SF Symbol")
    func accessorySymbolMapping() {
        #expect(MonitorPowerModel.accessorySymbol("mouse") == "magicmouse")
        #expect(MonitorPowerModel.accessorySymbol("keyboard") == "keyboard")
        #expect(MonitorPowerModel.accessorySymbol("trackpad") == "trackpad")
        #expect(MonitorPowerModel.accessorySymbol("other") == "dot.radiowaves.left.and.right")
        #expect(MonitorPowerModel.accessorySymbol(nil) == "dot.radiowaves.left.and.right")
    }

    @Test("Accessory tint: crit <10 (run→need ramp), low <20 (→run ramp), sage otherwise")
    func accessoryTintThresholds() {
        // Mirrors mock `.accrow.crit/.low .abar i` gradients exactly (not just a
        // single colour) — pin both stops plus the threshold boundaries.
        #expect(MonitorPowerModel.accessoryTint(7).barGradient == [MonitorDesign.signalAmber, MonitorDesign.signalCoral])
        #expect(MonitorPowerModel.accessoryTint(9.9).barGradient == [MonitorDesign.signalAmber, MonitorDesign.signalCoral])
        #expect(MonitorPowerModel.accessoryTint(14).barGradient == [MonitorDesign.oklch(0.62, 0.06, 78), MonitorDesign.signalAmber])
        #expect(MonitorPowerModel.accessoryTint(19.9).barGradient == [MonitorDesign.oklch(0.62, 0.06, 78), MonitorDesign.signalAmber])
        #expect(MonitorPowerModel.accessoryTint(20).barGradient == [MonitorDesign.signalSage])
        #expect(MonitorPowerModel.accessoryTint(96).barGradient == [MonitorDesign.signalSage])
    }
}
