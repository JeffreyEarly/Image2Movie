import AppKit
import AVFoundation
import Combine

/// The one export entry point for the window, Shortcuts, and local automation.
@MainActor @objc(ExportCoordinator)
final class ExportCoordinator: NSObject, ObservableObject {
    @objc static let shared = ExportCoordinator()

    @Published private(set) var activeJob: ExportJob?
    @Published private(set) var recentJobs: [ExportJob] = []
    @objc var hasActiveExport: Bool { activeJob != nil }

    private weak var draftModel: ImagesToMovie?
    private weak var draftWindow: NSWindow?
    private var encoder: ImagesToMovie?
    private var accessLease: FileAccessLease?
    private var draftAccessLeases: [FileAccessLease] = []
    private var progressObservation: NSKeyValueObservation?
    private var waiters: [UUID: [CheckedContinuation<URL, Error>]] = [:]

    private override init() { super.init() }

    @objc(attachDraftModel:window:)
    func attachDraftModel(_ model: ImagesToMovie?, window: NSWindow?) {
        draftModel = model
        draftWindow = window
        if let model, let job = activeJob {
            model.minValue = 0
            model.maxValue = UInt(job.totalFrames)
            model.value = UInt(job.completedFrames)
            model.progressString = "\(job.completedFrames) of \(job.totalFrames)"
            model.movieCreationInProgress = true
        }
    }

    func job(id: UUID? = nil) -> ExportJob? {
        guard let id else { return activeJob ?? recentJobs.first }
        return activeJob?.id == id ? activeJob : recentJobs.first { $0.id == id }
    }

    func start(_ request: ExportRequest) throws -> UUID {
        try start(request, fromDraft: false)
    }

