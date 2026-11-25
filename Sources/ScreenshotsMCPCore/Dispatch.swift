import Foundation
import Synchronization

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches PhotoKit or Vision directly — everything goes through `ScreenshotStore`,
/// which is what lets the tests drive every branch below against an in-memory double with
/// no photo library and no consent dialog.
public struct ScreenshotTools: ToolHandler {
    private let store: any ScreenshotStore
    private let calendar: Calendar
    private let format: Format
    private let timeout: Duration

    public init(
        store: any ScreenshotStore,
        calendar: Calendar = .current,
        timeout: Duration = Configuration.timeout
    ) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(_ error: any Error, tool: String, since started: ContinuousClock.Instant)
        -> ToolOutput
    {
        Diagnostics.toolFailed(tool, error: error, since: started)
        // Only our own error types are described: a system error's text can quote a path.
        let message =
            (error as? ToolError)?.message
            ?? ToolError.storeFailure("the request could not be completed").message
        return ToolOutput(text: message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        guard ToolCatalog.all().contains(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }
        let arguments = try Arguments(
            parameters.arguments, calendar: calendar,
            allowed: ToolCatalog.argumentNames(of: parameters.name))

        if parameters.name == ToolCatalog.statusName {
            return try await status()
        }

        let authorization = try await requireAccess()
        // A limited library selection makes every answer partial, and a partial answer
        // that does not say so reads as a complete one. It goes before the data.
        let limited = authorization == .limited ? [Format.limitedAccessNote] : []

        switch parameters.name {
        case ToolCatalog.listName:
            return try await list(arguments, notices: limited)
        default:
            return try await extractText(arguments, notices: limited)
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

    /// Paged at the source: PhotoKit hands out only the assets of the page asked for, so
    /// the whole album is never loaded, and the notice is built from the total it reports.
    private func list(_ arguments: Arguments, notices extra: [String]) async throws -> String {
        let from = try arguments.optionalDate("from_date")
        let to = try arguments.optionalDate("to_date")
        // `to_date` is inclusive at the precision written, so the store is given the first
        // instant after everything it covers.
        let end = to?.endExclusive(calendar: calendar)
        if let from, let end, end <= from.date { throw ToolError.endBeforeStart }
        let page = try arguments.page(
            defaultLimit: Configuration.listLimit, limits: Configuration.listLimitRange)

        let found = try await store.list(
            from: from?.date, to: end, limit: page.limit, offset: page.offset)
        let position = Notice.page(
            offset: page.offset, count: found.results.count, total: found.total,
            things: "screenshots")
        return ToolStandard.withNotices(
            extra + arguments.notices + [position].compactMap { $0 },
            format.list(found, from: from, to: to))
    }

    private func extractText(_ arguments: Arguments, notices extra: [String]) async throws
        -> String
    {
        let requested = try arguments.stringArray("ids")
        guard !requested.isEmpty else { throw ToolError.missingArgument("ids") }

        // Deduplicated while keeping the caller's order: OCR is the expensive part of
        // this server, and running it twice for a repeated id buys nothing.
        var seen = Set<String>()
        let ids = requested.filter { seen.insert($0).inserted }

        guard Configuration.extractIDsRange.contains(ids.count) else {
            throw ToolError.tooManyIDs(
                count: ids.count, maximum: Configuration.maximumExtractIDs)
        }

        let characterOffset = try arguments.int(
            "character_offset", default: 0, in: Configuration.offsetRange)
        let maxCharacters = try arguments.int(
            "max_characters", default: Configuration.defaultWindow(forIDs: ids.count),
            in: Configuration.maxCharactersRange)

        // The deadline abandons this work rather than stopping it, so what it has read is
        // collected here and survives the abandonment.
        let collected = Collected()
        let outcome = await Deadline.run(within: timeout * 0.9) {
            do {
                try await store.extractText(ids: ids) { collected.append($0) }
                return Result<Void, any Error>.success(())
            } catch {
                return .failure(error)
            }
        }
        if case .failure(let error)? = outcome { throw error }

        let results = collected.snapshot()
        var partial: [String] = []
        if outcome == nil {
            // Nothing read at all is a failure to report, not a result.
            guard !results.isEmpty else {
                throw ToolError.timedOut(seconds: Int(timeout.components.seconds))
            }
            partial = [
                Notice.partial(after: results.count, things: "screenshots", narrowBy: "ids")
            ]
        }

        // Windows shrink only when the answer would not fit, and every notice is built from
        // what was rendered, so it stays true.
        return ToolStandard.fitting(maxCharacters) { size in
            let rendered = format.extracted(
                results, characterOffset: characterOffset, maxCharacters: size)
            return ToolStandard.withNotices(
                extra + arguments.notices + partial + rendered.notices, rendered.text)
        }
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}

/// What the store has delivered so far, readable from the thread that abandons the work.
private final class Collected: Sendable {
    private let results = Mutex<[TextExtraction]>([])

    func append(_ result: TextExtraction) {
        results.withLock { $0.append(result) }
    }

    func snapshot() -> [TextExtraction] {
        results.withLock { $0 }
    }
}
