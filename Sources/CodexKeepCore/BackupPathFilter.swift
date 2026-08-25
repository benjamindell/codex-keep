import Foundation

enum BackupPathFilter {
    private static let generatedDirectoryNames: Set<String> = [
        ".build",
        ".cache",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".tox",
        ".venv",
        "__pycache__",
        "build",
        "cache",
        "deriveddata",
        "dist",
        "node_modules",
        "tmp",
        "venv"
    ]

    static func shouldExclude(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { component in
            let name = component.lowercased()
            return generatedDirectoryNames.contains(name)
                || name == ".git"
                || name == ".ds_store"
                || name.hasSuffix(".pyc")
                || name.hasSuffix(".pyo")
                || name.hasSuffix(".tmp")
                || name.hasSuffix(".swp")
                || name.hasSuffix(".swpx")
                || name.hasPrefix(".#")
                || name.hasSuffix("~")
        }
    }
}
