import Combine
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("发送来源的真实输入区边界", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct ChatSendFlightComposerLayoutTests {
    enum Scenario: CaseIterable, Sendable {
        case expandedFirstLine
        case longDraft
    }

    @Test("真实输入框展开时限制来源离场边界", arguments: ["capsule", "adaptive", "card"], Scenario.allCases)
    func realComposerBoundsDriveDeparture(style: String, scenario: Scenario) async throws {
        let config = AppConfigStore.shared
        await config.waitForPersistentStoreLoaded()
        let originalStyle = config.chatComposerStyle
        let originalBackground = config.currentBackgroundImage
        config.chatComposerStyle = style
        do {
            defer {
                config.chatComposerStyle = originalStyle
                config.currentBackgroundImage = originalBackground
            }
            let draft: String
            switch scenario {
            case .expandedFirstLine: draft = "展开框首行"
            case .longDraft: draft = (1...80).map { "第 \($0) 行：真实滚动片段。" }.joined(separator: "\n")
            }
            let sourceID: ChatSendPresentationSource = .text
            let controller = ChatSendFlightController()
            let sources = ChatSendFlightSources()
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            let host = UIHostingController(rootView: ComposerHost(
                controller: controller, sources: sources,
                draft: draft, startsExpanded: style != "card"
            ))
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            // 只在初次挂载排布，之后依靠真实 Composer 更新和既有文本控件的滚动。
            host.view.layoutIfNeeded()
            let surface = UIView(frame: window.bounds)
            surface.isUserInteractionEnabled = false
            window.addSubview(surface)
            controller.attach(to: surface)
            defer {
                controller.cancel()
                window.isHidden = true
                window.rootViewController = nil
            }

            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let editor = editor(in: host.view, containing: draft),
                   editor.bounds.height > 1,
                   controller.composerAnchor?.window === window,
                   controller.composerContentAnchor?.window === window,
                   controller.viewportAnchor?.window === window {
                    if scenario != .longDraft || style == "card"
                        || (editor as? UITextView).map({ $0.contentSize.height > $0.bounds.height + 100 }) == true {
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let editor = try #require(editor(in: host.view, containing: draft))
            let outerAnchor = try #require(controller.composerAnchor)
            let contentAnchor = try #require(controller.composerContentAnchor)
            try #require(outerAnchor.window === window && contentAnchor.window === window)
            let outerFrame = outerAnchor.convert(outerAnchor.bounds, to: surface)
            let contentFrame = contentAnchor.convert(contentAnchor.bounds, to: surface)

            if scenario == .longDraft, style != "card" {
                let textView = try #require(editor as? UITextView)
                try #require(textView.contentSize.height > textView.bounds.height + 100)
                textView.setContentOffset(CGPoint(
                    x: textView.contentOffset.x,
                    y: textView.contentSize.height - textView.bounds.height
                ), animated: false)
                try await Task.sleep(for: .milliseconds(40))
                try #require(textView.contentOffset.y > 100)
            }

            var captures: [ChatSendFlightCapture] = []
            let captureDeadline = ContinuousClock.now + .seconds(3)
            while captures.isEmpty, ContinuousClock.now < captureDeadline {
                captures = sources.capture(in: surface, ids: [sourceID])
                if captures.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            }
            let capture = try #require(captures.first)
            let departure = try #require(controller.departureBounds)
            #expect(departure.maxY <= outerFrame.minY + 0.5)
            #expect(departure.maxY <= contentFrame.minY + 0.5)
            #expect(capture.frame.maxY > departure.maxY + 1)

            if style != "card" {
                #expect(abs(outerFrame.height - 66) < 1)
                #expect(contentFrame.minY < outerFrame.minY - 80)
                #expect(editor.bounds.height > 100)
                if scenario == .expandedFirstLine {
                    // 首行本来就高于旧占位锚点，这一断言区分真实 overlay 与手工高度夹具。
                    #expect(capture.frame.maxY < outerFrame.minY)
                } else {
                    #expect(capture.contentVerticalPosition > 0.9)
                    #expect(capture.frame.height <= editor.bounds.height + 0.5)
                }
            } else {
                #expect(abs(contentFrame.minY - outerFrame.minY) < 1)
                #expect(contentFrame.height > editor.bounds.height)
            }

            let started = CACurrentMediaTime()
            controller.begin(
                id: UUID(), captures: captures, response: 0.2, damping: 1, backgrounds: [:], at: started,
                onMessagesPrepared: { _ in true }, onSourcesRetired: { _ in },
                onHandoff: { _, _ in true }, onCompletion: {}
            )
            let flying = try #require(capture.content.superview)
            // 中心与尺寸重组会产生浮点尾差，不能将其误判为起始位置跳变。
            #expect(abs(flying.frame.minX - capture.frame.minX) < 1e-6)
            #expect(abs(flying.frame.minY - capture.frame.minY) < 1e-6)
            #expect(abs(flying.frame.width - capture.frame.width) < 1e-6)
            #expect(abs(flying.frame.height - capture.frame.height) < 1e-6)
            // 尚无身份/落点时也必须已离开输入区；不调用发送、布局刷新或网络来推动此断言。
            controller.advance(at: started + 0.15)
            #expect(flying.frame.maxY < capture.frame.maxY - 1)
            controller.advance(at: started + 1.2)
            #expect(controller.isActive)
            #expect(abs(flying.frame.maxY - departure.maxY) < 0.5)
        } catch {
            await config.flushPendingWrites()
            throw error
        }
        await config.flushPendingWrites()
    }

    private func editor(in view: UIView, containing draft: String) -> UIView? {
        if let textView = view as? UITextView, textView.isEditable, textView.text == draft { return textView }
        if let textField = view as? UITextField, textField.text == draft { return textField }
        for child in view.subviews {
            if let editor = editor(in: child, containing: draft) { return editor }
        }
        return nil
    }
}

@MainActor
private struct ComposerHost: View {
    let controller: ChatSendFlightController
    let sources: ChatSendFlightSources
    let draft: String
    let startsExpanded: Bool
    var availableHeight: CGFloat = .infinity
    @FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .background(ChatSendFlightLayoutAnchor(controller: controller, region: .viewport))
            .safeAreaInset(edge: .bottom) {
                // 复用生产的占位与 overlay，不用 UIView 人为指定输入框高度。
                VStack(spacing: 0) {
                    TelegramMessageComposer(
                        sendFlightController: controller,
                        text: .constant(draft),
                        sendAction: { false }, stopAction: {},
                        focus: $focused,
                        availableHeight: availableHeight,
                        cflState: CFLComposerState(canSend: true, isSubmitting: false, isResponding: false),
                        isExpandedComposer: startsExpanded
                    )
                }
                .background(ChatSendFlightLayoutAnchor(controller: controller, region: .composer))
            }
            .environment(\.chatSendFlightSources, sources)
    }
}
