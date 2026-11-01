/// The public key that verifies the on-device model's OpenSSF Model Signing bundle (threat model T46).
/// Pinned in the app, so a model signed by anyone else is refused. A test checks it is the same key as
/// docs/models/model-signing.pub.pem; the private key never leaves the project owner's Mac.
enum ModelSigningKey {
    static let pem = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEag3kZ0LsbcQph6AIA4mBQLjRa+Xm
    PLmK93U7HVlfKIs8mhyc6s8/0MBgWV6qLmXcGnRcCrHsPBHwsauLcEszNQ==
    -----END PUBLIC KEY-----
    """
}
