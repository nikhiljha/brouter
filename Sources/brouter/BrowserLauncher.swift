import AppKit

enum BrowserLauncher {
    /// Build the argument vector passed to `/usr/bin/open` for a target+url.
    static func openArguments(for target: BrowserTarget, url: String) -> [String] {
        var args: [String] = []

        // How to identify the app to `open`.
        let appSpec = appSpecifier(target.app)

        let needsArgs = target.profile != nil || !target.args.isEmpty
        if needsArgs {
            // New instance routing so we can pass --args (Chrome de-dupes itself).
            args += ["-n"]
        }
        args += appSpec

        if needsArgs {
            args += ["--args"]
            if let profile = target.profile, !profile.isEmpty {
                args += ["--profile-directory=\(profile)"]
            }
            args += target.args
            args += [url]
        } else {
            args += [url]
        }
        return args
    }

    /// Returns the `open` flag pair identifying the application.
    /// - "/Applications/Foo.app" or contains "/" or ends ".app" -> -a <path>
    /// - looks like a bundle id (dotted, no spaces) -> -b <id>
    /// - otherwise an app name -> -a <name>
    private static func appSpecifier(_ app: String) -> [String] {
        if app.hasSuffix(".app") || app.contains("/") {
            return ["-a", app]
        }
        if app.contains("."), !app.contains(" ") {
            return ["-b", app]
        }
        return ["-a", app]
    }

    /// Launch the URL in the given target. Returns true on success.
    @discardableResult
    static func launch(_ target: BrowserTarget, url: String) -> Bool {
        // Fast path: hand off to an already-running Chrome via its singleton
        // socket. This avoids exec'ing a throwaway browser process, so there's
        // no Dock bounce and nothing for an on-exec AV/EDR scan to stall on.
        // Falls through to `open` on any miss (browser not running, etc.).
        if SingletonNotifier.tryNotify(target, url: url) {
            return true
        }

        let args = openArguments(for: target, url: url)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = args
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let ok = proc.terminationStatus == 0
            if !ok {
                FileHandle.standardError.write(Data("[brouter] open exited \(proc.terminationStatus) for \(target.displayName)\n".utf8))
            }
            return ok
        } catch {
            FileHandle.standardError.write(Data("[brouter] failed to launch open: \(error)\n".utf8))
            return false
        }
    }

    // MARK: - App resolution

    /// Resolve a target's app (path, bundle id, or name) to a file URL on disk.
    static func appURL(for app: String) -> URL? {
        let fm = FileManager.default
        if app.hasSuffix(".app") || app.contains("/") {
            return fm.fileExists(atPath: app) ? URL(fileURLWithPath: app).resolvingSymlinksInPath() : nil
        }
        if app.contains("."), !app.contains(" ") {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
        }
        // Resolve symlinks (e.g. /Applications/Safari.app) so icons don't get an alias badge.
        let dirs = ["/Applications", "~/Applications", "/System/Applications", "/System/Applications/Utilities"]
        return dirs.lazy
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).appendingPathComponent("\(app).app") }
            .first { fm.fileExists(atPath: $0.path) }?
            .resolvingSymlinksInPath()
    }

    /// Icon for a target's app, or a generic application icon.
    static func icon(for target: BrowserTarget) -> NSImage {
        if let url = appURL(for: target.app) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
