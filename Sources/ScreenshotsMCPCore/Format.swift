import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// `Sun 09 Aug 2026 12:34`, or a placeholder for an asset Photos has no capture date
    /// for — rare, but it happens to assets imported without metadata.
    func stamp(_ date: Date?) -> String {
        guard let date else { return "(no date)" }
        return DateParsing.dayWithYear(date, calendar: calendar) + " "
            + DateParsing.time(date, calendar: calendar)
    }

    static func size(_ screenshot: Screenshot) -> String {
        "\(screenshot.pixelWidth)×\(screenshot.pixelHeight)"
    }

    /// A filter bound printed back in the shape it arrived in, so the echoed range can be
    /// pasted straight into the next call.
    func echo(_ bound: ParsedDate) -> String {
        DateParsing.roundTrip(bound.date, isDateOnly: bound.isDateOnly, calendar: calendar)
    }

    /// Appended to any answer built while the library grant is a limited selection. The
    /// caller would otherwise read a short list as a short album.
    static let limitedAccessNote = """
        NOTE: Photos access is a LIMITED SELECTION, so this is only the part of the \
        Screenshots album that selection covers. Call screenshots_status for how to widen \
        it.
        """

    // MARK: Tools

    public func list(_ page: ScreenshotPage, from: ParsedDate?, to: ParsedDate?, offset: Int)
        -> String
    {
        let range: String
        switch (from, to) {
        case (nil, nil):
            range = "whole album"
        case (let start?, nil):
            range = "from \(echo(start)) onwards"
        case (nil, let end?):
            range = "before \(echo(end))"
        case (let start?, let end?):
            range = "\(echo(start)) → \(echo(end))"
        }

        // The resolved range and zone are echoed so a model can catch its own
        // off-by-one-day before the reader has to.
        let header =
            "\(page.total) screenshot\(page.total == 1 ? "" : "s") · \(range) · "
            + "\(calendar.timeZone.identifier) · newest first"

        guard !page.results.isEmpty else {
            return header + "\nNo screenshots match."
        }

        let stampWidth = page.results.map { stamp($0.creationDate).count }.max() ?? 0
        let sizeWidth = page.results.map { Self.size($0).count }.max() ?? 0

        var lines = [header]
        for screenshot in page.results {
            var line = Self.pad(stamp(screenshot.creationDate), to: stampWidth)
            line += "  " + Self.pad(Self.size(screenshot), to: sizeWidth)
            lines.append(line + "  id=\(screenshot.id)")
        }

        let shown = offset + page.results.count
        if shown < page.total {
            lines.append("…\(page.total - shown) more · call again with offset=\(shown)")
        }
        return lines.joined(separator: "\n")
    }

    /// One block per id, in the order the ids were given.
    ///
    /// The recognised text is printed flush left under its header rather than indented,
    /// because indentation would silently change the content the caller asked for.
    public func extracted(_ results: [TextExtraction]) -> String {
        let readable = results.filter { $0.failure == nil }.count
        var text =
            "Text from \(readable) of \(results.count) screenshot"
            + "\(results.count == 1 ? "" : "s")"

        for result in results {
            var heading = "id=\(result.id)"
            if let screenshot = result.screenshot {
                heading += " · \(stamp(screenshot.creationDate)) · \(Self.size(screenshot))"
            }
            text += "\n\n--- \(heading)\n"

            if let failure = result.failure {
                text += "(cannot read: \(failure))"
            } else if result.lines.isEmpty {
                text += "(no text recognised in this screenshot)"
            } else {
                text += result.lines.joined(separator: "\n")
            }
        }
        return text
    }

    public func status(
        _ authorization: PhotoAuthorization, screenshotCount: Int?, binaryPath: String
    ) -> String {
        let headline: String
        switch authorization {
        case .authorized: headline = "Photos permission: GRANTED (full library)."
        case .limited: headline = "Photos permission: GRANTED for a LIMITED SELECTION only."
        case .denied: headline = "Photos permission: DENIED."
        case .restricted: headline = "Photos permission: RESTRICTED by system policy."
        case .notDetermined: headline = "Photos permission: not requested yet."
        }

        var text = headline + "\n\n"
        // The fixed operating limits, stated here rather than left to be assumed from the
        // README — this is what the running process actually enforces.
        text += Self.block([
            ("binary", binaryPath),
            ("time zone", calendar.timeZone.identifier),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            (
                "in scope",
                screenshotCount.map { "\($0) screenshot\($0 == 1 ? "" : "s") in the album" }
                    ?? "unknown — permission not granted, nothing was counted"
            ),
            ("OCR languages", "Vision automatic detection, not configurable"),
            ("default page size", "\(Configuration.listLimit)"),
            ("ids per extract call", "at most \(Configuration.maximumExtractIDs)"),
        ])

        text += "\n\n" + Self.scopeStatement
        if authorization != .authorized {
            text += "\n\n" + ToolError.authorizationMessage(authorization)
        }
        return text
    }

    /// The paragraph this whole server exists to be honest about. It is printed on every
    /// status call, granted or not, because the thing most worth knowing here is what the
    /// permission covers rather than whether it was given.
    static let scopeStatement = """
        WHAT THE PERMISSION ACTUALLY COVERS

        macOS grants Photos access at the level of the WHOLE LIBRARY. There is no
        screenshots-only permission and no read-only one either: the access level that can
        read is the same level that can write, so the consent dialog asks for more than
        this server uses.

        The narrowing to screenshots is done BY THIS SERVER'S CODE, NOT BY THE OS. There is
        exactly one fetch in the codebase, hard-coded to the Screenshots smart album
        (PHAssetCollectionSubtypeSmartAlbumScreenshots), and ids are resolved inside that
        album, so a photograph cannot be reached even by naming its identifier. That is
        verifiable by reading SystemScreenshotStore.swift — it is short, and it is the only
        file here that talks to Apple — but it is discipline holding the line, not a
        sandbox.

        Two things follow, and both hold regardless of the permission:

          · No image data ever crosses this server's boundary. No file paths, no
            thumbnails, no exports, no base64. Text only.
          · Nothing is ever written. This server makes no change request of any kind, and
            the store protocol has no method that could.
        """
}
