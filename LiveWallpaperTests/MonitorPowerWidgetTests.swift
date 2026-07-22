import Testing
import Foundation
@testable import LiveWallpaper

@Suite("Monitor power widget")
struct MonitorPowerWidgetTests {

    private func system(_ mutate: (inout MonitorSystemSnapshot) -> Void) -> MonitorSystemSnapshot {
        var s = MonitorSystemSnapshot()
        mutate(&s)
        return s
    }

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
        let calculating = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.62; $0.batteryCharging = true; $0.batteryMinutesToFull = nil
        })
        #expect(calculating.timeLine == nil)

        let mismatched = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.62; $0.batteryCharging = true; $0.batteryMinutesRemaining = 90
        })
        #expect(mismatched.timeLine == nil)

        let zero = MonitorPowerModel(system: system {
            $0.batteryLevel = 0.40; $0.batteryCharging = false; $0.batteryMinutesRemaining = 0
        })
        #expect(zero.timeLine == nil)
    }

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
        #expect(MonitorPowerModel.accessoryTint(7).barGradient == [MonitorDesign.signalAmber, MonitorDesign.signalCoral])
        #expect(MonitorPowerModel.accessoryTint(9.9).barGradient == [MonitorDesign.signalAmber, MonitorDesign.signalCoral])
        #expect(MonitorPowerModel.accessoryTint(14).barGradient == [MonitorDesign.oklch(0.62, 0.06, 78), MonitorDesign.signalAmber])
        #expect(MonitorPowerModel.accessoryTint(19.9).barGradient == [MonitorDesign.oklch(0.62, 0.06, 78), MonitorDesign.signalAmber])
        #expect(MonitorPowerModel.accessoryTint(20).barGradient == [MonitorDesign.signalSage])
        #expect(MonitorPowerModel.accessoryTint(96).barGradient == [MonitorDesign.signalSage])
    }

    @Test("Over the cap, the LOWEST-percent accessories are kept, original order preserved")
    func displayAccessoriesKeepsNeediest() {
        let m = MonitorPowerModel(system: system {
            $0.accessories = [
                MonitorAccessoryBattery(name: "Magic Mouse", kind: "mouse", percent: 82),
                MonitorAccessoryBattery(name: "Magic Keyboard", kind: "keyboard", percent: 9),
                MonitorAccessoryBattery(name: "Magic Trackpad", kind: "trackpad", percent: 41),
            ]
        })
        let shown = m.displayAccessories(limit: 2)
        #expect(shown.map(\.name) == ["Magic Keyboard", "Magic Trackpad"])
    }

    @Test("At or under the cap, accessories pass through untouched")
    func displayAccessoriesPassThrough() {
        let two = MonitorPowerModel(system: system {
            $0.accessories = [
                MonitorAccessoryBattery(name: "A", kind: "mouse", percent: 5),
                MonitorAccessoryBattery(name: "B", kind: "keyboard", percent: 99),
            ]
        })
        #expect(two.displayAccessories(limit: 2).map(\.name) == ["A", "B"])
        let none = MonitorPowerModel(system: system { $0.accessories = nil })
        #expect(none.displayAccessories(limit: 2).isEmpty)
    }
}
