import Foundation
import IOKit

/// Energy counters of the AppleCLPC driver (the performance controller), for macOS 27.
///
/// On macOS 27 the `Energy Model` channels the power manager publishes stop advancing for
/// processes without an Apple entitlement: they sit still for minutes, then catch up in one
/// jump. AppleCLPC keeps the same totals in counters that stay live, but it doesn't list
/// them in its IOReport legend, so they can't be discovered — a subscription has to name
/// each one by its report ID, and those IDs differ per chip.
///
/// The ID table is ported from macmon (https://github.com/vladkens/macmon, `src/clpc.rs`),
/// Copyright (c) 2024 vladkens, MIT License. It was generated there from macOS 27.2.
enum CLPCEnergy {
    struct Channel: Equatable {
        let id: UInt64
        let name: String
    }

    /// Channel names, chosen to match the `Energy Model` ones they stand in for.
    static let cpu = "CPU Energy", gpu = "GPU Energy", ane = "ANE", dram = "DRAM", dcs = "DCS"

    static let group = "CLPC"

    /// The counters for a CLPC driver bundle, or nil when the OS or chip isn't in the table.
    static func channels(bundle: String, osMajor: Int) -> [Channel]? {
        guard osMajor == 27, let keys = keys[bundle] else { return nil }
        // The high half is the counter's index in the driver's report table (the same on
        // every chip), the low half a per-chip key.
        return zip([(16, cpu), (25, gpu), (24, ane), (26, dram), (27, dcs)], keys).map { slot, key in
            Channel(id: UInt64(slot.0) << 32 | UInt64(key), name: slot.1)
        }
    }

    /// Subscription entries for this machine's CLPC counters; empty when they aren't known.
    static func subscriptionChannels() -> [NSMutableDictionary] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }

        var driverID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &driverID) == KERN_SUCCESS,
              let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, nil, 0)?
                  .takeRetainedValue() as? String,
              let channels = channels(bundle: bundle, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        else { return [] }

        // IOReportTypes.h: a simple integer in the power category with one element, counting nJ.
        let format: Int64 = 1 | 2 << 16 | 1 << 32
        let nanojoules: Int64 = 3 << 56 | 118 << 32
        return channels.map { channel in
            // Mutable: IOReport's getters cache derived fields in the channel dictionary.
            NSMutableDictionary(dictionary: [
                "DriverID": NSNumber(value: Int64(bitPattern: driverID)),
                "DriverName": "AppleCLPC",
                "IOReportGroupName": group,
                "IOReportSubGroupName": "Energy Counters",
                "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: nanojoules)],
                "LegendChannel": [NSNumber(value: Int64(bitPattern: channel.id)), NSNumber(value: format), channel.name],
            ])
        }
    }

    /// Per-chip keys in the order CPU, GPU, ANE, DRAM, DCS.
    private static let keys: [String: [UInt32]] = [
        "com.apple.driver.AppleT6000CLPCv3": [0x4747_9059, 0x4519_bf1e, 0x9aaa_17f8, 0xd6ca_0cfb, 0x05ca_c729],
        "com.apple.driver.AppleT6002CLPC":   [0xb501_816b, 0x9e2c_3e8b, 0x14d5_a574, 0x7670_4b08, 0x2d7b_7fb2],
        "com.apple.driver.AppleT6020CLPC":   [0xe301_cd75, 0x8f34_cc7a, 0x7415_fb0f, 0x2624_4bb6, 0x5f31_a20f],
        "com.apple.driver.AppleT6022CLPC":   [0x76f5_fd21, 0x9062_4499, 0x3c09_7307, 0xe8f2_ddf9, 0xfa86_5a91],
        "com.apple.driver.AppleT6030CLPC":   [0xbe03_a01a, 0x472d_6c9c, 0xb899_0c38, 0x2380_9c0f, 0xb594_4c6a],
        "com.apple.driver.AppleT6031CLPC":   [0xd81e_0084, 0x1085_f98b, 0x313a_3be1, 0x65ff_699d, 0x10cb_1f6a],
        "com.apple.driver.AppleT6032CLPC":   [0xf4a2_1308, 0x85e8_0513, 0x63dc_8e25, 0x63dc_aae5, 0x8cc1_3c13],
        "com.apple.driver.AppleT6041CLPC":   [0x263c_f1f0, 0x22e4_cf59, 0x7849_fb5c, 0xfe93_2624, 0x8fc8_575c],
        "com.apple.driver.AppleT6050CLPC":   [0xd3ab_60bb, 0x27cd_4ce5, 0x8c0f_1c59, 0xf3c8_1737, 0x3d89_affa],
        "com.apple.driver.AppleT6050dCLPC":  [0x18b3_010e, 0xedec_a11a, 0x188b_d883, 0xa331_96f9, 0x0b3c_717e],
        "com.apple.driver.AppleT8103CLPCv3": [0x2cdd_31f2, 0x21be_cf42, 0x0667_fb81, 0xc0c2_0839, 0x31d3_e1e7],
        "com.apple.driver.AppleT8112CLPC":   [0xb543_5137, 0x638d_9d52, 0xea08_9c36, 0x8b6e_0faa, 0x9a6e_145a],
        "com.apple.driver.AppleT8122CLPC":   [0x54b5_1c99, 0xce2d_d9dc, 0x960a_fe2f, 0x0b96_41d3, 0x0d80_2b66],
        "com.apple.driver.AppleT8132CLPC":   [0x4a85_4d94, 0x3b3e_3b79, 0x1ff4_a9ec, 0x9a44_d225, 0xe340_48d2],
        "com.apple.driver.AppleT8140CLPC":   [0x9bf5_4436, 0xef70_589c, 0x569d_941b, 0x035f_5005, 0x5344_2391],
        "com.apple.driver.AppleT8142CLPC":   [0x4370_8744, 0x6a01_0933, 0xbc5e_fdf0, 0xe136_33aa, 0x2b8d_7fec],
        "com.apple.driver.AppleT8152CLPC":   [0x485d_4bfc, 0x1178_4654, 0x9380_c6bb, 0xe17c_13bf, 0x4e80_dc41],
    ]
}
