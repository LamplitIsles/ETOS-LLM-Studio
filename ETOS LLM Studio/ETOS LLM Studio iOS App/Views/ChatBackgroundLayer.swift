import SwiftUI
import UIKit
import AVFoundation
import ETOSCore

struct ChatComposerCircleBackground: View {
    let usesLiquidGlass: Bool
    let tint: Color
    let stroke: Color
    let shadow: Color

    var body: some View {
        Group {
            if #available(iOS 26.0, *), usesLiquidGlass {
                Circle().fill(Color.clear)
                    .glassEffect(.clear.interactive(), in: Circle())
                    .overlay(Circle().fill(tint))
                    .overlay(Circle().stroke(stroke, lineWidth: 0.5))
                    .shadow(color: shadow, radius: 6, x: 0, y: 2)
            } else {
                Circle().fill(.ultraThinMaterial)
                    .overlay(Circle().fill(tint))
                    .overlay(Circle().stroke(stroke, lineWidth: 0.5))
                    .shadow(color: shadow, radius: 6, x: 0, y: 2)
            }
        }
    }
}

struct ChatScrollNavigationButton: View {
    let systemName: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let usesLiquidGlass: Bool
    var circleSize: CGFloat = 40
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var config = AppConfigStore.shared

    private var tint: Color {
        let opacity = LiquidGlassTintSetting.normalized(config.liquidGlassTintOpacity)
        return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }
    private var stroke: Color { Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28) }
    private var shadow: Color { Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1) }
    private var usesSystemGlassFeedback: Bool {
        if #available(iOS 26.0, *) { return usesLiquidGlass }
        return false
    }
    private var icon: some View {
        Image(systemName: systemName)
            .etFont(.system(size: max(14, circleSize * 0.45), weight: .semibold))
            .foregroundColor(TelegramColors.attachButtonColor)
            .frame(width: circleSize, height: circleSize)
            .contentShape(Circle())
    }
    var body: some View {
        Button(action: action) {
            icon.background {
                ChatComposerCircleBackground(usesLiquidGlass: usesLiquidGlass, tint: tint, stroke: stroke, shadow: shadow)
            }
        }
        .buttonStyle(ComposerPressButtonStyle(usesSystemGlassFeedback: usesSystemGlassFeedback))
        .frame(width: max(44, circleSize), height: max(44, circleSize))
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.36)
    }
}

private struct LoopingBackgroundVideoView: UIViewRepresentable {
    let url: URL
    let contentMode: String
    let shouldPlay: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        context.coordinator.configure(
            view: view,
            url: url,
            contentMode: contentMode,
            shouldPlay: shouldPlay
        )
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        context.coordinator.configure(
            view: uiView,
            url: url,
            contentMode: contentMode,
            shouldPlay: shouldPlay
        )
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.playerLayer.player = nil
    }

    final class Coordinator {
        private var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func configure(
            view: PlayerContainerView,
            url: URL,
            contentMode: String,
            shouldPlay: Bool
        ) {
            view.playerLayer.videoGravity = contentMode == "fit" ? .resizeAspect : .resizeAspectFill
            if currentURL == url, view.playerLayer.player === player {
                updatePlayback(shouldPlay: shouldPlay)
                return
            }

            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.actionAtItemEnd = .none
            looper = AVPlayerLooper(player: player, templateItem: item)
            view.playerLayer.player = player
            self.player = player
            currentURL = url
            updatePlayback(shouldPlay: shouldPlay)
        }

        private func updatePlayback(shouldPlay: Bool) {
            if shouldPlay {
                player?.play()
            } else {
                player?.pause()
            }
        }

        func stop() {
            player?.pause()
            player = nil
            looper = nil
            currentURL = nil
        }
    }

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }
}

struct ChatBackgroundLayer: View {
    @ObservedObject private var background = ChatBackgroundModel.shared
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var appConfig = AppConfigStore.shared
    let isChatVisible: Bool

    var body: some View {
        GeometryReader { geometry in
            Group {
                if background.enableBackground,
                   background.currentBackgroundIsVideo,
                   let videoURL = background.currentBackgroundMediaURL {
                    ZStack {
                        if background.backgroundContentMode == "fit" {
                            colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground)
                        }

                        LoopingBackgroundVideoView(
                            url: videoURL,
                            contentMode: background.backgroundContentMode,
                            shouldPlay: scenePhase == .active && (
                                isChatVisible || appConfig.continueVideoBackgroundPlaybackWhenChatHidden
                            )
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .clipped()
                        .blur(radius: background.backgroundBlur)
                        .opacity(background.backgroundOpacity)
                    }
                } else if background.enableBackground,
                          let image = background.currentBackgroundImageBlurredUIImage {
                    ZStack {
                        if background.backgroundContentMode == "fit" {
                            colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground)
                        }

                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(
                                contentMode: background.backgroundContentMode == "fill" ? .fill : .fit
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .clipped()
                            .opacity(background.backgroundOpacity)
                    }
                } else {
                    TelegramDefaultBackground()
                }
            }
            .task(id: DisplayImageTarget(
                size: geometry.size, scale: displayScale,
                fillsBounds: background.backgroundContentMode == "fill"
            )) {
                background.updateBackgroundDisplayTarget(size: geometry.size, scale: displayScale)
            }
        }
    }

}
