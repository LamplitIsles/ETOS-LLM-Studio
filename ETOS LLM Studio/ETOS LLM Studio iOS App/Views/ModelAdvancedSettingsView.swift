// ============================================================================
// ModelAdvancedSettingsView.swift
// ============================================================================
// ModelAdvancedSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import UIKit
import ETOSCore

enum ModelAdvancedSettingsDestination: Hashable {
    case conversation
    case output

    var title: String {
        switch self {
        case .conversation:
            return NSLocalizedString("会话", comment: "Core conversation settings title")
        case .output:
            return NSLocalizedString("输出", comment: "Core output settings title")
        }
    }
}

struct ModelAdvancedSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var editingMessageRegexRule: MessageRegexRule?
    @State private var isShowingSessionContextIntro = false
    @State private var isShowingGenerationOutputIntro = false

    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
    @Binding var aiTemperatureEnabled: Bool
    @Binding var aiTopPEnabled: Bool
    @Binding var maxChatHistory: Int
    @Binding var lazyLoadMessageCount: Int
    @Binding var enableStreaming: Bool
    @Binding var enableResponseSpeedMetrics: Bool
    @Binding var enableOpenAIStreamIncludeUsage: Bool
    @Binding var enableAutoSessionNaming: Bool
    @Binding var enableReasoningSummary: Bool
    @Binding var currentSession: ChatSession?
    @Binding var includeSystemTimeInPrompt: Bool
    @Binding var systemTimeInjectionPosition: SystemTimeInjectionPosition
    @Binding var enablePeriodicTimeLandmark: Bool
    @Binding var periodicTimeLandmarkIntervalMinutes: Int

    let destination: ModelAdvancedSettingsDestination

    private let samplingParameterStep = 0.01
    private let temperatureRange = 0.0...2.0
    private let topPRange = 0.0...1.0

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var sendDelayFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        return formatter
    }

    var body: some View {
        modelObservationView
            .guideSettingsPageContext(
                id: guidePageID,
                title: destination.title,
                documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings")],
                settings: guideSettings
            )
    }

    private var guidePageID: GuidePageID {
        switch destination {
        case .conversation: return "settings-conversation"
        case .output: return "settings-output"
        }
    }

    private var guideSettings: [GuidePageSetting] {
        switch destination {
        case .conversation:
            return conversationGuideSettings
        case .output:
            return outputGuideSettings
        }
    }

    private var conversationGuideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .bool("auto_session_naming", label: NSLocalizedString("自动生成话题标题", comment: "向导设置字段"), get: { enableAutoSessionNaming }, set: { enableAutoSessionNaming = $0 }),
            .double("send_delay_seconds", label: NSLocalizedString("延迟发送秒数", comment: "向导设置字段"), range: 0...3_600, get: { normalizedSendDelay(appConfig.chatSendDelaySeconds) }, set: { appConfig.chatSendDelaySeconds = normalizedSendDelay($0) }),
            .integer("automatic_execution_budget", label: NSLocalizedString("自动执行预算", comment: "向导设置字段"), range: 1...10_000, get: { max(1, appConfig.conversationRuntimeExecutionBudget) }, set: { appConfig.conversationRuntimeExecutionBudget = max(1, $0) }),
            .integer("max_context_messages", label: NSLocalizedString("最大上下文消息数", comment: "向导设置字段"), range: 1...100_000, get: { maxChatHistory }, set: { maxChatHistory = $0 }),
            .bool("automatic_history_loading", label: NSLocalizedString("自动管理历史消息", comment: "向导设置字段"), get: { viewModel.automaticHistoryLoadingEnabled }, set: { viewModel.automaticHistoryLoadingEnabled = $0 }),
            .bool("use_video_analysis_model", label: NSLocalizedString("非原生视频使用解析模型", comment: "向导设置字段"), get: { appConfig.enableVideoAnalysisForNonNativeModels }, set: { appConfig.enableVideoAnalysisForNonNativeModels = $0 }),
            .string("video_analysis_model", label: NSLocalizedString("视频解析模型", comment: "向导设置字段"), allowedValues: viewModel.videoAnalysisModelOptions.map(\.id), get: { appConfig.videoAnalysisModelIdentifier }, set: { setVideoAnalysisModelIdentifier($0) }),
            .string("video_frame_mode", label: NSLocalizedString("视频处理方式", comment: "向导设置字段"), allowedValues: VideoFrameExtractionMode.allCases.map(\.rawValue), get: { VideoFrameExtractionMode.normalized(appConfig.videoFrameExtractionMode).rawValue }, set: { appConfig.videoFrameExtractionMode = $0 }),
            .double("video_frame_fps", label: NSLocalizedString("视频抽帧速率", comment: "向导设置字段"), range: 0.1...5, get: { videoFrameExtractionFPSBinding.wrappedValue }, set: { videoFrameExtractionFPSBinding.wrappedValue = $0 }),
            .integer("video_frame_maximum_count", label: NSLocalizedString("最多画面数", comment: "向导设置字段"), range: 4...120, get: { videoFrameMaximumCountBinding.wrappedValue }, set: { videoFrameMaximumCountBinding.wrappedValue = $0 })
        ]
        if !viewModel.automaticHistoryLoadingEnabled {
            settings.append(.integer("initial_visible_messages", label: NSLocalizedString("初始显示消息数", comment: "向导设置字段"), range: 1...100_000, get: { lazyLoadMessageCount }, set: { lazyLoadMessageCount = $0 }))
        }
        return settings
    }

    private var outputGuideSettings: [GuidePageSetting] {
        [
            .bool("temperature_enabled", label: NSLocalizedString("自定义 Temperature", comment: "向导设置字段"), get: { aiTemperatureEnabled }, set: { aiTemperatureEnabled = $0 }),
            .double("temperature", label: NSLocalizedString("Temperature", comment: "向导设置字段"), range: temperatureRange, get: { temperatureBinding.wrappedValue }, set: { temperatureBinding.wrappedValue = $0 }),
            .bool("top_p_enabled", label: NSLocalizedString("自定义 Top P", comment: "向导设置字段"), get: { aiTopPEnabled }, set: { aiTopPEnabled = $0 }),
            .double("top_p", label: NSLocalizedString("Top P", comment: "向导设置字段"), range: topPRange, get: { topPBinding.wrappedValue }, set: { topPBinding.wrappedValue = $0 }),
            .bool("streaming_enabled", label: NSLocalizedString("启用流式输出", comment: "向导设置字段"), get: { enableStreaming }, set: { enableStreaming = $0 }),
            .bool("stream_include_usage", label: NSLocalizedString("流式附带官方 Token 用量", comment: "向导设置字段"), get: { enableOpenAIStreamIncludeUsage }, set: { enableOpenAIStreamIncludeUsage = $0 }),
            .bool("reasoning_summary", label: NSLocalizedString("启用思考摘要", comment: "向导设置字段"), get: { enableReasoningSummary }, set: { enableReasoningSummary = $0 }),
            .string("reasoning_content_echo_mode", label: NSLocalizedString("思维链回传", comment: "向导设置字段"), allowedValues: ReasoningContentEchoMode.allCases.map(\.rawValue), get: { ReasoningContentEchoMode.normalized(appConfig.reasoningContentEchoMode).rawValue }, set: { appConfig.reasoningContentEchoMode = $0 }),
            .bool("response_speed_metrics", label: NSLocalizedString("启用响应测速", comment: "向导设置字段"), get: { enableResponseSpeedMetrics }, set: { enableResponseSpeedMetrics = $0 })
        ]
    }

    private var configuredView: some View {
        settingsContent
            .navigationTitle(destination.title)
            .onAppear(perform: handleAppear)
    }

    private var modelObservationView: some View {
        configuredView
            .onChange(of: appConfig.enableVideoAnalysisForNonNativeModels) { _, isEnabled in
                if isEnabled {
                    syncVideoAnalysisModelSelection()
                }
            }
            .onChange(of: viewModel.activatedModelListVersion) { _, _ in
                syncVideoAnalysisModelSelection()
            }
    }

    private func handleAppear() {
        normalizeSamplingParametersIfNeeded()
        syncVideoAnalysisModelSelection()
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch destination {
        case .conversation:
            conversationSettingsContent
        case .output:
            outputSettingsContent
        }
    }

    private var conversationSettingsContent: some View {
        Form {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("会话", comment: "Core conversation settings title"),
                    summary: sessionContextIntroSummary,
                    details: sessionContextIntroDetails,
                    isExpanded: $isShowingSessionContextIntro
                )
            }

            Section {
                NavigationLink {
                    SessionListView().environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("会话管理", comment: ""), systemImage: "clock")
                }
            }

            Section {
                Toggle(NSLocalizedString("自动生成话题标题", comment: ""), isOn: $enableAutoSessionNaming)
                LabeledContent(NSLocalizedString("延迟发送（秒）", comment: "Send delay seconds setting title")) {
                    TextField(NSLocalizedString("秒", comment: "Seconds placeholder"), value: sendDelayBinding, formatter: sendDelayFormatter)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 80)
                }
            } header: {
                Text(NSLocalizedString("启动与发送", comment: "Conversation launch and send settings section"))
            }

            Section {
                LabeledContent(NSLocalizedString("自动执行预算", comment: "Conversation runtime execution budget")) {
                    TextField(
                        NSLocalizedString("数量", comment: ""),
                        value: conversationRuntimeBudgetBinding,
                        formatter: numberFormatter
                    )
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 80)
                }
            } header: {
                Text(NSLocalizedString("会话协作", comment: "Conversation collaboration settings"))
            } footer: {
                Text(NSLocalizedString("自动执行预算由同一根协作链共享，耗尽后可从会话列表继续。", comment: "Conversation runtime settings explanation"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("上下文窗口管理", comment: "")) {
                LabeledContent(NSLocalizedString("最大上下文消息数", comment: "")) {
                    TextField(NSLocalizedString("数量", comment: ""), value: $maxChatHistory, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }

                Toggle(
                    NSLocalizedString("自动管理历史消息", comment: "自动管理聊天历史窗口设置"),
                    isOn: $viewModel.automaticHistoryLoadingEnabled
                )

                if !viewModel.automaticHistoryLoadingEnabled {
                    LabeledContent(NSLocalizedString("初始显示消息数", comment: "手动模式初始显示聊天消息数设置")) {
                        TextField(NSLocalizedString("数量", comment: ""), value: $lazyLoadMessageCount, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }


            }

            Section {
                NavigationLink {
                    MessageRegexRulesView(editingRule: $editingMessageRegexRule)
                } label: {
                    Label(NSLocalizedString("正则替换", comment: ""), systemImage: "textformat")
                }
            } header: {
                Text(NSLocalizedString("消息规则", comment: ""))
            } footer: {
                Text(NSLocalizedString("规则会按列表顺序应用。保存替换会写入消息；仅发送只影响模型请求；仅显示只影响聊天气泡展示。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    NSLocalizedString("非原生视频使用解析模型", comment: "Use video analysis model toggle"),
                    isOn: $appConfig.enableVideoAnalysisForNonNativeModels
                )

                if appConfig.enableVideoAnalysisForNonNativeModels {
                    if viewModel.videoAnalysisModelOptions.isEmpty {
                        Text(NSLocalizedString("暂无支持原生视频输入的可用模型。", comment: "No video analysis model available"))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            NSLocalizedString("视频解析模型", comment: "Video analysis model picker"),
                            selection: videoAnalysisModelIdentifierBinding
                        ) {
                            ForEach(viewModel.videoAnalysisModelOptions) { model in
                                Text("\(model.model.displayName) | \(model.provider.name)")
                                    .tag(model.id)
                            }
                        }
                    }
                }

                Picker(
                    NSLocalizedString("视频处理方式", comment: "Video processing mode setting"),
                    selection: videoFrameExtractionModeBinding
                ) {
                    ForEach(VideoFrameExtractionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if videoFrameExtractionModeBinding.wrappedValue == .fixedFPS {
                    Stepper(value: videoFrameExtractionFPSBinding, in: 0.1...5, step: 0.1) {
                        LabeledContent(NSLocalizedString("抽帧速率", comment: "Video extraction FPS")) {
                            Text("\(videoFrameExtractionFPSBinding.wrappedValue, specifier: "%.1f") FPS")
                                .monospacedDigit()
                        }
                    }
                }

                LabeledContent(NSLocalizedString("最多画面数", comment: "Maximum extracted video frames")) {
                    TextField(
                        NSLocalizedString("数量", comment: "Maximum extracted video frames field placeholder"),
                        value: videoFrameMaximumCountBinding,
                        formatter: numberFormatter
                    )
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 60)
                }
            } header: {
                Text(NSLocalizedString("视频发送", comment: "Video sending settings section"))
            } footer: {
                Text(NSLocalizedString(
                    "开启后，非原生视频会先由所选模型解析并保存文字，再交给当前对话模型；关闭时继续使用抽帧方式。原生视频模型仍直接接收视频。",
                    comment: "Video sending settings explanation"
                ))
            }
        }
        .background { SettingsKeyboardDismissTapView() }
        .scrollDismissesKeyboard(.interactively)
    }

    private var conversationRuntimeBudgetBinding: Binding<Int> {
        Binding(
            get: { max(1, appConfig.conversationRuntimeExecutionBudget) },
            set: { appConfig.conversationRuntimeExecutionBudget = max(1, $0) }
        )
    }

    private var outputSettingsContent: some View {
        Form {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("输出", comment: "Core output settings title"),
                    summary: generationOutputIntroSummary,
                    details: generationOutputIntroDetails,
                    isExpanded: $isShowingGenerationOutputIntro
                )
            }

            Section(NSLocalizedString("采样参数", comment: "")) {
                Toggle(NSLocalizedString("自定义 Temperature", comment: ""), isOn: $aiTemperatureEnabled)
                if aiTemperatureEnabled {
                    Stepper(value: temperatureBinding, in: temperatureRange, step: samplingParameterStep) {
                        RequestBodySliderAnimatedValue(
                            text: temperatureDisplayText,
                            position: temperatureSliderPositionBinding.wrappedValue,
                            isNumeric: true
                        )
                        .monospacedDigit()
                    }

                    RequestBodyGradientSlider(
                        value: temperatureSliderPositionBinding,
                        palette: .temperature,
                        anchorCount: 3,
                        adjustmentStep: samplingParameterStep / (temperatureRange.upperBound - temperatureRange.lowerBound),
                        accessibilityLabel: NSLocalizedString("温度", comment: "Temperature sampling parameter title"),
                        accessibilityValue: temperatureDisplayText,
                        showsFlowingRainbow: false,
                        onEditingChanged: { _ in }
                    )
                    .sensoryFeedback(.selection, trigger: temperatureFeedbackAnchor)
                }

                Toggle(NSLocalizedString("自定义 Top P", comment: ""), isOn: $aiTopPEnabled)
                if aiTopPEnabled {
                    Stepper(value: topPBinding, in: topPRange, step: samplingParameterStep) {
                        Text(
                            String(
                                format: NSLocalizedString("核采样 (Top P): %.2f", comment: ""),
                                topPBinding.wrappedValue
                            )
                        )
                    }

                    Slider(value: topPBinding, in: topPRange, step: samplingParameterStep)
                }
            }

            Section {
                Toggle(NSLocalizedString("启用流式输出", comment: ""), isOn: $enableStreaming)
                Toggle(NSLocalizedString("流式附带官方 Token 用量", comment: "Enable stream include usage in OpenAI-compatible requests"), isOn: $enableOpenAIStreamIncludeUsage)
            } header: {
                Text(NSLocalizedString("流式输出", comment: ""))
            }


            Section {
                Toggle(NSLocalizedString("启用思考摘要", comment: ""), isOn: $enableReasoningSummary)
                Picker(NSLocalizedString("思维链回传", comment: ""), selection: reasoningContentEchoModeBinding) {
                    ForEach(ReasoningContentEchoMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text(NSLocalizedString("思考与推理", comment: "Output reasoning settings section"))
            } footer: {
                Text(compactOutputReasoningFooterText)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(NSLocalizedString("启用响应测速", comment: "Enable response speed metrics"), isOn: $enableResponseSpeedMetrics)
            } header: {
                Text(NSLocalizedString("响应测速与统计", comment: "Response speed metrics section title"))
            }

            Section {
                NavigationLink {
                    TTSSettingsView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("语音朗读（TTS）", comment: ""), systemImage: "speaker.wave.2")
                }
            } header: {
                Text(NSLocalizedString("语音朗读", comment: "TTS output settings section"))
            }
        }
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { normalizedSamplingValue(aiTemperature, in: temperatureRange) },
            set: { handleTemperatureChange($0) }
        )
    }

    private var temperatureSliderPositionBinding: Binding<Double> {
        let span = temperatureRange.upperBound - temperatureRange.lowerBound
        return Binding(
            get: {
                (temperatureBinding.wrappedValue - temperatureRange.lowerBound) / span
            },
            set: { position in
                temperatureBinding.wrappedValue = temperatureRange.lowerBound
                    + min(max(position, 0), 1) * span
            }
        )
    }

    private var temperatureDisplayText: String {
        String(
            format: NSLocalizedString("模型温度 (Temperature): %.2f", comment: ""),
            temperatureBinding.wrappedValue
        )
    }

    private var temperatureFeedbackAnchor: Int {
        Int(temperatureSliderPositionBinding.wrappedValue * 2 + 0.000_001)
    }

    private var topPBinding: Binding<Double> {
        Binding(
            get: { normalizedSamplingValue(aiTopP, in: topPRange) },
            set: { handleTopPChange($0) }
        )
    }

    private var reasoningContentEchoModeBinding: Binding<ReasoningContentEchoMode> {
        Binding(
            get: { ReasoningContentEchoMode.normalized(appConfig.reasoningContentEchoMode) },
            set: { appConfig.reasoningContentEchoMode = $0.rawValue }
        )
    }

    private var sendDelayBinding: Binding<Double> {
        Binding(
            get: { normalizedSendDelay(appConfig.chatSendDelaySeconds) },
            set: { appConfig.chatSendDelaySeconds = normalizedSendDelay($0) }
        )
    }

    private var videoFrameExtractionModeBinding: Binding<VideoFrameExtractionMode> {
        Binding(
            get: { VideoFrameExtractionMode.normalized(appConfig.videoFrameExtractionMode) },
            set: { appConfig.videoFrameExtractionMode = $0.rawValue }
        )
    }

    private var videoFrameExtractionFPSBinding: Binding<Double> {
        Binding(
            get: { min(max(appConfig.videoFrameExtractionFPS, 0.1), 5) },
            set: { appConfig.videoFrameExtractionFPS = min(max($0, 0.1), 5) }
        )
    }

    private var videoFrameMaximumCountBinding: Binding<Int> {
        Binding(
            get: { min(max(appConfig.videoFrameMaximumCount, 4), 120) },
            set: { appConfig.videoFrameMaximumCount = min(max($0, 4), 120) }
        )
    }

    private var videoAnalysisModelIdentifierBinding: Binding<String> {
        Binding(
            get: { appConfig.videoAnalysisModelIdentifier },
            set: { setVideoAnalysisModelIdentifier($0) }
        )
    }

    private func syncVideoAnalysisModelSelection() {
        let options = viewModel.videoAnalysisModelOptions
        guard !options.isEmpty else {
            if !appConfig.videoAnalysisModelIdentifier.isEmpty {
                setVideoAnalysisModelIdentifier("")
            }
            return
        }
        guard !options.contains(where: { $0.id == appConfig.videoAnalysisModelIdentifier }) else {
            return
        }
        setVideoAnalysisModelIdentifier(options[0].id)
    }

    private func setVideoAnalysisModelIdentifier(_ identifier: String) {
        AppConfigStore.persistSynchronously(.text(identifier), for: .videoAnalysisModelIdentifier)
        appConfig.videoAnalysisModelIdentifier = identifier
    }

    private var sessionContextIntroSummary: String {
        NSLocalizedString("会话设置简介", comment: "说明会话、发送和历史消息设置的用途")
    }

    private var sessionContextIntroDetails: String {
        introDetails([
            (
                NSLocalizedString("延迟发送（秒）", comment: "Send delay seconds setting title"),
                NSLocalizedString("设置为 0 时立即发送；大于 0 时，点击发送后会等待对应秒数，期间可点停止取消。", comment: "Send delay setting footer")
            ),
            (
                NSLocalizedString("自动管理历史消息", comment: "自动管理聊天历史窗口设置"),
                NSLocalizedString("开启后会在接近边缘时自动加载并回收历史气泡。关闭后按设置显示最近消息，每次向上加载 5 条；回到底部时恢复初始范围。设为 0 时显示全部历史。", comment: "自动管理聊天历史窗口说明")
            ),
            (
                NSLocalizedString("消息规则", comment: ""),
                NSLocalizedString("规则会按列表顺序应用。保存替换会写入消息；仅发送只影响模型请求；仅显示只影响聊天气泡展示。", comment: "")
            ),
            (
                NSLocalizedString("视频发送", comment: "Video sending settings section"),
                NSLocalizedString("在 Gemini 模型的输入模态中启用“视频”后，应用会通过 Gemini Files API 发送原视频；关闭该模态或切换到其他模型时，会从保留的原视频按智能抽帧或固定 FPS 生成带时间戳的画面。智能抽帧会优先保留场景变化，并去除黑帧和近似重复帧。", comment: "Video sending settings detailed explanation")
            )
        ])
    }

    private var generationOutputIntroSummary: String {
        NSLocalizedString("回复设置简介", comment: "说明回复风格、流式显示与朗读的用途")
    }

    private var generationOutputIntroDetails: String {
        introDetails([
            (
                NSLocalizedString("输出", comment: "回复设置使用说明标题"),
                NSLocalizedString("回复设置使用说明", comment: "采样、流式输出与朗读的使用方法")
            ),
            (
                NSLocalizedString("思考与推理", comment: "Output reasoning settings section"),
                outputReasoningDetailsText
            ),
            (
                NSLocalizedString("响应测速与统计", comment: "Response speed metrics section title"),
                "\(NSLocalizedString("开启后会记录单次 API 请求的总回复时间；流式时还会记录首字时间和 token/s。", comment: "Response speed metrics description"))\n\n\(NSLocalizedString("“流式附带官方 Token 用量”会在 OpenAI 兼容流式请求中发送 stream_options.include_usage=true，部分平台若不兼容可关闭。", comment: "OpenAI stream include usage description"))"
            )
        ])
    }

    private var compactOutputReasoningFooterText: String {
        let base = NSLocalizedString("开启思考摘要后会在思考完成后异步生成一行摘要，并显示在思考耗时后面。", comment: "")
        if reasoningContentEchoModeBinding.wrappedValue == .never {
            return "\(base)\n\n\(NSLocalizedString("选择“不回传”后，某些要求回传 reasoning_content 或思考签名元数据的 API 可能会返回 400 错误。", comment: ""))"
        }
        return base
    }

    private var outputReasoningDetailsText: String {
        let base = NSLocalizedString("开启思考摘要后会在思考完成后异步生成一行摘要，并显示在思考耗时后面。", comment: "")
        let compatibility = NSLocalizedString("该设置会控制 OpenAI 兼容请求中的 reasoning_content、Gemini 工具调用的 thoughtSignature，以及 Anthropic 工具调用历史中的 thinking/redacted_thinking 块回传。Gemini 与 Anthropic 官方要求工具调用延续时保留这些签名元数据；非工具调用的完整原始思考块当前无法可靠重建，因此不会额外伪造回传。", comment: "")
        if reasoningContentEchoModeBinding.wrappedValue == .never {
            let warning = NSLocalizedString("选择“不回传”后，某些要求回传 reasoning_content 或思考签名元数据的 API 可能会返回 400 错误。", comment: "")
            return "\(base)\n\n\(compatibility)\n\n\(warning)"
        }
        return "\(base)\n\n\(compatibility)"
    }

    private func introDetails(_ sections: [(String, String)]) -> String {
        sections
            .map { "\($0.0)\n\($0.1)" }
            .joined(separator: "\n\n")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .etFont(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(summary)
                .etFont(.subheadline)
                .foregroundStyle(.primary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func handleTemperatureChange(_ value: Double) {
        let roundedValue = normalizedSamplingValue(value, in: temperatureRange)
        if aiTemperature != roundedValue {
            aiTemperature = roundedValue
        }
        unlockTemperatureBoundaryAchievementIfNeeded(roundedValue)
    }

    private func handleTopPChange(_ value: Double) {
        let roundedValue = normalizedSamplingValue(value, in: topPRange)
        if aiTopP != roundedValue {
            aiTopP = roundedValue
        }
    }

    private func normalizeSamplingParametersIfNeeded() {
        handleTemperatureChange(aiTemperature)
        handleTopPChange(aiTopP)
    }

    private func normalizedSamplingValue(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        return (clampedValue / samplingParameterStep).rounded() * samplingParameterStep
    }

    private func normalizedSendDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private func unlockTemperatureBoundaryAchievementIfNeeded(_ value: Double) {
        let achievementID: AchievementID?
        if value == 2.0 {
            achievementID = .wildTemperature
        } else if value == 0.0 {
            achievementID = .absoluteReason
        } else {
            achievementID = nil
        }

        guard let achievementID else { return }
        Task {
            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: achievementID)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: achievementID)
        }
    }


}

private struct SettingsKeyboardDismissTapView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async { [weak uiView, weak coordinator = context.coordinator] in
            coordinator?.attach(to: uiView?.window)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private lazy var tapGesture: UITapGestureRecognizer = {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            return gesture
        }()

        func attach(to newWindow: UIWindow?) {
            guard window !== newWindow else { return }
            detach()
            window = newWindow
            newWindow?.addGestureRecognizer(tapGesture)
        }

        func detach() {
            window?.removeGestureRecognizer(tapGesture)
            window = nil
        }

        @objc private func handleTap() {
            window?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView: UIView? = touch.view
            while let currentView = touchedView {
                if currentView is UITextField || currentView is UITextView {
                    return false
                }
                touchedView = currentView.superview
            }
            return true
        }
    }
}

// 设置页与模型选择器共用同一列表，保持切换、编辑和创建副本的行为一致。
