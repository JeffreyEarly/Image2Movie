import AppKit
import AVFoundation

@MainActor @objc(AutomationRegression)
final class AutomationRegression: NSObject {
    @objc(runInDirectory:completion:)
    static func run(inDirectory directory: URL, completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            do {
                try runFileAccessRegression(inDirectory: directory)
                try await exerciseCoordinator(in: directory)
                try runMCPSettingsRegression()
                try await runMCPRegression(inDirectory: directory)
                completion(nil)
            } catch {
                completion(error as NSError)
            }
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ExportError.invalid("Automation regression: \(message)") }
    }

    private static func exerciseCoordinator(in directory: URL) async throws {
        let first = directory.appendingPathComponent("frame-00.png")
        let second = directory.appendingPathComponent("frame-01.png")
        let settings = ExportSettings(width: 320, height: 180)
        try check(settings.frameRate == 30 && settings.codec == .hevc && settings.quality == .high,
                  "automation defaults changed")

        let coordinator = ExportCoordinator.shared
        let originalHistory = coordinator.recentJobs.count
        let draft = ImagesToMovie()
        draft.imagePaths = NSMutableArray(array: ["draft-original.png"])
        draft.frameSize = NSSize(width: 640, height: 480)
        draft.frameRate = 24
        draft.codec = .h264
        coordinator.attachDraftModel(draft, window: nil)
        defer { coordinator.attachDraftModel(nil, window: nil) }

        let invalid = ExportRequest(inputURLs: [first],
                                    outputURL: directory.appendingPathComponent("automation-invalid.mp4"),
                                    settings: ExportSettings(width: 0, height: 180))
        var rejected = false
        do { _ = try coordinator.start(invalid) }
        catch ExportError.invalid { rejected = true }
        try check(rejected, "invalid dimensions were accepted")
        try check(coordinator.activeJob == nil, "invalid request started a job")

        let orderedOutput = directory.appendingPathComponent("automation-ordered.mp4")
        let ordered = ExportRequest(inputURLs: [first, second, first], outputURL: orderedOutput,
                                    settings: ExportSettings(width: 320, height: 180, codec: .h264))
        let orderedID = try coordinator.start(ordered)
        try check(coordinator.activeJob?.id == orderedID && coordinator.activeJob?.totalFrames == 3,
                  "ordered duplicate images were collapsed")
        try check(draft.movieCreationInProgress, "interactive controls were not locked")
        do {
            _ = try coordinator.start(ordered)
            throw ExportError.invalid("A concurrent job was accepted.")
        } catch ExportError.busy { /* expected */ }
        let result = try await coordinator.wait(for: orderedID)
        try check(result == orderedOutput && coordinator.job(id: orderedID)?.state == .completed,
                  "completed job was not recorded")
        try check(coordinator.job(id: orderedID)?.progress == 1 && !draft.movieCreationInProgress,
                  "terminal progress did not unlock the draft")
        let asset = AVURLAsset(url: result)
        let duration = try await asset.load(.duration)
        try check(abs(CMTimeGetSeconds(duration) - 3.0 / 30.0) < 0.002,
                  "duplicate image did not produce a third frame")
        let colors = try (0..<3).map { try frameColor(in: asset, frame: $0) }
        try check(colors == [.red, .green, .red],
                  "movie frames did not preserve supplied order and duplicates")

        rejected = false
        do { _ = try coordinator.start(ordered) }
        catch ExportError.invalid { rejected = true }
        try check(rejected, "an existing movie was overwritten without permission")

        let cancelledOutput = directory.appendingPathComponent("automation-cancelled.mp4")
        let cancelRequest = ExportRequest(inputURLs: Array(repeating: first, count: 100),
                                          outputURL: cancelledOutput,
                                          settings: ExportSettings(width: 320, height: 180, codec: .h264))
        let cancelledID = try coordinator.start(cancelRequest)
        try coordinator.cancel(id: cancelledID)
        _ = try? await coordinator.wait(for: cancelledID)
        try check(coordinator.job(id: cancelledID)?.state == .cancelled &&
                  !FileManager.default.fileExists(atPath: cancelledOutput.path),
                  "cancellation left a published movie or nonterminal job")

        let retryOutput = directory.appendingPathComponent("automation-retry.mp4")
        let retryID = try coordinator.start(ExportRequest(inputURLs: [second], outputURL: retryOutput,
                                                          settings: ExportSettings(width: 320, height: 180,
                                                                                   codec: .h264)))
        _ = try await coordinator.wait(for: retryID)
        try check(coordinator.job(id: retryID)?.state == .completed && coordinator.activeJob == nil,
                  "immediate retry failed")
        try check(coordinator.recentJobs.count == originalHistory + 3 &&
                  coordinator.recentJobs.map(\.id).prefix(3).elementsEqual([retryID, cancelledID, orderedID]),
                  "recent job history is missing a terminal result")
        try check(draft.imagePaths as? [String] == ["draft-original.png"] &&
                  draft.frameSize == NSSize(width: 640, height: 480) && draft.frameRate == 24 &&
                  draft.codec == .h264, "automation changed the interactive draft")

        let historyStart = coordinator.recentJobs.count
        var burstIDs: [UUID] = []
        for index in 0..<21 {
            let output = directory.appendingPathComponent("automation-history-\(index).mp4")
            let id = try coordinator.start(ExportRequest(
                inputURLs: [first], outputURL: output,
                settings: ExportSettings(width: 320, height: 180, codec: .h264)))
            burstIDs.append(id)
            _ = try await coordinator.wait(for: id)
        }
        try check(coordinator.recentJobs.count == 20,
                  "completed job history did not retain exactly 20 jobs")
        try check(coordinator.recentJobs.first?.id == burstIDs.last &&
                  !coordinator.recentJobs.contains(where: { $0.id == burstIDs.first }),
                  "completed job history did not retain the latest 20 jobs")
        try check(coordinator.recentJobs.count == min(20, historyStart + 21),
                  "completed job history count changed unexpectedly")

        let corruptInput = directory.appendingPathComponent("automation-corrupt.png")
        try Data("not a PNG image".utf8).write(to: corruptInput)
        let failedOutput = directory.appendingPathComponent("automation-corrupt.mp4")
        let failedID = try coordinator.start(ExportRequest(
            inputURLs: [corruptInput], outputURL: failedOutput,
            settings: ExportSettings(width: 320, height: 180, codec: .h264)))
        var failureObserved = false
        do { _ = try await coordinator.wait(for: failedID) }
        catch { failureObserved = true }
        try check(failureObserved && coordinator.job(id: failedID)?.state == .failed,
                  "corrupt input did not produce a terminal failed job")
        try check(coordinator.job(id: failedID)?.error?.contains(corruptInput.lastPathComponent) == true,
                  "failed job did not retain the input filename")
        try check(!FileManager.default.fileExists(atPath: failedOutput.path),
                  "failed export published a destination")

        let waiterOutput = directory.appendingPathComponent("automation-waiters.mp4")
        let waiterID = try coordinator.start(ExportRequest(
            inputURLs: [second], outputURL: waiterOutput,
            settings: ExportSettings(width: 320, height: 180, codec: .h264)))
        async let firstWaiter = coordinator.wait(for: waiterID)
        async let secondWaiter = coordinator.wait(for: waiterID)
        let (firstResult, secondResult) = try await (firstWaiter, secondWaiter)
        try check(firstResult == waiterOutput && secondResult == waiterOutput,
                  "concurrent waiters did not receive the same completed result")
    }

    private enum FrameColor { case red, green, other }

    private static func frameColor(in asset: AVAsset, frame: Int) throws -> FrameColor {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(value: Int64(frame), timescale: 30), actualTime: nil)
        guard let color = NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?
            .usingColorSpace(.deviceRGB) else { return .other }
        return color.redComponent > color.greenComponent * 1.5 ? .red :
            color.greenComponent > color.redComponent * 1.5 ? .green : .other
    }
}
