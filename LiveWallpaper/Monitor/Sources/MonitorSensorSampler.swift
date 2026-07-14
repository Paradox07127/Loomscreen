import Foundation
import IOKit
import os

/// In-process Apple SMC reader for CPU / GPU / SoC temperature and CPU package
/// power — the "B-tier" sensor readings the CPU/GPU widgets show when present.
///
/// Everything here is read-only IOKit against the `AppleSMC` service. Under the
/// App Sandbox opening that service MAY be denied (`IOServiceOpen` returns a
/// non-zero result); when it is, `available` stays false and every `sample()`
/// returns `nil`, so the widgets simply hide their sensor rows — identical to the
/// pre-sensor behaviour, no fabricated zeros. Whether the open succeeds is the
/// on-device signal for whether a privileged helper is required instead.
///
/// The SMC key-data struct layout + selector match the long-standing community
/// readers (beltex/SMCKit, the `stats` menu bar app); temperature/power keys are
/// read as `flt ` (Float32 °C / W) with an `sp78` fallback for Intel.
final class MonitorSensorSampler {
    private static let log = Logger(subsystem: "LiveWallpaper.Monitor", category: "sensors")

    private var connection: io_connect_t = 0
    private var didAttemptOpen = false
    private(set) var available = false

    // Averaged over whichever keys read successfully — Apple Silicon exposes many
    // per-cluster sensors whose exact codes vary by chip, so we probe a broad set
    // and average the finite hits rather than hard-coding one key.
    private static let cpuTempKeys = [
        // Intel
        "TC0P", "TC0D", "TC0E", "TC0F", "TCXC", "TCXR",
        // Apple Silicon P/E-core clusters (M1…M4 spellings)
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X",
        "Tp0b", "Tp0f", "Tp0j", "Tp0n", "Tp0r", "Tp0v",
        "Te05", "Te0L", "Te0P", "Te0S",
    ]
    private static let gpuTempKeys = [
        "TG0P", "TG0D",                       // Intel
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",  // Apple Silicon
    ]
    private static let socTempKeys = ["Ts0S", "Ts1S", "Tm0P", "Ts0P"]
    private static let cpuPowerKeys = ["PCPC", "PC0C", "PCPT", "PSTR", "PCPG"]

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Read the sensors, or `nil` if the SMC is unreachable / every key missed.
    func sample() -> MonitorSensorReadings? {
        openIfNeeded()
        guard available else { return nil }

        let cpu = averageTemperature(Self.cpuTempKeys)
        let gpu = averageTemperature(Self.gpuTempKeys)
        let soc = averageTemperature(Self.socTempKeys) ?? cpu
        let power = firstPower(Self.cpuPowerKeys)

        if cpu == nil, gpu == nil, soc == nil, power == nil { return nil }
        return MonitorSensorReadings(cpuTempC: cpu, gpuTempC: gpu, socTempC: soc, cpuPowerW: power)
    }

    // MARK: - Connection

    private func openIfNeeded() {
        guard !didAttemptOpen else { return }
        didAttemptOpen = true

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            Self.log.notice("🌡️ AppleSMC service not found")
            return
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result == kIOReturnSuccess {
            available = true
        } else {
            connection = 0
            // 0xe00002e2 = kIOReturnNotPermitted: the sandbox blocked the open. The
            // `iokit-user-client-class` entitlement (AppleSMCClient) is the relaxed
            // path that keeps the in-process read working without a helper. Kept as a
            // one-shot error diagnostic for hardware/OS where the open still fails.
            let code = String(UInt32(bitPattern: result), radix: 16)
            Self.log.notice("🌡️ AppleSMC open denied (0x\(code)) — sensor rows will stay hidden")
        }
    }

    // MARK: - Key reads

    private func averageTemperature(_ keys: [String]) -> Double? {
        var sum = 0.0
        var count = 0
        for key in keys {
            // Plausible temperature band, so a spurious 0 / garbage key is ignored.
            if let value = readValue(key), value > 1, value < 130 {
                sum += value
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    private func firstPower(_ keys: [String]) -> Double? {
        for key in keys {
            if let value = readValue(key), value.isFinite, value > 0, value < 1000 {
                return value
            }
        }
        return nil
    }

    /// Read a key and decode its numeric value (temperature °C or power W). Two
    /// calls: `kSMCGetKeyInfo` (9) for the type/size, then `kSMCReadKey` (5).
    private func readValue(_ key: String) -> Double? {
        var input = SMCKeyData()
        input.key = Self.fourCharCode(key)
        input.data8 = 9  // kSMCGetKeyInfo
        guard let info = call(input), info.result == 0, info.keyInfo.dataSize > 0 else { return nil }

        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.keyInfo.dataType = info.keyInfo.dataType
        input.data8 = 5  // kSMCReadKey
        guard let output = call(input), output.result == 0 else { return nil }

        let size = Int(info.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return Self.decode(type: info.keyInfo.dataType, bytes: bytes)
    }

    private func call(_ input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, inputSize, &output, &outputSize)
        return result == kIOReturnSuccess ? output : nil
    }

    // MARK: - Decoding

    /// FourCC key ("TC0P") → packed UInt32.
    private static func fourCharCode(_ string: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in string.utf8.prefix(4) { code = (code << 8) | UInt32(byte) }
        return code
    }

    /// Decode by SMC data type: `flt ` = little-endian Float32, `sp78` = signed
    /// 7.8 fixed-point (Intel temps), `ui16`/`ui8 ` = big-endian unsigned.
    private static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        switch type {
        case fourCharCode("flt "):
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: raw))
        case fourCharCode("sp78"):
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case fourCharCode("ui16"):
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case fourCharCode("ui8 "):
            guard let first = bytes.first else { return nil }
            return Double(first)
        default:
            return nil
        }
    }
}

// MARK: - SMC parameter struct (kernel ABI)

/// Mirrors `SMCKeyData_t` — the fixed struct `AppleSMC`'s user client expects for
/// `IOConnectCallStructMethod(selector 2)`. Field order/size must match the kernel
/// exactly; this is the layout the community SMC readers have used for years.
private struct SMCKeyData {
    struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Vers()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    // 32-byte payload.
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
