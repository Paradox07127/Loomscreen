import Combine
import Foundation
@testable import LiveWallpaper

@MainActor
final class FakePowerMonitor: PowerMonitoring {
    private let subject: CurrentValueSubject<PowerMonitor.PowerSource, Never>

    private(set) var powerSourcePublisherReadCount = 0
    private(set) var currentPowerSourceReadCount = 0
    private(set) var refreshPowerStatusCallCount = 0

    init(initialPowerSource: PowerMonitor.PowerSource = .external) {
        subject = CurrentValueSubject(initialPowerSource)
    }

    var powerSourcePublisher: AnyPublisher<PowerMonitor.PowerSource, Never> {
        powerSourcePublisherReadCount += 1
        return subject.eraseToAnyPublisher()
    }

    var currentPowerSource: PowerMonitor.PowerSource {
        currentPowerSourceReadCount += 1
        return subject.value
    }

    func send(_ powerSource: PowerMonitor.PowerSource) {
        subject.send(powerSource)
    }

    func refreshPowerStatus() {
        refreshPowerStatusCallCount += 1
    }
}
