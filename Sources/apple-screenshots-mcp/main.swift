import Foundation
import ScreenshotsMCPCore

// Launcher only. Everything testable lives in ScreenshotsMCPCore, which the test target
// imports; an executable target cannot be imported.
do {
    // No settings to read: the extension's manifest declares no user_config and passes no
    // arguments, so this server's behaviour is fixed constants plus the per-tool
    // permission switch in Claude Desktop.
    try await ScreenshotsMCPServer.run()
} catch {
    // Exiting 0 here would be indistinguishable from a clean shutdown, which is how a
    // server disappears mid-session with nothing to show for it.
    Diagnostics.fatal(error)
    exit(1)
}
