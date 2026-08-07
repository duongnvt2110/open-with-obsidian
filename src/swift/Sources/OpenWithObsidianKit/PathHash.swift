import Foundation
import CryptoKit

public enum PathHash {
    public static func shortHex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }
}
