import Foundation

enum ChatSendPresentationSource: Equatable, Sendable { case audio(UUID), image(UUID), file(UUID) }
struct AudioAttachment { let id: UUID; let data: Data; let fileName: String }
struct ImageAttachment { let id: UUID; let data: Data; let fileName: String }
struct FileAttachment { let id: UUID; let data: Data; let fileName: String }
@main struct ChatAttachmentPreparationChecks {
    static func main() {
        let audio = AudioAttachment(id: UUID(), data: Data([1]), fileName: "voice.m4a")
        let image = ImageAttachment(id: UUID(), data: Data([2]), fileName: "image.png")
        let file = FileAttachment(id: UUID(), data: Data([3]), fileName: "folder/report.txt")
        let failed = ChatAttachmentPreparation.prepare(
            audio: audio, audioFileName: "stored.m4a", images: [image], files: [file],
            saveAudio: { _, _ in true }, saveImage: { _, _ in false }, saveFile: { _, _ in nil }
        )
        precondition(!failed.isComplete && failed.audioFileName == "stored.m4a")
        precondition(failed.failures.count == 2)
        precondition(failed.failures[0].source == .image(image.id) && failed.failures[0].fileName == image.fileName)
        precondition(failed.failures[1].source == .file(file.id) && failed.failures[1].fileName == file.fileName)
        precondition(failed.failures.allSatisfy { !$0.description.isEmpty })
        var audioSaveCalls = 0
        let missingAudioName = ChatAttachmentPreparation.prepare(
            audio: audio, audioFileName: nil, images: [], files: [],
            saveAudio: { _, _ in audioSaveCalls += 1; return true },
            saveImage: { _, _ in true }, saveFile: { _, name in name }
        )
        precondition(!missingAudioName.isComplete && audioSaveCalls == 0)
        precondition(missingAudioName.failures.first?.source == .audio(audio.id))
        var dispatched = 0
        if failed.isComplete { dispatched += 1 }
        precondition(dispatched == 0)
        let complete = ChatAttachmentPreparation.prepare(
            audio: audio, audioFileName: "stored.m4a", images: [image], files: [file],
            saveAudio: { _, _ in true }, saveImage: { _, _ in true },
            saveFile: { _, name in precondition(name == "report.txt"); return "existing-report.txt" }
        )
        precondition(complete.isComplete && complete.images.first?.source == .image(image.id))
        precondition(complete.files.first?.attachment.id == file.id && complete.files.first?.fileName == "existing-report.txt")
        let empty = ImageAttachment(id: UUID(), data: Data(), fileName: "empty.png")
        let missing = ImageAttachment(id: UUID(), data: Data([4]), fileName: "missing.png")
        var imageSaves = 0
        let references = ChatAttachmentPreparation.prepareImageGenerationReferences([image, empty, missing]) { value in
            imageSaves += 1
            return value.id == image.id ? "renamed.png" : nil
        }
        precondition(!references.isComplete && imageSaves == 2)
        precondition(references.images.first?.source == .image(image.id) && references.images.first?.fileName == "renamed.png")
        precondition(references.failures.map(\.source) == [.image(empty.id), .image(missing.id)])
        precondition(references.failures.map(\.fileName) == ["empty.png", "missing.png"])
        print("attachment preparation checks passed")
    }
}
