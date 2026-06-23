import Foundation

enum BackupPathFilter {
    static func shouldExclude(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { component in
            component == ".git"
                || component == ".DS_Store"
                || component.hasSuffix(".tmp")
                || component.hasSuffix(".swp")
                || component.hasSuffix(".swpx")
                || component.hasPrefix(".#")
                || component.hasSuffix("~")
        }
    }
}
