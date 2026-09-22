import Foundation

enum Config {
    static let bundleIdentifier = "com.nikhiljha.brouter"
    /// Canonical location (standard macOS app settings dir).
    static let canonical = NSString(string: "~/Library/Application Support/brouter/config.js").expandingTildeInPath
    /// Alternative for the XDG-inclined.
    static let xdgConfig = NSString(string: "~/.config/brouter/config.js").expandingTildeInPath

    /// Resolve the config file path. Resolution order:
    ///   1. $BROUTER_CONFIG
    ///   2. ~/Library/Application Support/brouter/config.js   (canonical)
    ///   3. ~/.config/brouter/config.js
    /// Falls back to the canonical path if none exist yet.
    static func resolveURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["BROUTER_CONFIG"], !env.isEmpty {
            return URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: canonical) { return URL(fileURLWithPath: canonical) }
        if fm.fileExists(atPath: xdgConfig) { return URL(fileURLWithPath: xdgConfig) }
        return URL(fileURLWithPath: canonical)
    }

    /// Ensure a config file exists, generating a starter (populated with the
    /// browsers detected on this Mac) at the canonical path if not.
    /// Returns the resolved config URL.
    @discardableResult
    static func ensureExists() -> URL {
        let url = resolveURL()
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return writeStarter(to: url)
    }

    /// Write a freshly generated starter config to `url`.
    @discardableResult
    static func writeStarter(to url: URL) -> URL {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = ConfigGenerator.starter(BrowserDetector.detect())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("[brouter] wrote starter config: \(url.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[brouter] failed to write starter config: \(error)\n".utf8))
        }
        return url
    }
}
