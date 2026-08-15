import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches PhotoKit or Vision directly — everything goes through `ScreenshotStore`,
/// which is what lets the tests drive every branch below against an in-memory double with
/// no photo library and no consent dialog.
public struct ScreenshotTools: Sendable {
    private let store: any ScreenshotStore
    private let calendar: Calendar
    private let format: Format

    public init(
        store: any ScreenshotStore,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        if parameters.name == ToolCatalog.statusName {
            return try await status()
        }

        let authorization = try await requireAccess()

        switch parameters.name {
        case ToolCatalog.listName:
            return try await withLimitedAccessNote(authorization, list(arguments))

        case ToolCatalog.extractName:
            return try await withLimitedAccessNote(authorization, extractText(arguments))

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func requireAccess() async throws -> PhotoAuthorization {
        var authorization = store.authorization()
        if authorization == .notDetermined {
            authorization = await store.requestAccess()
        }
        guard authorization.isUsable else { throw ToolError.notAuthorized(authorization) }
        return authorization
    }

    /// A limited library selection makes every answer partial, and a partial answer that
    /// does not say so reads as a complete one.
    private func withLimitedAccessNote(_ authorization: PhotoAuthorization, _ text: String)
        -> String
    {
        authorization == .limited ? text + "\n\n" + Format.limitedAccessNote : text
    }

    // MARK: Tools

    /// The one tool that answers before the permission is resolved, so a caller can find
    /// out what is wrong instead of guessing from a failure.
    private func status() async throws -> String {
        let authorization = store.authorization()
        // Counting needs the grant, so an ungranted server reports the scope it would
        // read rather than pretending the album is empty. Requesting access here would
        // pop a consent dialog from a tool whose whole job is to describe the state.
        var screenshotCount: Int?
        if authorization.isUsable {
            screenshotCount = try await store.count()
        }
        return format.status(
            authorization, screenshotCount: screenshotCount, binaryPath: Self.binaryPath)
    }

    private func list(_ arguments: Arguments) async throws -> String {
        let from = try arguments.optionalDate("from")
        let to = try arguments.optionalDate("to")
        if let from, let to, to.date < from.date { throw ToolError.endBeforeStart }

        let limit = try arguments.int(
            "limit", default: Configuration.listLimit, in: Configuration.listLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        let page = try await store.list(
            from: from?.date, to: to?.date, limit: limit, offset: offset)
        return format.list(page, from: from, to: to, offset: offset)
    }

    private func extractText(_ arguments: Arguments) async throws -> String {
        let requested = try arguments.stringArray("ids")
        guard !requested.isEmpty else { throw ToolError.missingArgument("ids") }

        // Deduplicated while keeping the caller's order: OCR is the expensive part of
        // this server, and running it twice for a repeated id buys nothing.
        var seen = Set<String>()
        let ids = requested.filter { seen.insert($0).inserted }

        guard ids.count <= Configuration.maximumExtractIDs else {
            throw ToolError.tooManyIDs(
                count: ids.count, maximum: Configuration.maximumExtractIDs)
        }

        let results = try await store.extractText(ids: ids)
        return format.extracted(results)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
