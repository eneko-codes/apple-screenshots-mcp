import Foundation

/// `PHAuthorizationStatus` for the `.readWrite` access level, which is the only level
/// that can read anything: `.addOnly` grants writing and nothing else.
///
/// That asymmetry is worth stating plainly, because it is the reason the consent dialog
/// asks for more than this server uses. There is no read-only Photos permission on macOS,
/// so a server that reads must hold the level that also allows writing. This one never
/// writes — it makes no `PHAssetChangeRequest` at all, and the seam has no method that
/// could.
public enum PhotoAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    /// macOS 15+. The person chose a subset of the library, so the Screenshots album is
    /// visible only in part. Usable, but every answer built on it has to say so.
    case limited
    case authorized

    public var isUsable: Bool { self == .authorized || self == .limited }
}

public enum ToolError: Error, Equatable {
    case notAuthorized(PhotoAuthorization)
    case albumMissing
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case endBeforeStart
    case tooManyIDs(count: Int, maximum: Int)
    case storeFailure(String)

    public var message: String {
        switch self {
        case .notAuthorized(let status):
            return Self.authorizationMessage(status)

        case .albumMissing:
            return """
                macOS reports no Screenshots album in this photo library.

                The album is a smart album Photos maintains by itself, and it only appears
                once the library contains at least one screenshot. Screenshots taken with
                ⌘⇧3 or ⌘⇧4 land on the Desktop as ordinary files and never reach Photos —
                only screenshots imported from an iPhone or iPad, or added to Photos by
                hand, appear here.

                This server has no other way in: it reads that album and nothing else.
                """

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use one of:
                \(DateParsing.acceptedForms)
                """

        case .endBeforeStart:
            return "'to' is before 'from'. A date range cannot end before it begins."

        case .tooManyIDs(let count, let maximum):
            return """
                \(count) ids were given; this server extracts text from at most \(maximum) \
                per call.

                OCR decodes each screenshot at full resolution and runs a recognition pass
                over it, so a large batch is slow rather than free. Split the list and call
                again, or narrow it with screenshots_list first.
                """

        case .storeFailure(let detail):
            return "Photos returned an error: \(detail)"
        }
    }

    static func authorizationMessage(_ status: PhotoAuthorization) -> String {
        switch status {
        case .authorized:
            return "Photos access granted (full library)."

        case .limited:
            return """
                Photos access is granted for a LIMITED SELECTION, not the whole library.

                Only the assets picked in that selection are visible, so the Screenshots
                album will look emptier than it is and a screenshot you can see in Photos
                may simply not be reachable here.

                Widen it in:
                  System Settings → Privacy & Security → Photos → "apple-screenshots-mcp" → Full Access
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Fotos)
                """

        case .notDetermined:
            return """
                No Photos access: macOS has not asked yet.

                Restart Claude Desktop and call this tool again; the consent dialog should
                appear.

                If it does not, check that the binary still carries its embedded Info.plist:
                  otool -P .build/release/apple-screenshots-mcp | grep NSPhotoLibrary
                """

        case .denied:
            return """
                No Photos access: it is denied.

                Grant it in:
                  System Settings → Privacy & Security → Photos → enable "apple-screenshots-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Fotos)

                Then restart Claude Desktop: the permission is resolved when the process
                starts.

                Note what that switch actually grants: access to the WHOLE library. macOS
                has no screenshots-only permission. This server narrows the scope to one
                smart album in its own code, which is discipline rather than a sandbox.
                """

        case .restricted:
            return """
                No Photos access: restricted by a system policy (parental controls or a
                device management profile).

                This cannot be granted from System Settings; the policy imposing it has to
                be lifted.
                """
        }
    }
}
