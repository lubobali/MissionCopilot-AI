import Foundation
import Security

/// One lock setting for every Secure Enclave key (mission vault and evidence signer), so they cannot drift.
/// Apple's default is "after first unlock"; we require "when unlocked, this device only".
/// iOS cannot report this back from a chip key, so a test pins the value and the phone lock test proves it.
enum ChipKeyAccess {
    static var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

    struct Failed: Error {}

    static func make() throws -> SecAccessControl {
        guard let access = SecAccessControlCreateWithFlags(nil, accessibility, .privateKeyUsage, nil) else {
            throw Failed()
        }
        return access
    }
}
