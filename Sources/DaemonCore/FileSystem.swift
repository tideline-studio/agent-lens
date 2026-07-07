import Foundation

public struct FileSystem: Sendable {
    public var contents: @Sendable (String) throws -> Data
    public var stat: @Sendable (String) throws -> FileStat

    public init(
        contents: @escaping @Sendable (String) throws -> Data,
        stat: @escaping @Sendable (String) throws -> FileStat
    ) {
        self.contents = contents
        self.stat = stat
    }
}

public struct FileStat: Sendable {
    public let mtimeNs: UInt64
    public let size: UInt64

    public init(mtimeNs: UInt64, size: UInt64) {
        self.mtimeNs = mtimeNs
        self.size = size
    }
}

extension FileSystem {
    public static let live = FileSystem(
        contents: { path in try Data(contentsOf: URL(fileURLWithPath: path)) },
        stat: { path in
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? Int) ?? 0
            return FileStat(mtimeNs: UInt64(max(0, mtime) * 1e9), size: UInt64(size))
        }
    )
}
