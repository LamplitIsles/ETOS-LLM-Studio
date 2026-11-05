#if os(iOS)
import Foundation
import CryptoKit
import Kingfisher
import ETOSCore

/// One private Kingfisher store for all reconstructible CFL copies. Keys contain
/// only a digest; source URLs and credentials never become
/// filenames. This store is unrelated to the durable pending-send store.
actor CFLMediaDiskCache: CFLMediaCache {
    static let shared: CFLMediaDiskCache? = try? CFLMediaDiskCache()

    private let disk: DiskStorage.Backend<Data>
    private let files: FileManager
    private var cleanupScheduled = false

    init(directory: URL? = nil, files: FileManager = .default, sizeLimit: UInt = 1_073_741_824) throws {
        self.files = files
        var config = DiskStorage.Config(name: "ETOS.CFL.media", sizeLimit: sizeLimit,
                                        fileManager: files, directory: directory)
        config.usesHashedFileName = false
        disk = try DiskStorage.Backend<Data>(config: config)
        var location = disk.directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                ofItemAtPath: location.path)
    }

    private func name(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return digest
    }

    func read(key: String) throws -> Data? {
        return try disk.value(forKey: name(key))
    }

    func write(_ data: Data, key: String, withoutExpiry: Bool) throws {
        try disk.store(value: data, forKey: name(key),
                       expiration: withoutExpiry ? .never : .days(7),
                       writeOptions: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if !cleanupScheduled {
            cleanupScheduled = true
            Task { await cleanExpiredAndOversize() }
        }
    }

    func update(key: String, withoutExpiry: Bool,
                transform: @Sendable (Data?) -> Data?) throws {
        let old = try disk.value(forKey: name(key))
        if let next = transform(old) {
            try write(next, key: key, withoutExpiry: withoutExpiry)
        }
    }

    func cleanExpiredAndOversize() {
        defer { cleanupScheduled = false }
        // Kingfisher's capacity limit is a lazy target, not a hard quota.
        _ = try? disk.removeExpiredValues()
        _ = try? disk.removeSizeExceededValues()
    }

    func remove(key: String) throws {
        let filename = name(key)
        guard files.fileExists(atPath: disk.directoryURL.appendingPathComponent(filename).path) else { return }
        try disk.remove(forKey: filename)
    }

}
#endif
