#if os(iOS)
import AVFoundation
import Combine
import ETOSCore
import SwiftUI

/// One player for the conversation: switching messages cancels the old load and playback.
@MainActor
final class CFLVoicePlayer: ObservableObject {
    enum Phase { case idle, loading, playing, paused, failed }
    @Published private(set) var id: CFLDisplayMessage.ID?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var playerDelegate: CFLVoicePlayerDelegate?
    private var loadTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var generation = UUID()

    func toggle(id: CFLDisplayMessage.ID, load: @escaping @MainActor () async throws -> Data) {
        if self.id == id, let player {
            if phase == .playing {
                player.pause()
                phase = .paused
                progressTask?.cancel()
                progressTask = nil
            } else {
                if player.currentTime >= player.duration { player.currentTime = 0 }
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                    try AVAudioSession.sharedInstance().setActive(true)
                    guard player.play() else { throw CFLFailure.requestFailed }
                    phase = .playing
                    watchProgress()
                } catch { phase = .failed }
            }
            return
        }
        stop()
        self.id = id
        phase = .loading
        let token = generation
        loadTask = Task { [weak self] in
            do {
                let data = try await load()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                let player = try AVAudioPlayer(data: data)
                let delegate = CFLVoicePlayerDelegate { [weak self] success in
                    guard let self, self.generation == token else { return }
                    self.progressTask?.cancel()
                    self.progressTask = nil
                    if success {
                        self.currentTime = self.duration
                        self.phase = .paused
                    } else {
                        self.player?.stop()
                        self.player = nil
                        self.playerDelegate = nil
                        self.currentTime = 0
                        self.duration = 0
                        self.phase = .failed
                    }
                }
                player.delegate = delegate
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                guard player.prepareToPlay(), player.play() else { throw CFLFailure.requestFailed }
                self.player = player
                self.playerDelegate = delegate
                self.duration = player.duration
                self.currentTime = 0
                self.phase = .playing
                self.loadTask = nil
                self.watchProgress()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.player = nil
                self.loadTask = nil
                self.phase = .failed
            }
        }
    }

    func seek(_ value: Double, id: CFLDisplayMessage.ID) {
        guard self.id == id, let player, player.duration > 0 else { return }
        player.currentTime = min(max(value, 0), 1) * player.duration
        currentTime = player.currentTime
    }

    func stop() {
        generation = UUID()
        loadTask?.cancel()
        progressTask?.cancel()
        loadTask = nil
        progressTask = nil
        player?.stop()
        player = nil
        playerDelegate = nil
        id = nil
        phase = .idle
        currentTime = 0
        duration = 0
    }

    private func watchProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    if player.currentTime >= player.duration - 0.1 { self.currentTime = player.duration }
                    self.phase = .paused
                    self.progressTask = nil
                    return
                }
            }
        }
    }

    deinit {
        loadTask?.cancel()
        progressTask?.cancel()
        player?.stop()
    }
}

private final class CFLVoicePlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor @Sendable (Bool) -> Void

    nonisolated init(onFinish: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [onFinish] in onFinish(flag) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [onFinish] in onFinish(false) }
    }
}

struct CFLVoiceMessage: View {
    let item: CFLDisplayMessage
    let voice: CFLVoiceRef
    @ObservedObject var model: CFLConversationModel
    @ObservedObject var player: CFLVoicePlayer
    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var background = ChatBackgroundModel.shared
    @ObservedObject private var appearance = ChatAppearanceProfileManager.shared

    private var selected: Bool { player.id == item.id }
    private var phase: CFLVoicePlayer.Phase { selected ? player.phase : .idle }
    private var progress: Double {
        selected && player.duration > 0 ? player.currentTime / player.duration : 0
    }
    private var waveform: some View {
        let bytes = voice.id.isEmpty ? [UInt8(48)] : Array(voice.id.utf8)
        return ZStack {
            HStack(spacing: 2) {
                ForEach(0..<36, id: \.self) { index in
                    let sample = Int(bytes[index % bytes.count])
                    Capsule()
                        .fill(Double(index + 1) / 36 <= progress ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 2.5, height: CGFloat(5 + (sample * (index + 7)) % 15))
                }
            }
            .accessibilityHidden(true)
            Slider(value: Binding(get: { progress }, set: { player.seek($0, id: item.id) }), in: 0...1)
                .opacity(0.02)
                .disabled(!selected || player.duration <= 0)
                .accessibilityLabel(Text(NSLocalizedString("语音进度", comment: "Voice playback progress")))
        }
        .frame(height: 32)
    }
    private var caption: String {
        if phase == .loading { return NSLocalizedString("正在加载", comment: "Loading voice message") }
        if phase == .failed { return NSLocalizedString("无法播放此音频。", comment: "Voice playback failed") }
        guard selected, player.duration > 0 else { return NSLocalizedString("语音消息", comment: "Voice message") }
        return "\(time(player.currentTime)) / \(time(player.duration))"
    }
    private func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    private var bubbleColor: Color {
        let slot = appearance.activeProfile.assistantBubble
        if slot.isEnabled {
            return ChatAppearanceColorCodec.color(from: slot.hex, fallback: Color(uiColor: .secondarySystemBackground))
                .opacity(background.enableBackground ? 0.75 : 1)
        }
        return background.enableBackground ? Color(uiColor: .secondarySystemBackground).opacity(0.75) : Color(uiColor: .systemBackground)
    }

    var body: some View {
        HStack {
            HStack(spacing: 12) {
                Button {
                    player.toggle(id: item.id) {
                        try await model.voice(voice, target: item.id.target, session: item.id.session,
                                              revision: item.sessionRevision, clientID: item.clientID)
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.15)).frame(width: 44, height: 44)
                        if phase == .loading {
                            ProgressView()
                        } else {
                            Image(systemName: phase == .playing ? "pause.fill" : "play.fill")
                                .etFont(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(phase == .loading)
                .accessibilityLabel(Text(NSLocalizedString(phase == .playing ? "暂停语音" : phase == .failed ? "重试播放语音" : "播放语音", comment: "Voice playback")))

                VStack(alignment: .leading, spacing: 4) {
                    waveform
                    Text(caption).etFont(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                .frame(width: 160)
            }
            .padding(12)
            .background {
                if !config.enableNoBubbleUI {
                    ChatBubbleBackground(shape: RoundedRectangle(cornerRadius: CGFloat(config.chatBubbleCornerRadius)), fill: AnyShapeStyle(bubbleColor), enableLiquidGlass: config.enableLiquidGlass)
                }
            }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, config.enableNoBubbleUI ? 9 : 3)
    }
}
#endif
