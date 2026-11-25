import Foundation

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

    /// The arguments a tool declares, read from its schema so that what is accepted and
    /// what is advertised cannot differ.
    public static func argumentNames(of toolName: String) -> [String] {
        let schema = all().first { $0.name == toolName }?.inputSchema
        return (schema?.objectValue?["properties"]?.objectValue ?? [:]).keys.sorted()
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

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int? = nil)
        -> Value
    {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
        ]
        if let def { schema["default"] = .int(def) }
        return .object(schema)
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
            Lists screenshots from the macOS Screenshots smart album, newest first (ties \
            by id), \(Configuration.listLimit) to a page, each with an id, when it was \
            taken and its pixel size. With no argument it returns the newest page. When \
            more match than the page holds, the first lines of the result say how many \
            there are and the offset to pass for the next page; limit goes up to \
            \(Configuration.listLimitRange.upperBound). from_date and to_date bound the \
            range, both inclusive: to_date=2026-08-12 includes the whole of that day.

            Returns METADATA ONLY. There is no image, no thumbnail, no file path and \
            no export: the ids exist so screenshot_extract_text can be pointed at a \
            few screenshots instead of the whole album. Photographs are not in this \
            album and cannot be listed here.
            """,
        inputSchema: object(properties: [
            "from_date": string("Earliest capture time to include. \(dateHelp)"),
            "to_date": string(
                "Latest capture time to include, inclusive at the precision written. \(dateHelp)"
            ),
            "limit": integer(
                "Maximum number of screenshots in one page.",
                range: Configuration.listLimitRange, default: Configuration.listLimit),
            "offset": integer(
                """
                Number of screenshots to skip. A result that does not hold every match \
                says, in its first lines, the offset to pass for the next page.
                """, range: Configuration.offsetRange, default: 0),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let extract = Tool(
        name: extractName,
        title: "Extract text from screenshots",
        description: """
            Runs Vision text recognition over one to \(Configuration.maximumExtractIDs) \
            screenshots and returns the recognised text, in reading order, per id. Each \
            screenshot's text is returned through a window: with no argument, about \
            \(Configuration.defaultMaxCharacters) characters shared among the ids asked \
            for. When a screenshot holds more, the first lines of the result say so and \
            give the character_offset that continues it; to read the rest of one, call \
            again with only its id. max_characters (up to \
            \(Configuration.maxCharactersRange.upperBound)) sets the window of each \
            screenshot, and a window that would not fit the answer is made smaller, as the \
            first lines say. A call that reaches its time limit returns the screenshots \
            read so far and says so.

            Ids come from screenshots_list and are resolved inside the Screenshots \
            album, so an id naming an ordinary photograph is reported as out of scope \
            rather than read. The answer is text: no image data is returned by this \
            tool or by any other in this server.

            Recognition uses Vision's default languages and language correction; there is \
            no language list to configure. OCR is imperfect on small or stylised type. \
            Treat the text as a reading of the screenshot, not as a transcript to quote \
            verbatim without saying so.
            """,
        inputSchema: object(
            properties: [
                "ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "minItems": .int(Configuration.extractIDsRange.lowerBound),
                    "maxItems": .int(Configuration.extractIDsRange.upperBound),
                    "description": .string(
                        "Identifiers returned by screenshots_list. Several at once is "
                            + "cheaper than one call each."),
                ]),
                "character_offset": integer(
                    """
                    Number of characters of each screenshot's text to skip. A result that \
                    does not hold all of a screenshot says, in its first lines, the value \
                    to pass for the rest; pass it with only that screenshot's id.
                    """, range: Configuration.offsetRange, default: 0),
                "max_characters": integer(
                    """
                    The most characters of each screenshot's text to return. Without it, \
                    \(Configuration.defaultMaxCharacters) divided by the number of ids.
                    """, range: Configuration.maxCharactersRange),
            ],
            required: ["ids"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )
}
