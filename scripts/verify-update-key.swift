import Foundation
import CryptoKit
let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard let data = Data(base64Encoded: raw), data.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data),
      let expected = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
      key.publicKey.rawRepresentation.base64EncodedString() == expected else {
    fputs("Update signing key does not match the app's public key.\n", stderr); exit(1)
}
print("Update signing key matches the embedded public key.")
