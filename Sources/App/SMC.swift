import Foundation
import IOKit

/// Reads Apple SMC (System Management Controller) sensors.
/// Struct layout must exactly match the kernel's SMCParamStruct (80 bytes on arm64).
final class SMC: @unchecked Sendable {

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

    /// Read a 4-char SMC key as a big-endian IEEE 754 float (type `flt `).
    func float(_ key: String) -> Float? {
        guard let b = read(key) else { return nil }
        let bits = UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3)
        let f = Float(bitPattern: bits)
        guard f.isFinite else { return nil }
        return f
    }

    /// Read a signed 7.8 fixed-point temperature (type `sp78`), returns °C.
    func temp(_ key: String) -> Float? {
        guard let b = read(key) else { return nil }
        let raw = Int16(Int16(b.0) << 8 | Int16(b.1))
        let c = Float(raw) / 256.0
        guard c > 5 && c < 130 else { return nil }
        return c
    }

    /// Read first 4 bytes of any SMC key.
    private func read(_ key: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var inp = Param(), out = Param()
        inp.key = fourCC(key)

        inp.data8 = 9 // kSMCGetKeyInfo
        guard call(&inp, &out) else { return nil }

        inp.keyInfo = out.keyInfo
        inp.data8 = 5 // kSMCReadKey
        out = Param()
        guard call(&inp, &out) else { return nil }

        return (out.bytes.0, out.bytes.1, out.bytes.2, out.bytes.3)
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
