#if os(iOS)
import Foundation
import CryptoKit
import Testing
@testable import ETOS_LLM_Studio_App

@Suite("CFL private media disk cache")
struct CFLMediaDiskCacheTests {
    @Test("Original bytes survive a new cache instance and filenames hide keys")
    func rawBytesAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "https://example.invalid/private?token=synthetic-test-only"
        let gif = Data([71, 73, 70, 56, 57, 97, 0, 1, 2, 3])
        let webp = Data([82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80])
        let first = try CFLMediaDiskCache(directory: root)
        try await first.write(gif, key: key, withoutExpiry: false)
        try await first.write(webp, key: "thumbnail", withoutExpiry: true)
        let second = try CFLMediaDiskCache(directory: root)
        #expect(try await second.read(key: key) == gif)
        #expect(try await second.read(key: "thumbnail") == webp)
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let paths = enumerator.allObjects.compactMap { ($0 as? URL)?.lastPathComponent }
        #expect(!paths.contains { $0.contains("synthetic-test-only") || $0.contains("example.invalid") })
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("com.onevcat.Kingfisher.ImageCache.ETOS.CFL.media")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(digest).path)
        let expiration = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(expiration.timeIntervalSinceNow - 7 * 24 * 60 * 60) < 60)
        try await second.remove(key: key)
        #expect(try await second.read(key: key) == nil)
        #expect(try await second.read(key: "thumbnail") == webp)
    }

    @Test("A small test budget lazily evicts raw data")
    func capacityCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try CFLMediaDiskCache(directory: root, sizeLimit: 100)
        try await cache.write(Data(repeating: 1, count: 80), key: "a", withoutExpiry: true)
        try await cache.write(Data(repeating: 2, count: 80), key: "b", withoutExpiry: false)
        await cache.cleanExpiredAndOversize()
        let a = try await cache.read(key: "a"), b = try await cache.read(key: "b")
        #expect(a == nil || b == nil)
    }
}
#endif
