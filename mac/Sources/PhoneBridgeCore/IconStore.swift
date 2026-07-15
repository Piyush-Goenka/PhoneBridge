import Foundation

public protocol IconStoring {
    func has(_ hash: String) -> Bool
    func save(_ hash: String, png: Data) throws
    func path(_ hash: String) -> URL?
}

public final class DiskIconStore: IconStoring {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ hash: String) -> URL {
        let safe = hash.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe + ".png")
    }

    public func has(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(hash).path)
    }

    public func save(_ hash: String, png: Data) throws {
        try png.write(to: fileURL(hash))
    }

    public func path(_ hash: String) -> URL? {
        has(hash) ? fileURL(hash) : nil
    }
}
