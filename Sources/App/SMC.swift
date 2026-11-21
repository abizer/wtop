import Foundation
import IOKit

/// Reads Apple SMC (System Management Controller) sensors.
/// Struct layout must exactly match the kernel's SMCParamStruct (80 bytes on arm64).
final class SMC {

    // MARK: - Kernel struct (80 bytes — verified via brute-force probing)

    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0    // Must be UInt32, NOT IOByteCount (which is 8 bytes on arm64)
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct Param {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0     // Required — aligns result/status/data8 to match kernel layout
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                               0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    typealias SMCBytes = (
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
        UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8
    )

    private var conn: io_connect_t = 0
    private var keyInfoCache: [UInt32: KeyInfo] = [:]  // key metadata never changes; skip kSMCGetKeyInfo after first read

    init?() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            return nil
        }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    /// Decode a raw temperature reading in °C, or nil if the type isn't a temperature
    /// encoding we know or the value is physically implausible.
    ///
    /// The key's declared type decides the encoding — guessing produces numbers that look
    /// like temperatures but aren't. Apple Silicon reports `flt ` (little-endian IEEE 754);
    /// Intel-era keys were `sp78` (big-endian signed 8.8 fixed point).
    static func celsius(bytes b: (UInt8, UInt8, UInt8, UInt8), type: String) -> Float? {
        let value: Float
        switch type {
        case "flt ":
            value = Float(bitPattern: UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24)
        case "sp78":
            value = Float(Int16(bitPattern: UInt16(b.0) << 8 | UInt16(b.1))) / 256
        default:
            return nil
        }
        return value.isFinite && value > 0 && value < 150 ? value : nil
    }

    /// Read a temperature sensor in °C.
    func temp(_ key: String) -> Float? {
        guard let (bytes, type) = read(key) else { return nil }
        return Self.celsius(bytes: bytes, type: type)
    }

    /// Read a power rail in watts. Rails are `flt ` like the temperatures.
    func watts(_ key: String) -> Float? {
        guard let (b, type) = read(key), type == "flt " else { return nil }
        let value = Float(bitPattern: UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24)
        return value.isFinite && value >= 0 && value < 1000 ? value : nil
    }

    /// Read the first 4 bytes of an SMC key, along with its four-character type code.
    private func read(_ key: String) -> (bytes: (UInt8, UInt8, UInt8, UInt8), type: String)? {
        var inp = Param(), out = Param()
        inp.key = fourCC(key)

        if let cached = keyInfoCache[inp.key] {
            inp.keyInfo = cached
        } else {
            inp.data8 = 9 // kSMCGetKeyInfo
            guard call(&inp, &out) else { return nil }
            keyInfoCache[inp.key] = out.keyInfo
            inp.keyInfo = out.keyInfo
        }

        inp.data8 = 5 // kSMCReadKey
        out = Param()
        guard call(&inp, &out) else { return nil }

        let code = inp.keyInfo.dataType
        let type = String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
        return ((out.bytes.0, out.bytes.1, out.bytes.2, out.bytes.3), type)
    }

    private func call(_ input: inout Param, _ output: inout Param) -> Bool {
        let sz = MemoryLayout<Param>.stride
        var outSz = sz
        let r = IOConnectCallStructMethod(conn, 2, &input, sz, &output, &outSz)
        return r == kIOReturnSuccess && output.result == 0
    }

    private func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
