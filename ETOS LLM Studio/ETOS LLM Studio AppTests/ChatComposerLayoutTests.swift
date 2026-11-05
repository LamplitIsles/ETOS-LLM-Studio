import Testing
import UIKit
import SwiftUI
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("聊天输入框布局测试")
struct ChatComposerLayoutTests {
    @Test("输入框按实际换行增长，在上限内滚动")
    func growsWithTextAndRespectsHeightLimit() {
        let input = CFLComposerTextView.InputView()
        input.font = .systemFont(ofSize: 16)
        input.textContainer.lineFragmentPadding = 0
        let maximum: CGFloat = 130

        input.text = "一行"
        let oneLine = input.fittingHeight(width: 200, maximum: maximum)
        input.text = "一行\n两行"
        let twoLines = input.fittingHeight(width: 200, maximum: maximum)
        input.text = Array(repeating: "较长的一行文本", count: 30).joined(separator: "\n")
        let longText = input.fittingHeight(width: 200, maximum: maximum)

        #expect(oneLine == 44)
        #expect(twoLines > oneLine && twoLines < maximum)
        #expect(longText == maximum)
        #expect(input.isScrollEnabled)

        input.text = "一行"
        #expect(input.fittingHeight(width: 200, maximum: maximum) == oneLine)
    }

    @Test("按实际可用宽度换行")
    func measuresActualWidth() {
        let input = CFLComposerTextView.InputView()
        input.font = .systemFont(ofSize: 16)
        input.textContainer.lineFragmentPadding = 0
        input.text = String(repeating: "文字", count: 25)
        #expect(input.fittingHeight(width: 120, maximum: 300) > input.fittingHeight(width: 260, maximum: 300))
    }

    @Test("屏幕键盘换行设置不影响硬件换行或粘贴")
    func softwareReturnHonorsSetting() {
        var submissions = 0
        let composer = CFLComposerTextView(
            text: .constant("草稿"), focus: .constant(false), font: .systemFont(ofSize: 16),
            maximumHeight: 130, hardwareReturnSends: true, softwareReturnSends: true,
            onSubmit: { submissions += 1 }
        )
        let coordinator = composer.makeCoordinator()
        let input = CFLComposerTextView.InputView()
        let range = NSRange(location: 0, length: 0)

        #expect(!coordinator.textView(input, shouldChangeTextIn: range, replacementText: "\n"))
        #expect(submissions == 1)
        #expect(coordinator.textView(input, shouldChangeTextIn: range, replacementText: "第一行\n第二行"))
        #expect(submissions == 1)

        input.insertingHardwareNewline = true
        #expect(coordinator.textView(input, shouldChangeTextIn: range, replacementText: "\n"))
        input.insertingHardwareNewline = false

        coordinator.parent = CFLComposerTextView(
            text: .constant("草稿"), focus: .constant(false), font: .systemFont(ofSize: 16),
            maximumHeight: 130, hardwareReturnSends: true, softwareReturnSends: false,
            onSubmit: { submissions += 1 }
        )
        #expect(coordinator.textView(input, shouldChangeTextIn: range, replacementText: "\n"))
        #expect(submissions == 1)
    }
}
