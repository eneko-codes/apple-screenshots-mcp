import Foundation
import Testing

@testable import ScreenshotsMCPCore

/// The edges of the tool standard for this server's tools: each bound and one past it, the
/// text of each notice, pages and windows that chain, the longest result, the deadline and
/// the texts the model reads. Every screenshot, id and recognised text here is invented.
@Suite("Bounds")
struct BoundsTests {

    private static func identifier(_ index: Int) -> String {
        Fixtures.identifier(String(format: "%012d", index))
    }

    /// An album of `count` screenshots, one minute apart, row 0 the newest.
    private static func album(_ count: Int) -> [Screenshot] {
        (0..<count).map {
            Screenshot(
                id: identifier($0),
                creationDate: Fixtures.date(2026, 8, 9, 12, 0).addingTimeInterval(Double(-60 * $0)),
                pixelWidth: 2940, pixelHeight: 1912)
        }
    }

    private func call(
        _ name: String, _ arguments: [String: Value] = [:], store: FakeScreenshotStore,
        timeout: Duration = Configuration.timeout
    ) async -> (text: String, isError: Bool) {
        let tools = ScreenshotTools(store: store, calendar: Fixtures.calendar, timeout: timeout)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text) = result.content.first else { return ("(no text)", true) }
        return (text, result.isError)
    }

    private func list(_ count: Int, _ arguments: [String: Value] = [:]) async -> (text: String, isError: Bool) {
        await call(
            ToolCatalog.listName, arguments,
            store: FakeScreenshotStore(screenshots: Self.album(count), text: [:]))
    }

    /// The rows of an album of `count` that `text` shows, in order.
    private func rows(in text: String, of count: Int) -> [Int] {
        (0..<count).filter { text.contains(Self.identifier($0)) }
    }

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data")
    func defaultPage() async {
        let total = Configuration.listLimit + 5
        let result = await list(total)
        let limit = Configuration.listLimit
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–\(limit) of \(total) screenshots. Pass offset=\(limit) for the next page.\n\n"))
        #expect(rows(in: result.text, of: total) == Array(0..<limit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds everything, asked for from the start, carries no notice")
    func noNoticeWhenComplete() async {
        let result = await list(3)
        #expect(!result.text.contains("Showing"))
        #expect(rows(in: result.text, of: 3) == [0, 1, 2])
    }

    @Test("limit at its maximum is used as asked, and the page fits the longest result")
    func maximumPage() async {
        let maximum = Configuration.listLimitRange.upperBound
        let result = await list(maximum + 10, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(rows(in: result.text, of: maximum + 10) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which")
    func limitPastItsRange() async {
        let maximum = Configuration.listLimitRange.upperBound
        let over = await list(maximum + 10, ["limit": .int(maximum + 1)])
        #expect(over.text.hasPrefix("limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nShowing 1–\(maximum) of "))
        let under = await list(5, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of 5 "))
        #expect(rows(in: under.text, of: 5) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all")
    func pagesChain() async {
        let first = await list(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 screenshots. Pass offset=3 for the next page.\n\n"))
        #expect(rows(in: first.text, of: 7) == [0, 1, 2])
        let second = await list(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 screenshots. Pass offset=6 for the next page.\n\n"))
        #expect(rows(in: second.text, of: 7) == [3, 4, 5])
        let last = await list(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 screenshots. That is all.\n\n"))
        #expect(rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero")
    func offsetEdges() async {
        let past = await list(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 screenshots: offset=7 is past the end. That is all.\n\n"))
        #expect(past.text.contains("(nothing at this offset)"))
        let negative = await list(7, ["offset": .int(-1)])
        let range = Configuration.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        let beyond = await list(7, ["offset": .int(range.upperBound + 1)])
        #expect(beyond.text.hasPrefix("offset=\(range.upperBound + 1) is outside "))
    }

    @Test("Screenshots taken at the same instant keep one order, by id, across pages")
    func tiesKeepOneOrder() async {
        let moment = Fixtures.date(2026, 8, 9, 12, 0)
        let tied = (0..<6).reversed().map {
            Screenshot(id: Self.identifier($0), creationDate: moment, pixelWidth: 100, pixelHeight: 100)
        }
        let store = FakeScreenshotStore(screenshots: tied, text: [:])
        var seen: [Int] = []
        for offset in stride(from: 0, to: 6, by: 2) {
            let result = await call(
                ToolCatalog.listName, ["limit": .int(2), "offset": .int(offset)], store: store)
            seen += rows(in: result.text, of: 6)
        }
        #expect(seen == [0, 1, 2, 3, 4, 5])
        #expect(await call(ToolCatalog.listName, store: store).text.contains("ordered newest first, then by id"))
    }

    @Test("An empty match says so, with no page notice")
    func emptyMatch() async {
        let result = await list(0)
        #expect(result.text.contains("No screenshots match."))
        #expect(!result.text.contains("Showing"))
    }

    // MARK: Dates

    private func between(_ from: String?, _ to: String?) async -> (text: String, isError: Bool) {
        var arguments: [String: Value] = [:]
        if let from { arguments["from_date"] = .string(from) }
        if let to { arguments["to_date"] = .string(to) }
        return await call(ToolCatalog.listName, arguments, store: FakeScreenshotStore())
    }

    @Test("to_date is inclusive at the precision written: a day covers the whole day")
    func toDateIsInclusive() async {
        // newest is 2026-08-09 11:05 and blank 11:06.
        let day = await between(nil, "2026-08-09")
        #expect(day.text.contains(Fixtures.newest) && day.text.contains(Fixtures.blank))
        let before = await between(nil, "2026-08-08")
        #expect(!before.text.contains(Fixtures.newest))
        let minute = await between(nil, "2026-08-09T11:05")
        #expect(minute.text.contains(Fixtures.newest) && !minute.text.contains(Fixtures.blank))
        let second = await between(nil, "2026-08-09T11:05:00")
        #expect(second.text.contains(Fixtures.newest) && !second.text.contains(Fixtures.blank))
        let offset = await between(nil, "2026-08-09T11:05:00+02:00")
        #expect(offset.text.contains(Fixtures.newest) && !offset.text.contains(Fixtures.blank))
    }

    @Test("A range inside one day is not backwards; one that ends before it starts is refused")
    func rangeOrder() async {
        let sameDay = await between("2026-08-09T11:05", "2026-08-09")
        #expect(!sameDay.isError)
        let backwards = await between("2026-08-09T11:07", "2026-08-09T11:06")
        #expect(backwards.isError)
    }

    @Test("A date that does not exist is refused, in every form")
    func impossibleDates() async {
        for text in [
            "2026-02-30", "2026-02-29", "2026-04-31", "2026-03-29T02:30", "2026-02-30T09:00",
            "2026-02-30T09:00:00+01:00", "2026-13-01", "2026-08-12T24:00",
        ] {
            let result = await between(text, nil)
            #expect(result.isError, "\(text)")
            #expect(result.text.contains("2026-08-12T09:00"), "\(text)")
        }
        #expect(await between("2028-02-29", nil).isError == false)
    }

    // MARK: Arguments

    @Test("An argument the tool does not list is refused with the names allowed, so a renamed one fails clearly")
    func unknownArguments() async {
        let renamed = await call(
            ToolCatalog.listName, ["from": .string("2026-08-01")], store: FakeScreenshotStore())
        #expect(renamed.isError)
        #expect(renamed.text.contains("'from'"))
        #expect(renamed.text.contains("Allowed: from_date, limit, offset, to_date."))
        let extract = await call(
            ToolCatalog.extractName, ["ids": .array([]), "to": .int(1)], store: FakeScreenshotStore())
        #expect(extract.text.contains("Allowed: character_offset, ids, max_characters."))
        let long = await call(
            ToolCatalog.listName, [String(repeating: "x", count: 500): .int(1)],
            store: FakeScreenshotStore())
        #expect(long.text.utf16.count < 400)
    }

    @Test("A wrong type is refused with the form expected")
    func wrongTypes() async {
        let limit = await call(
            ToolCatalog.listName, ["limit": .string("ten")], store: FakeScreenshotStore())
        #expect(limit.isError && limit.text.contains("a whole number was expected"))
        let ids = await call(
            ToolCatalog.extractName, ["ids": .array([.string(Fixtures.newest), .int(3)])],
            store: FakeScreenshotStore())
        #expect(ids.isError && ids.text.contains("an array of strings was expected"))
        let date = await call(
            ToolCatalog.listName, ["from_date": .int(5)], store: FakeScreenshotStore())
        #expect(date.isError && date.text.contains("a date string was expected"))
    }

    @Test("An unknown tool name is repeated only in part")
    func unknownToolIsClipped() async {
        let result = await call(String(repeating: "x", count: 500), store: FakeScreenshotStore())
        #expect(result.isError && result.text.utf16.count < 200)
    }

    // MARK: Extraction windows

    private static let longLine = (0..<400).map { "Line \(String(format: "%04d", $0)) of an invented page" }

    private func extract(
        _ ids: [String], _ extra: [String: Value] = [:], lines: [String] = BoundsTests.longLine
    ) async -> (text: String, isError: Bool) {
        let screenshots = Self.album(ids.count)
        var text: [String: [String]] = [:]
        for screenshot in screenshots { text[screenshot.id] = lines }
        let store = FakeScreenshotStore(screenshots: screenshots, text: text)
        return await call(
            ToolCatalog.extractName,
            ["ids": .array(ids.map { .string($0) })].merging(extra) { _, new in new }, store: store)
    }

    private var whole: String { Self.longLine.joined(separator: "\n") }

    private func window(_ text: String) -> String {
        guard let start = text.range(of: "---") else { return "" }
        let afterHeading = text[start.upperBound...].drop { $0 != "\n" }.dropFirst()
        return String(afterHeading)
    }

    @Test("A long text comes as one default window, announced before the data")
    func defaultWindow() async {
        let size = Configuration.defaultWindow(forIDs: 1)
        #expect(size == Configuration.defaultMaxCharacters)
        let result = await extract([Self.identifier(0)])
        let label = "id=\(Self.identifier(0))"
        #expect(result.text.hasPrefix("\(label): characters 1–\(size) of \(whole.count). Pass character_offset=\(size) for the rest.\n\nText from 1 of 1 screenshot"))
        #expect(window(result.text) == String(whole.prefix(size)))
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole text")
    func windowsChain() async {
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await extract([Self.identifier(0)], ["character_offset": .int(offset), "max_characters": .int(7000)])
            let part = window(result.text)
            let last = offset + part.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("id=\(Self.identifier(0)): characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("A text that fits one window carries no notice, and an offset past the end says so")
    func shortTextAndPastTheEnd() async {
        let short = await extract([Self.identifier(0)], lines: ["Seat 14A", "Gate B22"])
        #expect(!short.text.contains("characters"))
        let past = await extract([Self.identifier(0)], ["character_offset": .int(whole.count + 5)])
        #expect(past.text.hasPrefix("id=\(Self.identifier(0)): characters 0 of \(whole.count): character_offset=\(whole.count + 5) is past the end. That is all."))
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async {
        let maximum = Configuration.maxCharactersRange.upperBound
        let big = Array(repeating: String(repeating: "a", count: 100), count: 600)
        let atMaximum = await extract([Self.identifier(0)], ["max_characters": .int(maximum)], lines: big)
        #expect(!atMaximum.text.contains("is outside"))
        #expect(window(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await extract([Self.identifier(0)], ["max_characters": .int(maximum + 1)], lines: big)
        #expect(over.text.hasPrefix("max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n"))
        let under = await extract([Self.identifier(0)], ["max_characters": .int(0)], lines: big)
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\n"))
        #expect(window(under.text) == "a")
    }

    @Test("Several long texts at the largest window still fit, each notice says what was shown, and the default is one usual page")
    func severalLongTexts() async {
        let ids = (0..<Configuration.maximumExtractIDs).map { Self.identifier($0) }
        let huge = Array(repeating: String(repeating: "é", count: 100), count: 1000)
        let asked = await extract(ids, ["max_characters": .int(Configuration.maxCharactersRange.upperBound)], lines: huge)
        #expect(!asked.isError)
        #expect(asked.text.utf16.count <= ToolStandard.longestResult)
        for id in ids {
            let notice = asked.text.split(separator: "\n").first { $0.hasPrefix("id=\(id): characters 1–") }
            #expect(notice != nil)
            #expect(notice?.contains("Pass character_offset=") == true)
        }
        let standard = await extract(ids, lines: huge)
        // The text itself is a usual page; the headings and notices of ten screenshots come on top.
        #expect(standard.text.utf16.count <= ToolStandard.usualPage + 4_000, "\(standard.text.utf16.count)")
        #expect(standard.text.contains("characters 1–\(Configuration.defaultWindow(forIDs: ids.count)) of "))
    }

    @Test("Ids are bounded by the range the schema states")
    func idCount() async {
        let tooMany = await extract((0...Configuration.maximumExtractIDs).map { Self.identifier($0) })
        #expect(tooMany.isError)
        #expect(tooMany.text.contains("\(Configuration.maximumExtractIDs + 1) ids"))
        let atMaximum = await extract((0..<Configuration.maximumExtractIDs).map { Self.identifier($0) }, lines: ["Seat 14A"])
        #expect(!atMaximum.isError)
    }

    @Test("An id that is not in the album is repeated only in part")
    func longIdIsClipped() async {
        let result = await call(
            ToolCatalog.extractName, ["ids": .array([.string(String(repeating: "z", count: 500))])],
            store: FakeScreenshotStore())
        #expect(!result.isError)
        #expect(result.text.utf16.count < 1_500)
    }

    @Test("A very long failure text is cut")
    func longFailureIsCut() async {
        let store = FakeScreenshotStore()
        store.failureText = String(repeating: "f", count: 50_000)
        store.unreadable = [Fixtures.newest]
        let result = await call(
            ToolCatalog.extractName, ["ids": .array([.string(Fixtures.newest)])], store: store)
        #expect(result.text.utf16.count < 1_500)
    }

    @Test("The limited-library note comes before the data")
    func limitedNoteFirst() async {
        let result = await call(
            ToolCatalog.listName, store: FakeScreenshotStore(status: .limited))
        #expect(result.text.hasPrefix("NOTE: Photos access is a LIMITED SELECTION"))
    }

    // MARK: The deadline

    @Test("A call that stalls after reading some screenshots returns them, says it is partial, and names the way to narrow")
    func partialExtraction() async {
        let store = FakeScreenshotStore()
        store.stallAfter = 1
        let result = await call(
            ToolCatalog.extractName,
            ["ids": .array([.string(Fixtures.oldest), .string(Fixtures.newest)])],
            store: store, timeout: .milliseconds(600))
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Partial: the time limit was reached after 1 screenshots. Narrow by ids.\n\n"))
        #expect(result.text.contains("Boarding pass"))
        #expect(!result.text.contains("Internal Server Error"))
    }

    @Test("A call that reads nothing before its deadline is an error saying how to ask for less")
    func timeoutIsAnError() async {
        let extracting = FakeScreenshotStore()
        extracting.stallAfter = 0
        let first = await call(
            ToolCatalog.extractName, ["ids": .array([.string(Fixtures.newest)])],
            store: extracting, timeout: .milliseconds(300))
        #expect(first.isError && first.text.contains("did not finish within"))
        #expect(first.text.contains("nothing was changed"))

        let listing = FakeScreenshotStore()
        listing.stallList = true
        let second = await call(ToolCatalog.listName, store: listing, timeout: .milliseconds(300))
        #expect(second.isError && second.text.contains("did not finish within"))
    }

    @Test("The deadline sits inside the time limit of the standard")
    func deadlineIsInsideTheLimit() {
        #expect(Configuration.timeout < ToolStandard.timeLimit)
    }

    // MARK: What the model reads

    @Test("No instruction or description is over the limit, and each states the bounds the code enforces")
    func textsAreWithinTheLimit() {
        #expect(
            ToolStandard.overlongTexts(
                instructions: ScreenshotsMCPServer.instructions, catalog: ToolCatalog.all()
            ).isEmpty)
        let instructions = ScreenshotsMCPServer.instructions
        #expect(instructions.contains("\(Configuration.timeout.components.seconds)-second limit"))
        #expect(instructions.contains("\(Configuration.listLimitRange.upperBound)"))

        let list = ToolCatalog.all().first { $0.name == ToolCatalog.listName }
        let properties = list?.inputSchema.objectValue?["properties"]?.objectValue
        #expect(properties?["limit"]?.objectValue?["maximum"]?.intValue == Configuration.listLimitRange.upperBound)
        #expect(properties?["offset"]?.objectValue?["maximum"]?.intValue == Configuration.offsetRange.upperBound)
        #expect(list?.description?.contains("up to \(Configuration.listLimitRange.upperBound)") == true)

        let extract = ToolCatalog.all().first { $0.name == ToolCatalog.extractName }
        let extractProperties = extract?.inputSchema.objectValue?["properties"]?.objectValue
        #expect(extractProperties?["ids"]?.objectValue?["maxItems"]?.intValue == Configuration.maximumExtractIDs)
        #expect(extractProperties?["ids"]?.objectValue?["minItems"]?.intValue == 1)
        #expect(extractProperties?["max_characters"]?.objectValue?["maximum"]?.intValue == Configuration.maxCharactersRange.upperBound)
        #expect(extract?.description?.contains("up to \(Configuration.maxCharactersRange.upperBound)") == true)
    }

    @Test("Every argument a tool accepts is one its schema declares, and the old names are gone")
    func argumentNames() {
        #expect(ToolCatalog.argumentNames(of: ToolCatalog.listName) == ["from_date", "limit", "offset", "to_date"])
        #expect(ToolCatalog.argumentNames(of: ToolCatalog.extractName) == ["character_offset", "ids", "max_characters"])
        #expect(ToolCatalog.argumentNames(of: ToolCatalog.statusName).isEmpty)
    }
}