    private func start(_ request: ExportRequest, fromDraft: Bool) throws -> UUID {
        let editingDraft = (draftWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
        guard activeJob == nil, draftModel?.movieCreationInProgress != true,
              (fromDraft || (draftWindow?.attachedSheet == nil && !editingDraft)) else {
            throw ExportError.busy
        }
        // The lease must precede the renderer and outlive its final callback.
        let lease = try FileAccessManager.shared.acquire(reading: request.inputURLs,
                                                         writing: [request.outputURL])
        try validate(request)
        let model = ImagesToMovie()
        model.imagePaths = NSMutableArray(array: request.inputURLs.map(\.path))
        model.frameSize = NSSize(width: request.settings.width, height: request.settings.height)
        model.frameRate = UInt(request.settings.frameRate)
        model.codec = switch request.settings.codec {
        case .h264: AVVideoCodecType.h264
        case .hevc: AVVideoCodecType.hevc
        case .prores422: AVVideoCodecType(rawValue: "apcn")
        }
        model.qualityMode = switch request.settings.quality {
        case .standard: .standard
        case .high: .high
        case .custom: .customBitrate
        }
        if let bitrate = request.settings.customBitrateMbps {
            model.averageBitRate = UInt((bitrate * 1_000_000).rounded())
        }
        model.allowOverwrite = request.overwrite

        let id = UUID()
        activeJob = ExportJob(id: id, state: .running, progress: 0, completedFrames: 0,
                              totalFrames: request.inputURLs.count, settings: request.settings,
                              outputURL: request.outputURL, error: nil)
        encoder = model
        accessLease = lease
        draftModel?.minValue = 0
        draftModel?.maxValue = UInt(request.inputURLs.count)
        draftModel?.value = 0
        draftModel?.progressString = "0 of \(request.inputURLs.count)"
        draftModel?.movieCreationInProgress = true
        progressObservation = model.observe(\.value, options: [.new]) { [weak self] model, _ in
            let frames = Int(model.value)
            Task { @MainActor [weak self] in self?.updateProgress(id: id, frames: frames) }
        }
        model.createMovie(atPath: request.outputURL.path) { [weak self] error in
            // The Objective-C exporter completes on the main queue, after its writer and
            // temporary file have reached a terminal state.
            MainActor.assumeIsolated {
                self?.finish(id: id, error: error)
            }
        }
        return id
    }

    private func validate(_ request: ExportRequest) throws {
        guard !request.inputURLs.isEmpty else { throw ExportError.invalid("Choose at least one image.") }
        for (index, url) in request.inputURLs.enumerated() {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.isEmpty else {
                throw ExportError.invalid("Image \(index + 1) needs an absolute file URL.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ExportError.invalid("Image \(index + 1) does not exist: \(url.path)")
            }
        }
        guard request.outputURL.isFileURL, request.outputURL.path.hasPrefix("/") else {
            throw ExportError.invalid("Choose an absolute movie destination.")
        }
        let s = request.settings
        guard (1...3840).contains(s.width), (1...2160).contains(s.height),
              (1...30).contains(s.frameRate) else {
            throw ExportError.invalid("Movie dimensions must be at most 3840 × 2160 and frame rate 1–30 fps.")
        }
        guard s.codec != .prores422 || s.quality != .custom else {
            throw ExportError.invalid("ProRes 422 does not use a custom bit rate.")
        }
        if s.quality == .custom {
            guard let bitrate = s.customBitrateMbps, bitrate.isFinite, (0.1...50).contains(bitrate) else {
                throw ExportError.invalid("Custom bit rate must be 0.1–50 Mbps.")
            }
        } else if s.customBitrateMbps != nil {
            throw ExportError.invalid("A custom bit rate requires Custom quality.")
        }
        let requiredExtension = s.codec == .prores422 ? "mov" : "mp4"
        guard request.outputURL.pathExtension.lowercased() == requiredExtension else {
            throw ExportError.invalid("\(s.codec.rawValue) movies need a .\(requiredExtension) destination.")
        }
        var isDirectory: ObjCBool = false
        let parent = request.outputURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExportError.invalid("The destination folder does not exist.")
        }
        if !request.overwrite && FileManager.default.fileExists(atPath: request.outputURL.path) {
            throw ExportError.invalid("The destination already exists. Choose a different name or allow overwrite.")
        }
    }

    private func updateProgress(id: UUID, frames: Int) {
        guard var job = activeJob, job.id == id else { return }
        job.completedFrames = min(max(frames, 0), job.totalFrames)
        job.progress = Double(job.completedFrames) / Double(job.totalFrames)
        activeJob = job
        draftModel?.value = UInt(job.completedFrames)
        draftModel?.progressString = "\(job.completedFrames) of \(job.totalFrames)"
    }

    private func finish(id: UUID, error: Error?) {
        guard var job = activeJob, job.id == id else { return }
        progressObservation = nil
        if let error {
            let nsError = error as NSError
            job.state = nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
                ? .cancelled : .failed
            job.error = error.localizedDescription
        } else {
            job.state = .completed
            job.completedFrames = job.totalFrames
            job.progress = 1
        }
        recentJobs.insert(job, at: 0)
        if recentJobs.count > 20 { recentJobs.removeLast() }
        activeJob = nil
        draftModel?.value = UInt(job.completedFrames)
        draftModel?.movieCreationInProgress = false
        encoder = nil
        accessLease = nil
        draftAccessLeases = []
        let continuations = waiters.removeValue(forKey: id) ?? []
        for continuation in continuations {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: job.outputURL) }
        }
    }

    func cancel(id: UUID? = nil) throws {
        guard let activeJob, id == nil || activeJob.id == id else { throw ExportError.unknownJob }
        encoder?.cancel()
    }

    @objc func cancelActiveExport() { try? cancel() }

    @objc(prepareForTerminationWithCompletion:)
    func prepareForTermination(completion: @escaping () -> Void) {
        guard let id = activeJob?.id else { completion(); return }
        try? cancel(id: id)
        Task { @MainActor in
            _ = try? await wait(for: id)
            completion()
        }
    }

    func wait(for id: UUID) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let job = job(id: id), job.state.isTerminal {
                switch job.state {
                case .completed: return job.outputURL
                case .cancelled: throw ExportError.cancelled
                case .failed: throw ExportError.invalid(job.error ?? "The movie export failed.")
                case .running: break
                }
            }
            guard activeJob?.id == id else { throw ExportError.unknownJob }
            return try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: []].append(continuation)
            }
        } onCancel: {
            Task { @MainActor in try? self.cancel(id: id) }
        }
    }

    /// Captures the existing GUI draft after its controls commit their values.
    @objc(exportDraftTo:retainingLeases:completion:)
    func exportDraft(to outputURL: URL, retainingLeases: [FileAccessLease], completion: @escaping (NSError?) -> Void) {
        guard let draftModel else {
            completion(ExportError.invalid("The movie window is unavailable.") as NSError)
            return
        }
        let codec: ExportCodec = switch draftModel.codec {
        case AVVideoCodecType.h264: .h264
        case AVVideoCodecType(rawValue: "apcn"): .prores422
        default: .hevc
        }
        let quality: ExportQuality = switch draftModel.qualityMode {
        case .standard: .standard
        case .customBitrate: .custom
        default: .high
        }
        let settings = ExportSettings(width: Int(draftModel.frameSize.width),
                                      height: Int(draftModel.frameSize.height),
                                      frameRate: Int(draftModel.frameRate), codec: codec,
                                      quality: codec == .prores422 ? .high : quality,
                                      customBitrateMbps: quality == .custom && codec != .prores422
                                        ? Double(draftModel.averageBitRate) / 1_000_000 : nil)
        let request = ExportRequest(inputURLs: draftModel.imagePaths.compactMap {
            guard let path = $0 as? String else { return nil }
            return URL(fileURLWithPath: path)
        }, outputURL: outputURL, settings: settings, overwrite: true)
        do {
            let id = try start(request, fromDraft: true)
            draftAccessLeases = retainingLeases
            Task { @MainActor in
                do { _ = try await wait(for: id); completion(nil) }
                catch { completion(error as NSError) }
            }
        } catch {
            completion(error as NSError)
        }
    }
}
