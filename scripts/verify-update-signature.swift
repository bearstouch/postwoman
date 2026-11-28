// Checks that an update archive's EdDSA signature matches the public key the app ships with (`sparklePublicKey` in
// release/manifest.json), so a release signed with another key fails here instead of publishing an update that every
// installed copy would reject.
//   swift scripts/verify-update-signature.swift <archive> <base64 signature> <base64 public key>
import CryptoKit
import Foundation

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

let values = Array(CommandLine.arguments.dropFirst())
guard values.count == 3 else { fail("usage: verify-update-signature.swift <archive> <signature> <public key>", status: 2) }
guard let archive = FileManager.default.contents(atPath: values[0]) else { fail("Can't read \(values[0]).") }
guard let signature = Data(base64Encoded: values[1]), let keyData = Data(base64Encoded: values[2]),
    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("The signature or the public key isn't base64 Ed25519.") }
guard key.isValidSignature(signature, for: archive) else {
    fail("The signature doesn't match sparklePublicKey: SPARKLE_ED_PRIVATE_KEY is another key, so installed apps would reject this update.")
}
print("The update signature matches sparklePublicKey.")
