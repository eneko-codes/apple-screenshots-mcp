import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop.
///
/// Three tools, all reads, so none carries a verb prefix — there is no `create_`,
/// `update_` or `delete_` here and there is no store method one could be built on. This
/// server cannot alter the photo library.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, because a tool whose
    /// schema depends on the configuration has to be built as a function and its name
    /// would then have nowhere stable to live.
    public static let statusName = "screenshots_status"
    public static let listName = "screenshots_list"
    public static let extractName = "screenshot_extract_text"

    /// Built from `Configuration`'s fixed constants, not a per-instance value — there is
    /// only one possible limit now, so a description drifting from what the server
    /// actually enforces is structurally impossible.
    public static func all() -> [Tool] {
        [status, list, extract]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is always a single string, never a union such as `["string", "null"]`.
    /// Claude Desktop's schema sanitiser drops a property whose type is a union and hands
    /// the model a bare `{}` in its place; an array property then arrives serialised as a
    /// string and is rejected. Omit a filter to leave it unbounded — never pass `null`.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "Screenshots permission and scope",
        description: """
            Reports whether this server can reach Photos, how many screenshots are in \
            scope, and exactly what the permission does and does not cover. Reads no \
            image and extracts no text.

            Read it before assuming an empty result means an empty album: macOS grants \
            Photos access for the whole library and this server narrows that to one smart \
            album in its own code, which this tool spells out.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let list = Tool(
        name: listName,
        title: "List screenshots",
        description: """
            Lists screenshots from the macOS Screenshots smart album, newest first, \
            with an id, when it was taken and its pixel size. Optionally bounded by a \
            date range.

            Returns METADATA ONLY. There is no image, no thumbnail, no file path and \
            no export — the ids exist so screenshot_extract_text can be pointed at a \
            few screenshots instead of the whole album. Photographs are not in this \
            album and cannot be listed here.
            """,
        inputSchema: object(properties: [
            "from": string("Earliest capture time to include (inclusive). \(dateHelp)"),
            "to": string("Latest capture time, exclusive. \(dateHelp)"),
            "limit": integer(
                "Maximum number of screenshots to return.",
                minimum: Configuration.listLimitRange.lowerBound,
                maximum: Configuration.listLimitRange.upperBound,
                default: Configuration.listLimit),
            "offset": integer(
                "Skip this many matches; use it to page.",
                minimum: Configuration.offsetRange.lowerBound,
                maximum: Configuration.offsetRange.upperBound, default: 0),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let extract = Tool(
        name: extractName,
        title: "Extract text from screenshots",
        description: """
            Runs Vision text recognition over one or more screenshots and returns the \
            recognised text, in reading order, per id. Up to \
            \(Configuration.maximumExtractIDs) ids per call — pass several rather than \
            calling repeatedly.

            Ids come from screenshots_list and are resolved inside the Screenshots \
            album, so an id naming an ordinary photograph is reported as out of scope \
            rather than read. The answer is text: no image data is returned by this \
            tool or by any other in this server.

            Recognition always uses Vision's own automatic language detection — there is \
            no language list to configure. OCR is imperfect on small or stylised type. \
            Treat the text as a reading of the screenshot, not as a transcript to quote \
            verbatim without saying so.
            """,
        inputSchema: object(
            properties: [
                "ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "maxItems": .int(Configuration.maximumExtractIDs),
                    "description": .string(
                        "Identifiers returned by screenshots_list. Several at once is "
                            + "cheaper than one call each."),
                ])
            ],
            required: ["ids"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )
}
