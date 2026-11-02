import Foundation
import MachO
import Testing
@testable import MissionCopilot

/// The app's database must be SQLCipher, linked into the app itself (ADR 0008 layer B, #68). If the
/// app also linked Apple's plain libsqlite3, its calls could reach the unencrypted one. Apple's own
/// frameworks load that library into every process for their own use; what matters is the app's links.
/// The tests do not link GRDB themselves: that would put a second copy in the test bundle.
struct SQLCipherLinkTests {
    @Test func theDatabaseIsSQLCipher() throws {
        #expect(try SQLCipherInfo.version()?.hasPrefix("4.20.0") == true)
    }

    @Test func theAppDoesNotLinkApplesPlainSQLite() {
        // Every image from inside the app bundle: in Debug builds the code lives in a .debug.dylib.
        let ours = (0..<_dyld_image_count()).filter { index in
            _dyld_get_image_name(index).map { String(cString: $0).hasPrefix(Bundle.main.bundlePath) } ?? false
        }
        let linked = ours.flatMap { Self.linkedLibraries(of: $0) }

        #expect(!ours.isEmpty && !linked.isEmpty)
        #expect(!linked.contains { $0.contains("libsqlite3") })
    }

    /// The libraries one loaded image asks the system to load (its LC_LOAD_DYLIB commands).
    static func linkedLibraries(of index: UInt32) -> [String] {
        guard let header = _dyld_get_image_header(index) else { return [] }
        var names: [String] = []
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_LOAD_DYLIB || load.cmd == UInt32(LC_LOAD_WEAK_DYLIB) {
                let dylib = command.load(as: dylib_command.self)
                names.append(String(cString: command.advanced(by: Int(dylib.dylib.name.offset))
                    .assumingMemoryBound(to: CChar.self)))
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return names
    }
}
