import Foundation
import Crypto
import NIOSSH

enum SSHAuthMethod {
    case password(String)
    case privateKey(String) // PEM content (OpenSSH format)
}

// MARK: - OpenSSH Ed25519 Private Key Parser

enum OpenSSHKeyParseError: LocalizedError {
    case invalidPEMFormat
    case invalidMagic
    case unsupportedCipher(String)
    case invalidKeyData
    case keyExtractionFailed

    var errorDescription: String? {
        switch self {
        case .invalidPEMFormat: return "Invalid PEM format"
        case .invalidMagic: return "Not a valid OpenSSH private key"
        case .unsupportedCipher(let cipher): return "Unsupported cipher: \(cipher) (only unencrypted keys supported)"
        case .invalidKeyData: return "Invalid key data"
        case .keyExtractionFailed: return "Failed to extract key bytes"
        }
    }
}

/// Parses an OpenSSH Ed25519 private key from PEM format and returns a NIOSSHPrivateKey.
func parseOpenSSHEd25519PrivateKey(pem: String) throws -> NIOSSHPrivateKey {
    // Strip PEM headers/footers and whitespace
    let lines = pem.components(separatedBy: .newlines)
    let base64Lines = lines.filter {
        !$0.hasPrefix("-----") && !$0.isEmpty
    }
    let base64String = base64Lines.joined()

    guard let keyData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
        throw OpenSSHKeyParseError.invalidPEMFormat
    }

    var reader = DataReader(data: keyData)

    // Check magic: "openssh-key-v1\0"
    let magic = "openssh-key-v1\0"
    guard let magicBytes = reader.readBytes(count: magic.utf8.count),
          Data(magicBytes) == magic.data(using: .utf8) else {
        throw OpenSSHKeyParseError.invalidMagic
    }

    // Read ciphername (should be "none")
    guard let cipherName = reader.readLengthPrefixedString() else {
        throw OpenSSHKeyParseError.invalidKeyData
    }
    if cipherName != "none" {
        throw OpenSSHKeyParseError.unsupportedCipher(cipherName)
    }

    // Read kdfname (should be "none")
    guard let _ = reader.readLengthPrefixedString() else {
        throw OpenSSHKeyParseError.invalidKeyData
    }

    // Read kdfoptions (empty for "none")
    guard let _ = reader.readLengthPrefixedData() else {
        throw OpenSSHKeyParseError.invalidKeyData
    }

    // Number of keys (always 1)
    guard let numKeys = reader.readUInt32(), numKeys == 1 else {
        throw OpenSSHKeyParseError.invalidKeyData
    }

    // Skip public key blob
    guard let _ = reader.readLengthPrefixedData() else {
        throw OpenSSHKeyParseError.invalidKeyData
    }

    // Read private key blob
    guard let privateBlob = reader.readLengthPrefixedData() else {
        throw OpenSSHKeyParseError.invalidKeyData
    }

    var blobReader = DataReader(data: privateBlob)

    // Skip 8 check bytes (two identical uint32s used to verify correct decryption)
    guard let _ = blobReader.readBytes(count: 8) else {
        throw OpenSSHKeyParseError.invalidKeyData
    }

    // Read key type string (e.g. "ssh-ed25519")
    guard let _ = blobReader.readLengthPrefixedString() else {
        throw OpenSSHKeyParseError.invalidKeyData
    }

    // Skip public key bytes (32 bytes for Ed25519, length-prefixed)
    guard let _ = blobReader.readLengthPrefixedData() else {
        throw OpenSSHKeyParseError.invalidKeyData
    }

    // Read private key bytes: 64 bytes total (first 32 = seed/private, last 32 = public)
    guard let privKeyData = blobReader.readLengthPrefixedData(), privKeyData.count >= 32 else {
        throw OpenSSHKeyParseError.keyExtractionFailed
    }

    // First 32 bytes are the private key seed
    let seed = privKeyData.prefix(32)

    do {
        let curve25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return NIOSSHPrivateKey(ed25519Key: curve25519Key)
    } catch {
        throw OpenSSHKeyParseError.keyExtractionFailed
    }
}

// MARK: - Generate Ed25519 Key Pair

