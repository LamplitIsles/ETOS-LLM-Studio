import SwiftUI
import ETOSCore

struct SpeechInputSettingsView: View {
    @Binding var enableSpeechInput: Bool
    @Binding var audioRecordingFormat: AudioRecordingFormat

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("启用语音输入", comment: ""), isOn: $enableSpeechInput)
                if enableSpeechInput {
                    Picker(NSLocalizedString("音频录制格式", comment: ""), selection: $audioRecordingFormat) {
                        ForEach(AudioRecordingFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    Text(audioRecordingFormat.formatDescription)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(NSLocalizedString("使用系统语音识别，确认后将文字放入输入框。", comment: "System speech input description"))
            }
        }
        .navigationTitle(NSLocalizedString("语音输入", comment: ""))
        .guideSettingsPageContext(
            id: "settings-speech-input",
            title: NSLocalizedString("语音输入", comment: "语音输入向导标题"),
            documents: [GuideDocumentReference(id: "speech-input", title: "Speech Input")],
            settings: [
                .bool("enabled", label: NSLocalizedString("启用语音输入", comment: "语音输入向导字段"), get: { enableSpeechInput }, set: { enableSpeechInput = $0 }),
                .string(
                    "recording_format",
                    label: NSLocalizedString("音频录制格式", comment: "语音输入向导字段"),
                    allowedValues: AudioRecordingFormat.allCases.map(\.rawValue),
                    allowsEmpty: false,
                    get: { audioRecordingFormat.rawValue },
                    set: { rawValue in
                        if let format = AudioRecordingFormat(rawValue: rawValue) { audioRecordingFormat = format }
                    }
                )
            ]
        )
    }
}
