import Foundation

/// Fixed limits for this server.
///
/// These used to be settings the person installing the extension could change, arriving as
/// command-line arguments substituted from `user_config` in the manifest. The owner's
/// plug-and-play rule removed that surface entirely: `extension/manifest.json` declares no
/// `user_config` and passes no arguments, so the only thing left to control this server's
/// behaviour is the per-tool allow/ask/prohibit switch in Claude Desktop.
///
/// OCR language recognition followed the same rule but landed differently. Rather than
/// freezing a language list here, Vision is left to auto-detect on every call — there is no
/// constant for it, because there is nothing to hold. `SystemScreenshotStore` never sets
/// `VNRecognizeTextRequest.recognitionLanguages` at all.
///
/// There is deliberately no setting for *what* this server may read. The scope is one
/// smart album, fixed in code; making it configurable would turn a guarantee into a
/// preference.
public enum Configuration {
    /// Default page size for `screenshots_list`. Each row is one line of about a hundred
    /// characters, so this is well under `ToolStandard.usualPage`.
    public static let listLimit = 50

    /// The most rows one page may hold. 200 rows of the widest ordinary width are about
    /// 20,000 characters, inside `ToolStandard.longestResult`; `BoundsTests` renders them.
    public static let listLimitRange = 1...200

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000_000

    /// Ceiling on how many ids one `screenshot_extract_text` call may take. OCR decodes
    /// each screenshot at full resolution, so a batch is slow rather than free.
    public static let maximumExtractIDs = 10
    public static let extractIDsRange = 1...maximumExtractIDs

    /// The window on the recognised text of each screenshot. The maximum is half the
    /// longest result, so one screenshot's window of ordinary text leaves room for the
    /// rest of the answer; `ToolStandard.fitting` shrinks a window when several
    /// screenshots, or characters that take several UTF-16 units each, would not fit.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)

    /// What a call with no `max_characters` aims to return in all: a usual page of text,
    /// shared by the screenshots asked for, so that a call is about one usual page whether
    /// it names one id or ten.
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// The window each screenshot gets when `max_characters` is not given.
    public static func defaultWindow(forIDs count: Int) -> Int {
        Swift.max(defaultMaxCharacters / Swift.max(count, 1), maxCharactersRange.lowerBound)
    }

    /// How long a call may run before it is answered with what it has. It stays well under
    /// the 60 seconds a client commonly waits, and so under `ToolStandard.timeLimit`, so
    /// the answer is ours and not the client's generic "no result".
    public static let timeout = Duration.seconds(45)
}
