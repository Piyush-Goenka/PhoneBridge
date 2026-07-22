import Foundation

// PhoneBridge is a single-user menu-bar app. Keep its support directory and
// every secret file accessible only to the account running the app.
enum PrivateFile {
    static func prepareDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func protect(_ file: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try protect(file)
    }
}