func generateEd25519KeyPair() throws -> (privateKeyPEM: String, publicKeyOpenSSH: String) {
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey

    // Build OpenSSH public key format: "ssh-ed25519 <base64>"
    var pubKeyBlob = Data()
    let keyType = "ssh-ed25519"
    let keyTypeData = keyType.data(using: .utf8)!
    var len = UInt32(keyTypeData.count).bigEndian
    pubKeyBlob.append(contentsOf: withUnsafeBytes(of: len) { Data($0) })
    pubKeyBlob.append(keyTypeData)

    let pubKeyBytes = publicKey.rawRepresentation
    len = UInt32(pubKeyBytes.count).bigEndian
    pubKeyBlob.append(contentsOf: withUnsafeBytes(of: len) { Data($0) })
    pubKeyBlob.append(pubKeyBytes)

    let pubKeyBase64 = pubKeyBlob.base64EncodedString()
    let publicKeyOpenSSH = "ssh-ed25519 \(pubKeyBase64) MobileSSH"

    // Build OpenSSH private key PEM format
    let privateKeyPEM = buildOpenSSHPrivateKeyPEM(privateKey: privateKey, publicKey: publicKey)

    return (privateKeyPEM, publicKeyOpenSSH)
}

private func buildOpenSSHPrivateKeyPEM(
    privateKey: Curve25519.Signing.PrivateKey,
    publicKey: Curve25519.Signing.PublicKey
) -> String {
    var blob = Data()

    func writeString(_ s: String) {
        let d = s.data(using: .utf8)!
        var len = UInt32(d.count).bigEndian
        blob.append(contentsOf: withUnsafeBytes(of: len) { Data($0) })
        blob.append(d)
    }

    func writeData(_ d: Data) {
        var len = UInt32(d.count).bigEndian
        blob.append(contentsOf: withUnsafeBytes(of: len) { Data($0) })
        blob.append(d)
    }

    func writeUInt32(_ v: UInt32) {
        var val = v.bigEndian
        blob.append(contentsOf: withUnsafeBytes(of: val) { Data($0) })
    }

    // Magic
    blob.append("openssh-key-v1\0".data(using: .utf8)!)

    // ciphername, kdfname, kdfoptions
    writeString("none")
    writeString("none")
    writeData(Data())

    // num keys
    writeUInt32(1)

    // public key blob
    var pubBlob = Data()
    func writePubString(_ s: String) {
        let d = s.data(using: .utf8)!
        var len = UInt32(d.count).bigEndian
        pubBlob.append(contentsOf: withUnsafeBytes(of: len) { Data($0) })
        pubBlob.append(d)
    }
    func writePubData(_ d: Data) {
        var len = UInt32(d.count).bigEndian
        pubBlob.append(contentsOf: withUnsafeBytes(of: len) { Data($0) })
        pubBlob.append(d)
    }
    writePubString("ssh-ed25519")
    writePubData(publicKey.rawRepresentation)
    writeData(pubBlob)

    // private blob
    var privBlob = Data()
    func writePrivString(_ s: String) {
        let d = s.data(using: .utf8)!
        var len = UInt32(d.count).bigEndian
        privBlob.append(contentsOf: withUnsafeBytes(of: len) { Data($0) })
        privBlob.append(d)
    }
    func writePrivData(_ d: Data) {
        var len = UInt32(d.count).bigEndian
        privBlob.append(contentsOf: withUnsafeBytes(of: len) { Data($0) })
        privBlob.append(d)
    }

    // check bytes (same uint32 twice)
    let checkInt = UInt32.random(in: 0..<UInt32.max)
    var check = checkInt.bigEndian
    privBlob.append(contentsOf: withUnsafeBytes(of: check) { Data($0) })
    privBlob.append(contentsOf: withUnsafeBytes(of: check) { Data($0) })

    // key type
    writePrivString("ssh-ed25519")

    // public key
    writePrivData(publicKey.rawRepresentation)

    // private key (seed + public = 64 bytes)
    var privKeyFull = Data()
    privKeyFull.append(privateKey.rawRepresentation) // 32 bytes seed
    privKeyFull.append(publicKey.rawRepresentation)  // 32 bytes public
    writePrivData(privKeyFull)

    // comment
    writePrivString("MobileSSH")

    // padding
    var pad: UInt8 = 1
    while privBlob.count % 8 != 0 {
        privBlob.append(pad)
        pad += 1
    }

    writeData(privBlob)

    // Encode to PEM
    let base64 = blob.base64EncodedString(options: [.lineLength64Characters])
    return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n"
}

// MARK: - DataReader Helper

private struct DataReader {
    let data: Data
    var offset: Int = 0

    mutating func readBytes(count: Int) -> [UInt8]? {
        guard offset + count <= data.count else { return nil }
        let bytes = Array(data[offset..<offset + count])
        offset += count
        return bytes
    }

    mutating func readData(count: Int) -> Data? {
        guard offset + count <= data.count else { return nil }
        let result = data[offset..<offset + count]
        offset += count
        return result
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(count: 4) else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    mutating func readLengthPrefixedData() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readData(count: Int(length))
    }

    mutating func readLengthPrefixedString() -> String? {
        guard let data = readLengthPrefixedData() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
