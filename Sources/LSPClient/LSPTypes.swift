import Foundation

public enum Language: String, Codable, Sendable, Hashable, CaseIterable {
    case swift, typescript, javascript, python, go, rust

    /// Maps a file path's extension to its language, or nil if unsupported.
    /// The single source of truth for extension → language routing.
    public static func from(path: String) -> Language? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift":                                return .swift
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return .typescript
        case "py", "pyi":                            return .python
        case "go":                                   return .go
        case "rs":                                   return .rust
        default:                                     return nil
        }
    }
}
