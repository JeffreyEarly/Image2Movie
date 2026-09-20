import AppIntents
import Foundation
import UniformTypeIdentifiers

extension ExportCodec: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie Codec")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .h264: "H.264", .hevc: "HEVC", .prores422: "ProRes 422"
    ]
}

extension ExportQuality: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie Quality")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .standard: "Standard", .high: "High", .custom: "Custom Bit Rate"
    ]
}

struct MovieFolderEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Authorized Movie Folder")
    static let defaultQuery = MovieFolderQuery()

    let id: String
    let name: String
    let writable: Bool
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ folder: AuthorizedFolder) {
        id = folder.id.uuidString
        name = folder.name
        writable = folder.writable
    }
}

struct MovieFolderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MovieFolderEntity] {
        await MainActor.run {
            FileAccessManager.shared.folders.filter { identifiers.contains($0.id.uuidString) }.map(MovieFolderEntity.init)
        }
    }

    func suggestedEntities() async throws -> [MovieFolderEntity] {
        await MainActor.run {
            FileAccessManager.shared.folders.filter(\.writable).map(MovieFolderEntity.init)
        }
    }
}

struct MovieJobEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie Export Job")
    static let defaultQuery = MovieJobQuery()

    let id: String
    @Property(title: "State") var state: String
    @Property(title: "Progress") var progress: Double
    @Property(title: "Frames Completed") var completedFrames: Int
    @Property(title: "Total Frames") var totalFrames: Int
    @Property(title: "Output") var outputURL: URL
    @Property(title: "Error") var error: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(outputURL.lastPathComponent)", subtitle: "\(state) · \(completedFrames)/\(totalFrames) frames")
    }

    init(_ job: ExportJob) {
        id = job.id.uuidString
        state = job.state.rawValue
        progress = job.progress
        completedFrames = job.completedFrames
        totalFrames = job.totalFrames
        outputURL = job.outputURL
        error = job.error
    }
}

struct MovieJobQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MovieJobEntity] {
        await MainActor.run {
            identifiers.compactMap { UUID(uuidString: $0) }
                .compactMap { ExportCoordinator.shared.job(id: $0) }.map(MovieJobEntity.init)
        }
    }

    func suggestedEntities() async throws -> [MovieJobEntity] {
        await MainActor.run {
            let coordinator = ExportCoordinator.shared
            return ([coordinator.activeJob].compactMap { $0 } + coordinator.recentJobs).map(MovieJobEntity.init)
        }
    }
}

struct ExportMovieIntent: LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Export Movie"
    static let description = IntentDescription("Create a movie from images in the supplied order.")
    static let supportedModes: IntentModes = [.background, .foreground(.deferred)]

    @Parameter(title: "Images") var images: [IntentFile]
    @Parameter(title: "Output Folder") var folder: MovieFolderEntity
    @Parameter(title: "Filename") var filename: String
    @Parameter(title: "Width") var width: Int
    @Parameter(title: "Height") var height: Int
    @Parameter(title: "Frame Rate", default: 30) var frameRate: Int
    @Parameter(title: "Codec", default: .hevc) var codec: ExportCodec
    @Parameter(title: "Quality", default: .high) var quality: ExportQuality
    @Parameter(title: "Custom Bit Rate (Mbps)") var customBitrateMbps: Double?
    @Parameter(title: "Overwrite Existing Movie", default: false) var overwrite: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$images) to \(\.$folder) as \(\.$filename)") {
            \.$width
            \.$height
            \.$frameRate
            \.$codec
            \.$quality
            \.$customBitrateMbps
            \.$overwrite
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let settings = ExportSettings(width: width, height: height, frameRate: frameRate,
                                      codec: codec, quality: quality,
                                      customBitrateMbps: customBitrateMbps)
        let fileURLs = try images.enumerated().map { index, file -> URL in
            guard let url = file.fileURL, url.isFileURL else {
                throw ExportError.invalid("Image \(index + 1) must be a file supplied to Shortcuts.")
            }
            return url
        }
        guard let folderID = UUID(uuidString: folder.id) else {
            throw ExportError.invalid("Choose an authorized output folder.")
        }
        let movieExtension = codec == .prores422 ? "mov" : "mp4"
        let outputName = (filename as NSString).pathExtension.isEmpty
            ? "\(filename).\(movieExtension)" : filename
        let outputURL = try await MainActor.run {
            try FileAccessManager.shared.resolve(folderID: folderID, relativePath: outputName, forWriting: true)
        }
        let resultLease = try await FileAccessManager.shared.acquire(reading: [outputURL], writing: [])
        let request = ExportRequest(inputURLs: fileURLs, outputURL: outputURL,
                                    settings: settings, overwrite: overwrite)
        let id = try await ExportCoordinator.shared.start(request)
        let progress = self.progress
        progress.totalUnitCount = Int64(fileURLs.count)
        let progressTask = Task {
            while !Task.isCancelled {
                let job = await ExportCoordinator.shared.job(id: id)
                progress.completedUnitCount = Int64(job?.completedFrames ?? 0)
                if job?.state.isTerminal != false { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }
        let file = try await performBackgroundTask {
            let url = try await ExportCoordinator.shared.wait(for: id)
            // Shortcuts serializes the result after perform() returns. A temporary
            // copy keeps that handoff independent of the output folder's scope.
            let transferURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Image2Movie-\(UUID().uuidString).\(url.pathExtension)")
            do {
                try FileManager.default.copyItem(at: url, to: transferURL)
            } catch {
                try? FileManager.default.removeItem(at: transferURL)
                throw error
            }
            withExtendedLifetime(resultLease) {}
            let movieType: UTType = codec == .prores422 ? .quickTimeMovie : .mpeg4Movie
            var file = IntentFile(fileURL: transferURL, filename: url.lastPathComponent, type: movieType)
            file.removedOnCompletion = true
            return file
        } onCancel: { _ in
            Task { @MainActor in try? ExportCoordinator.shared.cancel(id: id) }
        }
        progress.completedUnitCount = progress.totalUnitCount
        return .result(value: file)
    }
}

struct GetExportStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Export Status"
    static let description = IntentDescription("Inspect the active or a recent movie export.")
    @Parameter(title: "Job") var job: MovieJobEntity?

    static var parameterSummary: some ParameterSummary { Summary("Get status of \(\.$job)") }

    func perform() async throws -> some IntentResult & ReturnsValue<MovieJobEntity> {
        let id = job.flatMap { UUID(uuidString: $0.id) }
        guard let snapshot = await ExportCoordinator.shared.job(id: id) else { throw ExportError.unknownJob }
        return .result(value: MovieJobEntity(snapshot))
    }
}

struct CancelExportIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Export"
    static let description = IntentDescription("Cancel the active movie export.")
    @Parameter(title: "Job") var job: MovieJobEntity?

    static var parameterSummary: some ParameterSummary { Summary("Cancel \(\.$job)") }

    func perform() async throws -> some IntentResult {
        let id = job.flatMap { UUID(uuidString: $0.id) }
        try await ExportCoordinator.shared.cancel(id: id)
        return .result()
    }
}
