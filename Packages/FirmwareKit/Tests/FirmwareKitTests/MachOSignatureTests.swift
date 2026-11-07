import Foundation
import Testing

@testable import FirmwareKit

/// The guest-helper Mach-O checks on built images: thin and fat, signed and not, a modern load command, and files
/// cut short (which MachOKit 0.53, the checks' reader before, trapped on).
struct MachOSignatureTests {
    private static func le(_ values: [UInt32]) -> Data {
        Data(values.flatMap { v in (0..<4).map { UInt8(v >> ($0 * 8) & 0xFF) } })
    }
    private static func be(_ values: [UInt32]) -> Data {
        Data(values.flatMap { v in (0..<4).reversed().map { UInt8(v >> ($0 * 8) & 0xFF) } })
    }

    /// A thin 32-bit ARM image: its header, then each (cmd, payload words) as a load command.
    private static func image(subtype: UInt32, _ commands: [(UInt32, [UInt32])]) -> Data {
        let body = commands.reduce(Data()) { $0 + le([$1.0, UInt32(8 + 4 * $1.1.count)] + $1.1) }
        return le([0xFEED_FACE, 12, subtype, 2, UInt32(commands.count), UInt32(body.count), 0]) + body
    }

    private static func fat(_ slices: [(UInt32, Data)]) -> Data {
        var offset = 8 + 20 * slices.count
        var header = be([0xCAFE_BABE, UInt32(slices.count)])
        for (subtype, slice) in slices {
            header += be([12, subtype, UInt32(offset), UInt32(slice.count), 0])
            offset += slice.count
        }
        return slices.reduce(header) { $0 + $1.1 }
    }

    private static func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macho-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test func thinFatSignedAndNot() throws {
        let signed7 = Self.image(subtype: 9, [(0x1D, [0x1000, 0x220])])
        let unsigned7 = Self.image(subtype: 9, [(0x2, [0, 0, 0, 0])])
        let modern7 = Self.image(subtype: 9, [(0x8000_0028, [0, 0, 0, 0]), (0x1D, [0x1000, 0x220])])
        let signed6 = Self.image(subtype: 6, [(0x1D, [0x800, 0x100])])
        let dyldInfo6 = Self.image(subtype: 6, [(0x8000_0022, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), (0x1D, [0, 0])])

        #expect(MachOSignature.codeSignature(in: signed7).map { [$0.offset, $0.size] } == [0x1000, 0x220])
        #expect(MachOSignature.codeSignature(in: unsigned7) == nil)
        #expect(MachOSignature.guestToolProblem(try Self.write(signed7)) == nil)
        #expect(MachOSignature.guestToolProblem(try Self.write(unsigned7)) == "unsigned (ldid -S)")
        #expect(MachOSignature.guestToolProblem(try Self.write(modern7))?.contains("LC_MAIN") == true)
        #expect(MachOSignature.guestToolProblem(try Self.write(signed6)) == "cpu 12/6, not armv7")

        #expect(MachOSignature.appSyncProblem(try Self.write(Self.fat([(6, signed6), (9, signed7)]))) == nil)
        #expect(
            MachOSignature.appSyncProblem(try Self.write(Self.fat([(6, signed6), (9, unsigned7)])))?.hasPrefix(
                "slice 1"
            ) == true
        )
        #expect(MachOSignature.appSyncProblem(try Self.write(Self.fat([(6, signed6)]))) == "no armv7 slice")
        #expect(MachOSignature.appSyncProblem(try Self.write(signed7)) == "not a fat Mach-O (expected armv6+armv7)")

        #expect(MachOSignature.earlyARMProblem(try Self.write(Self.fat([(6, signed6), (9, signed7)]))) == nil)
        #expect(MachOSignature.earlyARMProblem(try Self.write(dyldInfo6))?.contains("newer dyld") == true)
        #expect(MachOSignature.earlyARMProblem(try Self.write(signed7)) == "no armv6 slice")

        let whole = Self.fat([(6, signed6), (9, signed7)])
        for cut in [3, 20, 40, whole.count - 1] {
            #expect(MachOSignature.earlyARMProblem(try Self.write(whole.prefix(cut))) == "not a Mach-O")
        }
        #expect(MachOSignature.codeSignature(in: signed7.prefix(40)) == nil)
    }
}
