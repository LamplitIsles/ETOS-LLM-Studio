// ============================================================================
// ChatServiceVideoAnalysis.swift
// ============================================================================
// ETOS LLM Studio
//
// 保留历史消息的视频解析结果访问。
// ============================================================================

import Foundation

public extension ChatMessage {
    func videoAnalysisResult(for fileName: String) -> VideoAnalysisResult? {
        videoAnalysisResults?.first { $0.fileName == fileName }
    }

    mutating func replaceVideoAnalysisResult(_ result: VideoAnalysisResult) {
        var results = videoAnalysisResults ?? []
        results.removeAll { $0.fileName == result.fileName }
        results.append(result)
        videoAnalysisResults = results
    }
}
