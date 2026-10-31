import SwiftUI

/// Empty app that hosts the Keychain tests: iOS gives a Keychain only to code running inside an app.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup { Text("EncryptionLab test host") }
    }
}
