import Foundation

/// Collects every attachment outcome; the caller must reject the whole input if any save fails.
struct ChatAttachmentPreparation {
    struct Failure: Sendable {
        let source: ChatSendPresentationSource
        let fileName: String
        let description: String
    }
    struct SavedImage {
        let fileName: String
        let source: ChatSendPresentationSource
    }
    struct SavedFile {
        let fileName: String
        let attachment: FileAttachment
    }
    let audioFileName: String?
    let images: [SavedImage]
    let files: [SavedFile]
    let failures: [Failure]
    var isComplete: Bool { failures.isEmpty }

    /// The generation endpoint receives all reference bytes in one POST.
    /// Storage may choose a different name; retain the original source identity.
    static func prepareImageGenerationReferences(
        _ images: [ImageAttachment], save: (ImageAttachment) -> String?
    ) -> Self {
        var saved: [SavedImage] = []
        var failures: [Failure] = []
        for image in images {
            let source = ChatSendPresentationSource.image(image.id)
            guard !image.data.isEmpty else {
                failures.append(.init(source: source, fileName: image.fileName, description: "image data unavailable"))
                continue
            }
            if let storedName = save(image) {
                saved.append(.init(fileName: storedName, source: source))
            } else {
                failures.append(.init(source: source, fileName: image.fileName, description: "image storage write failed"))
            }
        }
        return Self(audioFileName: nil, images: saved, files: [], failures: failures)
    }

    static func prepare(
        audio: AudioAttachment?, audioFileName: String?, images: [ImageAttachment], files: [FileAttachment],
        saveAudio: (Data, String) -> Bool, saveImage: (Data, String) -> Bool,
        saveFile: (Data, String) -> String?
    ) -> Self {
        var failures: [Failure] = []
        var savedAudio: String?
        var savedImages: [SavedImage] = []
        var savedFiles: [SavedFile] = []
        if let audio {
            if let audioFileName {
                if saveAudio(audio.data, audioFileName) { savedAudio = audioFileName }
                else { failures.append(Failure(source: .audio(audio.id), fileName: audio.fileName, description: "audio storage write failed")) }
            } else {
                failures.append(Failure(source: .audio(audio.id), fileName: audio.fileName, description: "audio target name unavailable"))
            }
        }
        for image in images {
            if saveImage(image.data, image.fileName) {
                savedImages.append(SavedImage(fileName: image.fileName, source: .image(image.id)))
            } else {
                failures.append(Failure(source: .image(image.id), fileName: image.fileName, description: "image storage write failed"))
            }
        }
        for file in files {
            let name = (file.fileName as NSString).lastPathComponent
            if let storedName = saveFile(file.data, name) {
                savedFiles.append(SavedFile(fileName: storedName, attachment: file))
            } else {
                failures.append(Failure(source: .file(file.id), fileName: file.fileName, description: "file storage write failed"))
            }
        }
        return Self(audioFileName: savedAudio, images: savedImages, files: savedFiles, failures: failures)
    }
}
