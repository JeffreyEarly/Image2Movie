import AppKit
import Foundation
import MCP
import UniformTypeIdentifiers

@MainActor
enum MovieMCPTools {
    static func register(on server: Server) async {
        let tools = definitions
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { parameters in
            await MainActor.run { call(parameters) }
        }
    }

    private static let fileReference: Value = .object([
        "type": .string("object"),
        "properties": .object([
            "folder_id": .object(["type": .string("string"), "format": .string("uuid")]),
            "relative_path": .object(["type": .string("string")])
        ]),
        "required": .array([.string("folder_id"), .string("relative_path")]),
        "additionalProperties": .bool(false)
    ])

    private static func schema(_ properties: [String: Value] = [:], required: [String] = []) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": .bool(false)
        ])
    }

    private static let definitions: [Tool] = [
        Tool(name: "get_capabilities", description: "Show supported movie settings, deterministic defaults, and export limits.",
             inputSchema: schema(), annotations: .init(readOnlyHint: true),
             outputSchema: schema(["defaults": .object(["type": .string("object")]),
                                   "limits": .object(["type": .string("object")]),
                                   "codecs": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                                   "qualities": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                                   "file_references": .object(["type": .string("string")])],
                                  required: ["defaults", "limits", "codecs", "qualities", "file_references"])),
        Tool(name: "list_authorized_folders", description: "List folder identifiers the user authorized in Image2Movie.",
             inputSchema: schema(), annotations: .init(readOnlyHint: true),
             outputSchema: schema(["folders": .object(["type": .string("array"),
                 "items": schema(["id": .object(["type": .string("string"), "format": .string("uuid")]),
                                   "name": .object(["type": .string("string")]),
                                   "writable": .object(["type": .string("boolean")])],
                                  required: ["id", "name", "writable"])])], required: ["folders"])),
        Tool(name: "inspect_sequence", description: "List supported images in numeric filename order, with rejected entries and reasons. Paths are relative to an authorized folder.",
             inputSchema: schema(["folder_id": .object(["type": .string("string"), "format": .string("uuid")]),
                                  "relative_path": .object(["type": .string("string"), "description": .string("Optional subfolder; omit to inspect the authorized folder root.")]),
                                  "offset": .object(["type": .string("integer"), "minimum": .int(0)]),
                                  "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(500)])],
                                 required: ["folder_id"]),
             annotations: .init(readOnlyHint: true),
             outputSchema: schema(["accepted": .object(["type": .string("array"), "items": fileReference]),
                                   "rejected": .object(["type": .string("array"), "items": schema([
                                      "name": .object(["type": .string("string")]),
                                      "reason": .object(["type": .string("string")])], required: ["name", "reason"])]),
                                   "count": .object(["type": .string("integer")]),
                                   "total_entries": .object(["type": .string("integer")]),
                                   "next_offset": .object(["type": .array([.string("integer"), .string("null")])])],
                                  required: ["accepted", "rejected", "count", "total_entries", "next_offset"])),
        Tool(name: "export_movie", description: "Start one movie export and return its job ID promptly. The input list is explicit order and may contain duplicates; output must be in a writable authorized folder.",
             inputSchema: schema([
                "inputs": .object(["type": .string("array"), "items": fileReference, "minItems": .int(1)]),
                "output": fileReference,
                "width": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(3840)]),
                "height": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(2160)]),
                "frame_rate": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(30)]),
                "codec": .object(["type": .string("string"), "enum": .array([.string("h264"), .string("hevc"), .string("prores422")])]),
                "quality": .object(["type": .string("string"), "enum": .array([.string("standard"), .string("high"), .string("custom")])]),
                "custom_bitrate_mbps": .object(["type": .string("number"), "minimum": .double(0.1), "maximum": .int(50)]),
                "overwrite": .object(["type": .string("boolean")])
             ], required: ["inputs", "output", "width", "height"]),
             outputSchema: schema(["job_id": .object(["type": .string("string"), "format": .string("uuid")]),
                                   "state": .object(["type": .string("string")])],
                                  required: ["job_id", "state"])),
        Tool(name: "get_export_status", description: "Read a job's progress, effective settings, output location, or failure. Omit job_id for the active or most recent job.",
             inputSchema: schema(["job_id": .object(["type": .string("string"), "format": .string("uuid")])]),
             annotations: .init(readOnlyHint: true),
             outputSchema: schema(["job_id": .object(["type": .string("string")]),
                                   "state": .object(["type": .string("string")]),
                                   "progress": .object(["type": .string("number")]),
                                   "completed_frames": .object(["type": .string("integer")]),
                                   "total_frames": .object(["type": .string("integer")]),
                                   "settings": .object(["type": .string("object")]),
                                   "output_url": .object(["type": .string("string")]),
                                   "error": .object(["type": .array([.string("object"), .string("null")])])],
                                  required: ["job_id", "state", "progress", "completed_frames", "total_frames", "settings", "output_url", "error"])),
        Tool(name: "cancel_export", description: "Cancel a running export by job ID, or omit job_id to cancel the active export.",
             inputSchema: schema(["job_id": .object(["type": .string("string"), "format": .string("uuid")])]),
             outputSchema: schema(["cancelled": .object(["type": .string("boolean")]),
                                   "job_id": .object(["type": .array([.string("string"), .string("null")])])],
                                  required: ["cancelled", "job_id"]))
    ]

    private static func call(_ parameters: CallTool.Parameters) -> CallTool.Result {
        do {
            let args = parameters.arguments ?? [:]
            let value: Value
            switch parameters.name {
            case "get_capabilities":
                try checkKeys(args, allowed: [])
                value = .object([
                    "defaults": .object(["frame_rate": .int(30), "codec": .string("hevc"),
                                         "quality": .string("high"), "overwrite": .bool(false)]),
                    "limits": .object(["maximum_width": .int(3840), "maximum_height": .int(2160),
                                       "maximum_frame_rate": .int(30), "concurrent_exports": .int(1)]),
                    "codecs": .array([.string("h264"), .string("hevc"), .string("prores422")]),
                    "qualities": .array([.string("standard"), .string("high"), .string("custom")]),
                    "file_references": .string("Authorized folder UUID plus a relative path; arbitrary file URLs are refused.")
                ])
            case "list_authorized_folders":
                try checkKeys(args, allowed: [])
                value = .object(["folders": .array(FileAccessManager.shared.folders.map {
                    .object(["id": .string($0.id.uuidString), "name": .string($0.name),
                             "writable": .bool($0.writable)])
                })])
            case "inspect_sequence":
                try checkKeys(args, allowed: ["folder_id", "relative_path", "offset", "limit"])
                value = try inspect(args)
            case "export_movie":
                try checkKeys(args, allowed: ["inputs", "output", "width", "height", "frame_rate",
                                              "codec", "quality", "custom_bitrate_mbps", "overwrite"])
                value = try export(args)
            case "get_export_status":
                try checkKeys(args, allowed: ["job_id"])
                let id = try optionalUUID("job_id", in: args)
                guard let job = ExportCoordinator.shared.job(id: id) else { throw ToolError("unknown_job", "No matching export job is available.") }
                value = try statusValue(job)
            case "cancel_export":
                try checkKeys(args, allowed: ["job_id"])
                let id = try optionalUUID("job_id", in: args)
                let cancelledID = id ?? ExportCoordinator.shared.activeJob?.id
                try ExportCoordinator.shared.cancel(id: id)
                value = .object(["cancelled": .bool(true), "job_id": cancelledID.map { .string($0.uuidString) } ?? .null])
            default:
                throw ToolError("unknown_tool", "Unknown tool \(parameters.name).")
            }
            return result(value)
        } catch let error as ToolError {
            return result(.object(["error": .object(["code": .string(error.code), "message": .string(error.message)])]), isError: true)
        } catch let error as ExportError {
            let code: String
            switch error {
            case .busy: code = "export_busy"
            case .invalid(let message): code = message.contains("already exists") ? "overwrite_refused" : "invalid_export"
            case .unknownJob: code = "unknown_job"
            case .cancelled: code = "cancelled"
            }
            return result(.object(["error": .object(["code": .string(code),
                                                      "message": .string(error.localizedDescription)])]), isError: true)
        } catch {
            return result(.object(["error": .object(["code": .string("operation_failed"),
                                                      "message": .string(error.localizedDescription)])]), isError: true)
        }
    }

    private static func inspect(_ args: [String: Value]) throws -> Value {
        let id = try uuid("folder_id", in: args)
        let path = args["relative_path"] == nil ? "" : try string("relative_path", in: args)
        let offset = try integer("offset", in: args, default: 0)
        let limit = try integer("limit", in: args, default: 100)
        guard offset >= 0, (1...500).contains(limit) else {
            throw ToolError("invalid_page", "offset must be at least 0 and limit must be 1–500.")
        }
        let root = try FileAccessManager.shared.rootURL(folderID: id)
        let directory = try path.isEmpty
            ? root
            : FileAccessManager.validatedDescendant(root: root, relativePath: path)
        let lease = try FileAccessManager.shared.acquire(reading: [root], writing: [])
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError("not_directory", "The selected path is not a readable directory.")
        }
        guard let enumerator = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else {
            throw ToolError("unreadable_directory", "The sequence directory could not be listed.")
        }
        var entries: [URL] = []
        while let entry = enumerator.nextObject() as? URL {
            guard entries.count < 10_000 else {
                throw ToolError("too_many_entries", "This folder has over 10,000 entries. Choose a smaller subfolder.")
            }
            entries.append(entry)
        }
        entries.sort {
            let lhs = $0.lastPathComponent, rhs = $1.lastPathComponent
            let comparison = lhs.compare(rhs, options: [.numeric, .caseInsensitive],
                                         locale: Locale(identifier: "en_US_POSIX"))
            return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
        }
        let page = entries.dropFirst(offset).prefix(limit)
        let supported = NSImage.imageTypes.compactMap(UTType.init)
        var accepted: [Value] = [], rejected: [Value] = []
        for entry in page {
            let name = entry.lastPathComponent
            let relative = path.isEmpty ? name : "\(path)/\(name)"
            do {
                _ = try FileAccessManager.validatedDescendant(root: root, relativePath: relative)
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
                guard values.isRegularFile == true else { throw ToolError("not_file", "Not a regular file.") }
                guard let type = values.contentType,
                      supported.contains(where: { type.conforms(to: $0) }) else {
                    throw ToolError("unsupported_format", "Unsupported image format.")
                }
                accepted.append(.object(["folder_id": .string(id.uuidString), "relative_path": .string(relative)]))
            } catch {
                rejected.append(.object(["name": .string(name), "reason": .string(error.localizedDescription)]))
            }
        }
        withExtendedLifetime(lease) {}
        return .object(["accepted": .array(accepted), "rejected": .array(rejected),
                        "count": .int(accepted.count), "total_entries": .int(entries.count),
                        "next_offset": offset + page.count < entries.count ? .int(offset + page.count) : .null])
    }

    private static func export(_ args: [String: Value]) throws -> Value {
        guard let items = args["inputs"]?.arrayValue, !items.isEmpty else {
            throw ToolError("invalid_inputs", "Provide at least one image in inputs.")
        }
        guard let output = args["output"] else { throw ToolError("missing_output", "Provide an output folder ID and relative path.") }
        let codecName = try optionalString("codec", in: args) ?? "hevc"
        let qualityName = try optionalString("quality", in: args) ?? "high"
        guard let codec = ExportCodec(rawValue: codecName) else { throw ToolError("unsupported_codec", "Choose h264, hevc, or prores422.") }
        guard let quality = ExportQuality(rawValue: qualityName) else { throw ToolError("unsupported_quality", "Choose standard, high, or custom.") }
        let settings = ExportSettings(width: try integer("width", in: args),
                                      height: try integer("height", in: args),
                                      frameRate: try integer("frame_rate", in: args, default: 30),
                                      codec: codec, quality: quality,
                                      customBitrateMbps: try optionalNumber("custom_bitrate_mbps", in: args))
        let overwrite = try optionalBool("overwrite", in: args) ?? false
        let inputURLs = try items.map { try resolve($0, forWriting: false) }
        let outputURL = try resolve(output, forWriting: true)
        let id = try ExportCoordinator.shared.start(ExportRequest(inputURLs: inputURLs, outputURL: outputURL,
                                                                   settings: settings, overwrite: overwrite))
        return .object(["job_id": .string(id.uuidString), "state": .string("running")])
    }

    private static func statusValue(_ job: ExportJob) throws -> Value {
        let error: Value = job.error.map {
            .object(["code": .string(job.state == .cancelled ? "cancelled" : "export_failed"),
                     "message": .string($0)])
        } ?? .null
        return .object(["job_id": .string(job.id.uuidString), "state": .string(job.state.rawValue),
                        "progress": .double(job.progress), "completed_frames": .int(job.completedFrames),
                        "total_frames": .int(job.totalFrames), "settings": try Value(job.settings),
                        "output_url": .string(job.outputURL.path), "error": error])
    }

    private static func resolve(_ value: Value, forWriting: Bool) throws -> URL {
        guard let object = value.objectValue else { throw ToolError("invalid_path", "A file reference must be an object.") }
        try checkKeys(object, allowed: ["folder_id", "relative_path"])
        return try FileAccessManager.shared.resolve(folderID: uuid("folder_id", in: object),
                                                    relativePath: string("relative_path", in: object),
                                                    forWriting: forWriting)
    }

    private static func string(_ key: String, in args: [String: Value]) throws -> String {
        guard let value = args[key]?.stringValue else { throw ToolError("invalid_argument", "\(key) must be a string.") }
        return value
    }
    private static func uuid(_ key: String, in args: [String: Value]) throws -> UUID {
        guard let value = UUID(uuidString: try string(key, in: args)) else {
            throw ToolError("invalid_argument", "\(key) must be a folder or job UUID.")
        }
        return value
    }
    private static func optionalUUID(_ key: String, in args: [String: Value]) throws -> UUID? {
        args[key] == nil ? nil : try uuid(key, in: args)
    }
    private static func optionalString(_ key: String, in args: [String: Value]) throws -> String? {
        guard let value = args[key] else { return nil }
        guard let string = value.stringValue else { throw ToolError("invalid_argument", "\(key) must be a string.") }
        return string
    }
    private static func optionalBool(_ key: String, in args: [String: Value]) throws -> Bool? {
        guard let value = args[key] else { return nil }
        guard let bool = value.boolValue else { throw ToolError("invalid_argument", "\(key) must be a boolean.") }
        return bool
    }
    private static func optionalNumber(_ key: String, in args: [String: Value]) throws -> Double? {
        guard let value = args[key] else { return nil }
        guard let number = value.doubleValue ?? value.intValue.map(Double.init) else {
            throw ToolError("invalid_argument", "\(key) must be a number.")
        }
        return number
    }
    private static func checkKeys(_ args: [String: Value], allowed: Set<String>) throws {
        if let unexpected = args.keys.first(where: { !allowed.contains($0) }) {
            throw ToolError("unknown_argument", "\(unexpected) is not a supported argument.")
        }
    }
    private static func integer(_ key: String, in args: [String: Value], default fallback: Int) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard let integer = value.intValue else { throw ToolError("invalid_argument", "\(key) must be an integer.") }
        return integer
    }
    private static func integer(_ key: String, in args: [String: Value]) throws -> Int {
        guard args[key] != nil else { throw ToolError("missing_argument", "\(key) is required.") }
        return try integer(key, in: args, default: 0)
    }
    private static func result(_ value: Value, isError: Bool = false) -> CallTool.Result {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let candidate = CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)],
                                        structuredContent: Optional.some(value), isError: isError)
        if let encoded = try? JSONEncoder().encode(candidate), encoded.count <= 131_072 {
            return candidate
        }
        let error: Value = .object(["error": .object([
            "code": .string("result_too_large"),
            "message": .string("The result exceeds 128 KiB. Request a smaller inspection page.")
        ])])
        return .init(content: [.text(text: "Result exceeds 128 KiB; use a smaller page.", annotations: nil, _meta: nil)],
                     structuredContent: Optional.some(error), isError: true)
    }
}

private struct ToolError: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}
