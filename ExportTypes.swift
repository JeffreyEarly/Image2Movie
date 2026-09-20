import Foundation

enum ExportCodec: String, Codable, Sendable, CaseIterable {
    case h264, hevc, prores422
}

enum ExportQuality: String, Codable, Sendable, CaseIterable {
    case standard, high, custom
}

struct ExportSettings: Codable, Sendable {
    let width: Int
    let height: Int
    let frameRate: Int
    let codec: ExportCodec
    let quality: ExportQuality
    let customBitrateMbps: Double?

    init(width: Int, height: Int, frameRate: Int = 30, codec: ExportCodec = .hevc,
         quality: ExportQuality = .high, customBitrateMbps: Double? = nil) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.quality = quality
        self.customBitrateMbps = customBitrateMbps
    }
}

struct ExportRequest: Sendable {
    let inputURLs: [URL]
    let outputURL: URL
    let settings: ExportSettings
    let overwrite: Bool

    init(inputURLs: [URL], outputURL: URL, settings: ExportSettings, overwrite: Bool = false) {
        self.inputURLs = inputURLs
        self.outputURL = outputURL
        self.settings = settings
        self.overwrite = overwrite
    }
}

enum ExportJobState: String, Codable, Sendable {
    case running, completed, failed, cancelled

    var isTerminal: Bool { self != .running }
}

struct ExportJob: Codable, Sendable {
    let id: UUID
    var state: ExportJobState
    var progress: Double
    var completedFrames: Int
    let totalFrames: Int
    let settings: ExportSettings
    let outputURL: URL
    var error: String?
}

enum ExportError: LocalizedError {
    case busy
    case invalid(String)
    case unknownJob
    case cancelled

    var errorDescription: String? {
        switch self {
        case .busy: "A movie export is in progress, or the movie window has an open sheet or uncommitted edit."
        case .invalid(let message): message
        case .unknownJob: "That export job is no longer available."
        case .cancelled: "The movie export was cancelled."
        }
    }
}
