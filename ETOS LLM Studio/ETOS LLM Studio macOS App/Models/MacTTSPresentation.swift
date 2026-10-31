import AVFoundation
import ETOSCore
import Foundation

struct MacTTSServiceRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let kind: String
    let ready: Bool
}

struct MacTTSVoiceRow: Identifiable, Sendable {
    let id: String
    let title: String
}

struct MacTTSPresentation: Sendable {
    let snapshot: TTSConfigurationSnapshot
    let rows: [MacTTSServiceRow]
    let servicesByID: [UUID: TTSServiceConfiguration]
    let selected: TTSServiceConfiguration?
    let guideValue: JSONValue
    let identifiers: [String]

    static func prepare(_ snapshot: TTSConfigurationSnapshot) -> Self {
        let rows = snapshot.services.map { MacTTSServiceRow(id: $0.id, title: $0.name, kind: $0.providerKind.localizedName, ready: $0.isReady) }
        return .init(snapshot: snapshot, rows: rows,
            servicesByID: Dictionary(uniqueKeysWithValues: snapshot.services.map { ($0.id, $0) }),
            selected: snapshot.selectedService, guideValue: .array(rows.map {
                .dictionary(["id": .string($0.id.uuidString), "name": .string($0.title), "provider": .string($0.kind), "ready": .bool($0.ready)])
            }), identifiers: rows.map { $0.id.uuidString })
    }

    static func voices() -> [MacTTSVoiceRow] {
        AVSpeechSynthesisVoice.speechVoices().map { .init(id: $0.identifier, title: "\($0.name) (\($0.language))") }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
