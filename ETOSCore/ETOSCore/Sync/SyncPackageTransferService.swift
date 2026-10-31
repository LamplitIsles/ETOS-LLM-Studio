import Foundation

/// ETOS 同步导出信封。
public struct SyncPackageExportEnvelope: Codable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var envelope: SyncEnvelopeV2

    public init(
        schemaVersion: Int,
        exportedAt: Date,
        envelope: SyncEnvelopeV2
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.envelope = envelope
    }
}
