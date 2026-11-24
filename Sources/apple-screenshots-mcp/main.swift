import Foundation
import ScreenshotsMCPCore

// Launcher only. Everything testable lives in ScreenshotsMCPCore, which the test target
// imports; an executable target cannot be imported.
//
// No settings to read: the extension's manifest declares no user_config and passes no
// arguments, so this server's behaviour is fixed constants plus the per-tool
// permission switch in Claude Desktop.
await ScreenshotsMCPServer.run()
