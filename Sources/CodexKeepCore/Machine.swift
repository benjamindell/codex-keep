import Foundation

public enum Machine {
    public static func currentName() -> String {
        let rawName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = rawName
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))

        return sanitized.isEmpty ? "Mac" : sanitized
    }
}
