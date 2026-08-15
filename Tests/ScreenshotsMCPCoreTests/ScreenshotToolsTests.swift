import Foundation
import MCP
import Testing

@testable import ScreenshotsMCPCore

/// Drives the tool layer end to end against `FakeScreenshotStore`. No test in this file
/// touches PhotoKit or Vision, so the suite runs with no permission and no photo library —
/// which is the point.
@Suite("Tool dispatch")
struct ScreenshotToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeScreenshotStore = FakeScreenshotStore()
    ) async -> (text: String, isError: Bool) {
        let tools = ScreenshotTools(store: store, calendar: Fixtures.calendar)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let names = ToolCatalog.all().map(\.name)
        #expect(names.count == Set(names).count)
        #expect(names.count == 3, "three tools, no more: the catalogue is the scope")
        for tool in ToolCatalog.all() {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// A description claiming a ceiling different from what the server enforces would cost
    /// the model a wasted call to discover the truth. Both read the same `Configuration`
    /// constant, so this mostly guards against a typo splitting them apart.
    @Test("The extraction ceiling appears in the tool description and the schema")
    func descriptionReflectsConfiguration() {
        let extract = ToolCatalog.all().first { $0.name == "screenshot_extract_text" }
        #expect(
            extract?.description?.contains("\(Configuration.maximumExtractIDs) ids per call")
                == true)

        let ids = extract?.inputSchema.objectValue?["properties"]?.objectValue?["ids"]
        #expect(ids?.objectValue?["maxItems"]?.intValue == Configuration.maximumExtractIDs)
    }

    @Test("The default page size appears as the schema default")
    func listDefaultReflectsConfiguration() {
        let list = ToolCatalog.all().first { $0.name == "screenshots_list" }
        let limit = list?.inputSchema.objectValue?["properties"]?.objectValue?["limit"]
        #expect(limit?.objectValue?["default"]?.intValue == Configuration.listLimit)
    }

    /// The naming convention across the sibling servers reserves create_/update_/delete_
    /// for writes. This server has no writes, so no tool may carry one — a verb prefix
    /// appearing here would mean the seam had grown a mutation.
    @Test("Every tool is a read and none carries a write verb")
    func everythingIsRead() {
        for tool in ToolCatalog.all() {
            #expect(tool.annotations.readOnlyHint == true, "\(tool.name)")
            #expect(tool.annotations.destructiveHint == false, "\(tool.name)")
            for verb in ["create_", "update_", "delete_"] {
                #expect(!tool.name.hasPrefix(verb), "\(tool.name)")
            }
        }
    }

    /// Regression guard for a defect first seen in the sibling contacts server, where it
    /// made every list field of update_contact unusable.
    ///
    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union such as
    /// `["array", "null"]`, replacing the whole subtree with `{}`. The model then
    /// serialises an array argument to a string and `Arguments` rejects it. Text fields
    /// hide the fault, because an untyped string still arrives as a string. Nothing
    /// downstream of the client can catch this, so it is caught here — and `ids` is an
    /// array, which is exactly the shape that breaks.
    @Test("No property declares its type as a union")
    func schemasDeclareScalarTypes() {
        func walk(_ value: Value, path: String) {
            guard let node = value.objectValue else { return }
            if let declared = node["type"] {
                #expect(
                    declared.stringValue != nil,
                    "\(path): type must be a single string, not a union")
            }
            for (key, child) in node["properties"]?.objectValue ?? [:] {
                walk(child, path: "\(path).\(key)")
            }
            if let items = node["items"] { walk(items, path: "\(path)[]") }
        }
        for tool in ToolCatalog.all() { walk(tool.inputSchema, path: tool.name) }
    }

    /// The whole premise of the server: metadata and text cross the boundary, images do
    /// not. A tool gaining a `path`, `thumbnail` or `data` field would be the moment that
    /// stopped being true.
    @Test("No tool advertises a way to get image data out")
    func nothingOffersImageData() {
        let forbidden = ["path", "file", "thumbnail", "image", "data", "export", "base64", "url"]
        for tool in ToolCatalog.all() {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            for name in properties.keys {
                #expect(
                    !forbidden.contains(name.lowercased()),
                    "\(tool.name).\(name) sounds like an image escape hatch")
            }
        }
    }

    // MARK: Permission

    @Test("A denied permission names the switch and where to find it")
    func deniedPermissionExplainsItself() async {
        let result = await call("screenshots_list", store: FakeScreenshotStore(status: .denied))
        #expect(result.isError)
        #expect(result.text.contains("System Settings"))
        #expect(result.text.contains("apple-screenshots-mcp"))
    }

    @Test("A restricted permission says it cannot be granted from System Settings")
    func restrictedPermissionExplainsItself() async {
        let result = await call(
            "screenshots_list", store: FakeScreenshotStore(status: .restricted))
        #expect(result.isError)
        #expect(result.text.contains("policy"))
    }

    @Test("An undetermined permission is requested once, then the call proceeds")
    func undeterminedPermissionIsRequested() async {
        let store = FakeScreenshotStore(status: .notDetermined)
        let result = await call("screenshots_list", store: store)
        #expect(!result.isError)
        #expect(store.accessRequests == 1)
    }

    /// Limited access works, but a partial album that does not announce itself reads as a
    /// complete one — which is the failure mode worth guarding.
    @Test("Limited library access still answers, and says the answer is partial")
    func limitedAccessIsAnnounced() async {
        let store = FakeScreenshotStore(status: .limited)
        let list = await call("screenshots_list", store: store)
        #expect(!list.isError)
        #expect(list.text.contains("LIMITED SELECTION"))

        let extracted = await call(
            "screenshot_extract_text", ["ids": .array([.string(Fixtures.newest)])], store: store)
        #expect(!extracted.isError)
        #expect(extracted.text.contains("LIMITED SELECTION"))
    }

    // MARK: Status

    @Test("screenshots_status reports without needing permission")
    func statusWorksWhileDenied() async {
        let store = FakeScreenshotStore(status: .denied)
        let result = await call("screenshots_status", store: store)
        #expect(!result.isError)
        #expect(result.text.contains("DENIED"))
        #expect(store.accessRequests == 0, "status must not trigger a consent dialog")
    }

    @Test("screenshots_status counts what is in scope when it can")
    func statusReportsCount() async {
        let result = await call("screenshots_status")
        #expect(result.text.contains("4 screenshots in the album"))
    }

    @Test("screenshots_status admits it cannot count without the grant")
    func statusAdmitsUnknownCount() async {
        let result = await call("screenshots_status", store: FakeScreenshotStore(status: .denied))
        #expect(result.text.contains("nothing was counted"))
    }

    /// The honesty requirement, asserted rather than trusted to review: the status tool
    /// must say the grant is library-wide and that the narrowing is code, not a sandbox.
    @Test("screenshots_status states that the scope is code, not a permission")
    func statusIsHonestAboutScope() async {
        let result = await call("screenshots_status")
        #expect(result.text.contains("WHOLE LIBRARY"))
        #expect(result.text.contains("NOT BY THE OS"))
        #expect(result.text.contains("sandbox"))
        #expect(result.text.contains("PHAssetCollectionSubtypeSmartAlbumScreenshots"))
        #expect(result.text.contains("No image data ever crosses"))
    }

    @Test("screenshots_status reports the fixed operating limits")
    func statusReportsConfiguration() async {
        let result = await call("screenshots_status")
        #expect(result.text.contains("Vision automatic detection"))
        #expect(result.text.contains("at most \(Configuration.maximumExtractIDs)"))
        #expect(result.text.contains("\(Configuration.listLimit)"))
    }

    // MARK: List

    @Test("Listing returns newest first, with size and id and nothing else")
    func listIsNewestFirst() async {
        let result = await call("screenshots_list")
        #expect(!result.isError)
        #expect(result.text.contains("4 screenshots · whole album"))
        #expect(result.text.contains("Europe/Madrid"))
        #expect(result.text.contains("2940×1912"))

        let newestLine = result.text.range(of: Fixtures.newest)
        let oldestLine = result.text.range(of: Fixtures.oldest)
        #expect(newestLine != nil && oldestLine != nil)
        #expect(newestLine!.lowerBound < oldestLine!.lowerBound, "newest must sort first")
    }

    @Test("A date range filters and is echoed back in the form it arrived in")
    func listRangeIsEchoed() async {
        let result = await call(
            "screenshots_list", ["from": .string("2026-08-01"), "to": .string("2026-08-09")])
        #expect(result.text.contains("2026-08-01 → 2026-08-09"))
        #expect(result.text.contains(Fixtures.middle))
        #expect(!result.text.contains(Fixtures.oldest), "July is outside the range")
        #expect(!result.text.contains(Fixtures.newest), "'to' is exclusive")
    }

    @Test("Either bound may be given alone")
    func listAcceptsOneSidedRanges() async {
        let openEnded = await call("screenshots_list", ["from": .string("2026-08-01")])
        #expect(openEnded.text.contains("from 2026-08-01 onwards"))
        #expect(!openEnded.text.contains(Fixtures.oldest))

        let openStart = await call("screenshots_list", ["to": .string("2026-08-01")])
        #expect(openStart.text.contains("before 2026-08-01"))
        #expect(openStart.text.contains(Fixtures.oldest))
    }

    @Test("A range that runs backwards is refused")
    func backwardsRangeIsRefused() async {
        let result = await call(
            "screenshots_list", ["from": .string("2026-08-09"), "to": .string("2026-08-01")])
        #expect(result.isError)
        #expect(result.text.contains("cannot end before it begins"))
    }

    @Test("A truncated page announces what it withheld")
    func truncationIsAnnounced() async {
        let result = await call("screenshots_list", ["limit": .int(2)])
        #expect(result.text.contains("more · call again with offset=2"))
    }

    @Test("Offset pages through the album")
    func offsetPages() async {
        let result = await call("screenshots_list", ["limit": .int(2), "offset": .int(2)])
        #expect(result.text.contains(Fixtures.oldest))
        #expect(!result.text.contains(Fixtures.newest))
    }

    @Test("An empty match says so instead of returning a bare header")
    func emptyMatchIsExplicit() async {
        let result = await call(
            "screenshots_list", ["from": .string("2020-01-01"), "to": .string("2020-02-01")])
        #expect(!result.isError)
        #expect(result.text.contains("No screenshots match."))
    }

    @Test("A date this server does not accept is refused, naming the three forms")
    func badDateIsRefused() async {
        let result = await call("screenshots_list", ["from": .string("09/08/2026")])
        #expect(result.isError)
        #expect(result.text.contains("2026-08-12T09:00"))
    }

    @Test("An out-of-range limit is clamped rather than rejected")
    func limitIsClamped() async {
        let result = await call("screenshots_list", ["limit": .int(9999)])
        #expect(!result.isError)
    }

    // MARK: Extract

    @Test("Text comes back per id, in the order the ids were given")
    func extractPreservesOrder() async {
        let result = await call(
            "screenshot_extract_text",
            ["ids": .array([.string(Fixtures.oldest), .string(Fixtures.newest)])])
        #expect(!result.isError)
        #expect(result.text.contains("Boarding pass"))
        #expect(result.text.contains("Internal Server Error"))

        let first = result.text.range(of: "Boarding pass")!
        let second = result.text.range(of: "Internal Server Error")!
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test("The header counts how many ids produced text")
    func extractHeaderCounts() async {
        let result = await call(
            "screenshot_extract_text",
            ["ids": .array([.string(Fixtures.newest), .string(Fixtures.photograph)])])
        #expect(result.text.contains("Text from 1 of 2 screenshots"))
    }

    /// The load-bearing test of the whole repository. An id belonging to a photograph must
    /// not resolve, and the refusal must explain that ids are scoped to the album.
    @Test("An id outside the Screenshots album is refused, not read")
    func photographIDIsOutOfScope() async {
        let store = FakeScreenshotStore()
        let result = await call(
            "screenshot_extract_text", ["ids": .array([.string(Fixtures.photograph)])],
            store: store)
        #expect(!result.isError, "one bad id is a per-id outcome, not a failed call")
        #expect(result.text.contains("Screenshots album"))
        #expect(result.text.contains("ordinary photograph"))
    }

    /// A stale id must not cost the caller the ids that still work.
    @Test("One unknown id does not sink the whole batch")
    func partialBatchStillAnswers() async {
        let result = await call(
            "screenshot_extract_text",
            ["ids": .array([.string(Fixtures.photograph), .string(Fixtures.middle)])])
        #expect(!result.isError)
        #expect(result.text.contains("Total 42,30 €"))
    }

    @Test("A screenshot with no recognisable text says so rather than looking empty")
    func blankScreenshotIsExplicit() async {
        let result = await call(
            "screenshot_extract_text", ["ids": .array([.string(Fixtures.blank)])])
        #expect(!result.isError)
        #expect(result.text.contains("no text recognised"))
    }

    @Test("A screenshot whose pixels cannot be read reports the reason")
    func unreadableScreenshotReportsWhy() async {
        let store = FakeScreenshotStore()
        store.unreadable = [Fixtures.newest]
        let result = await call(
            "screenshot_extract_text", ["ids": .array([.string(Fixtures.newest)])], store: store)
        #expect(!result.isError)
        #expect(result.text.contains("cannot read:"))
    }

    @Test("Repeated ids are deduplicated before OCR runs")
    func duplicateIDsAreCollapsed() async {
        let store = FakeScreenshotStore()
        _ = await call(
            "screenshot_extract_text",
            ["ids": .array([.string(Fixtures.newest), .string(Fixtures.newest)])], store: store)
        #expect(store.extractCalls.first == [Fixtures.newest])
    }

    @Test("More ids than the fixed ceiling is refused before any OCR runs")
    func tooManyIDsIsRefused() async {
        let store = FakeScreenshotStore()
        // One more id than the ceiling allows. None of these need to resolve to a real
        // screenshot: the ceiling is enforced before the store is ever asked.
        let ids = (0...Configuration.maximumExtractIDs).map {
            Fixtures.identifier(String(format: "%012d", $0))
        }
        let result = await call(
            "screenshot_extract_text", ["ids": .array(ids.map { .string($0) })], store: store)
        #expect(result.isError == true)
        #expect(store.extractCalls.isEmpty, "nothing may be read once the call is refused")
    }

    @Test("An empty id list is refused rather than silently returning nothing")
    func emptyIDsIsRefused() async {
        let result = await call("screenshot_extract_text", ["ids": .array([])])
        #expect(result.isError)
        #expect(result.text.contains("ids"))
    }

    @Test("A bare string where a list was expected is accepted")
    func singleStringIsAccepted() async {
        let result = await call(
            "screenshot_extract_text", ["ids": .string(Fixtures.middle)])
        #expect(!result.isError)
        #expect(result.text.contains("IVA incluido"))
    }

    // MARK: Routing

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let result = await call("screenshots_delete_everything")
        #expect(result.isError)
        #expect(result.text.contains("is not a tool of this server"))
    }
}
