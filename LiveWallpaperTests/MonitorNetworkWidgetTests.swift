import Testing
import Foundation
@testable import LiveWallpaper

struct MonitorNetworkWidgetTests {

    private func iface(
        _ name: String, rx: Double = 0, tx: Double = 0,
        active: Bool? = nil, addresses: [String]? = nil,
        rxErrors: UInt64? = nil, txErrors: UInt64? = nil, rxDrops: UInt64? = nil
    ) -> MonitorNetworkInterface {
        MonitorNetworkInterface(
            name: name, rxBytesPerSec: rx, txBytesPerSec: tx,
            rxErrors: rxErrors, txErrors: txErrors, rxDrops: rxDrops,
            addresses: addresses, isActive: active
        )
    }

    @Test("nil / empty interface list yields no active interface")
    func activeNilForEmpty() {
        #expect(MonitorNetworkWidgetView.pickActiveInterface(nil) == nil)
        #expect(MonitorNetworkWidgetView.pickActiveInterface([]) == nil)
    }

    @Test("the NWPath-chosen isActive interface wins over higher traffic")
    func activePrefersFlag() {
        let picked = MonitorNetworkWidgetView.pickActiveInterface([
            iface("en0", rx: 10, tx: 5, active: true),
            iface("en1", rx: 999, tx: 999, active: false)
        ])
        #expect(picked?.name == "en0")
    }

    @Test("with no active flag, the highest rx+tx traffic interface is chosen")
    func activeFallsBackToTraffic() {
        let picked = MonitorNetworkWidgetView.pickActiveInterface([
            iface("lo0", rx: 1, tx: 1),
            iface("en0", rx: 40, tx: 20),
            iface("en1", rx: 5, tx: 5)
        ])
        #expect(picked?.name == "en0")
    }

    @Test("IPv4 is dotted with no colon; IPv6 (with colons) is rejected")
    func ipv4Discriminator() {
        #expect(MonitorNetworkWidgetView.isIPv4("192.168.1.24"))
        #expect(MonitorNetworkWidgetView.isIPv4("fe80::14b2:9c3f:8e1a:22d7") == false)
        #expect(MonitorNetworkWidgetView.isIPv4("::1") == false)
    }

    @Test("rate splits into numeral and unit at the first space")
    func rateSplit() {
        let mb = MonitorNetworkWidgetView.splitRate("6.2 MB/s")
        #expect(mb.value == "6.2")
        #expect(mb.unit == "MB/s")
        #expect(MonitorNetworkWidgetView.splitRate("0 B/s").unit == "B/s")
        #expect(MonitorNetworkWidgetView.splitRate("—").value == "—")
        #expect(MonitorNetworkWidgetView.splitRate("—").unit.isEmpty)
    }

    @Test("tail returns the last N samples, or the whole series when shorter")
    func tailWindow() {
        let series = (0..<30).map(Double.init)
        let last20 = MonitorNetworkWidgetView.tail(series, count: 20)
        #expect(last20.count == 20)
        #expect(last20.first == 10)
        #expect(last20.last == 29)

        let short = [1.0, 2.0, 3.0]
        #expect(MonitorNetworkWidgetView.tail(short, count: 20) == short)
    }

    @Test("tail also windows the L card's 120-sample un-shrunk chart")
    func tailWindowLarge() {
        let series = (0..<200).map(Double.init)
        let last120 = MonitorNetworkWidgetView.tail(series, count: 120)
        #expect(last120.count == 120)
        #expect(last120.first == 80)
        #expect(last120.last == 199)

        let atCapacity = (0..<120).map(Double.init)
        #expect(MonitorNetworkWidgetView.tail(atCapacity, count: 120) == atCapacity)
    }
}
