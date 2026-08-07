import Foundation

public enum ObsidianURL {
    public static func open(vault: String, file: String) -> URL {
        let encodedVault = percentEncode(vault)
        let encodedFile = percentEncode(file)
        return URL(string: "obsidian://open?vault=\(encodedVault)&file=\(encodedFile)")!
    }

    private static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
