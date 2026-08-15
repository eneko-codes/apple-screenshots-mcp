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
    /// Default page size for `screenshots_list`. The tool's own `limit` still wins.
    public static let listLimit = 50

    /// Ceiling on how many ids one `screenshot_extract_text` call may take. OCR decodes
    /// each screenshot at full resolution, so a batch is slow rather than free.
    public static let maximumExtractIDs = 10

    public static let listLimitRange = 1...200
    public static let extractIDsRange = 1...50

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...100_000
}
