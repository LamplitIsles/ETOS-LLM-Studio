// ============================================================================
// AudioMemoryModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义音频录制格式。
// ============================================================================

import Foundation

// MARK: - 音频录制格式

/// 音频录制格式枚举
public enum AudioRecordingFormat: String, CaseIterable, Codable, Sendable {
    case aac = "aac"
    case wav = "wav"

    /// 显示名称
    public var displayName: String {
        switch self {
        case .aac: return "AAC (M4A)"
        case .wav: return "WAV"
        }
    }

    /// 文件扩展名
    public var fileExtension: String {
        switch self {
        case .aac: return "m4a"
        case .wav: return "wav"
        }
    }

    /// MIME 类型
    public var mimeType: String {
        switch self {
        case .aac: return "audio/m4a"
        case .wav: return "audio/wav"
        }
    }

    /// 格式说明
    public var formatDescription: String {
        switch self {
        case .aac:
            return NSLocalizedString("AAC 压缩格式，文件小，兼容性好", comment: "AAC recording format description")
        case .wav:
            return NSLocalizedString("WAV 无压缩格式，音质最佳，文件较大", comment: "WAV recording format description")
        }
    }
}
