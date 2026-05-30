import AppKit

/// A single launchable destination discovered on the system: a browser,
/// possibly narrowed to one profile.
struct DetectedTarget {
    var key: String              // suggested config key, e.g. "chrome_work"
    var displayName: String      // "Chrome — Work"
    var profileLabel: String?    // "Work"
    var app: String              // app name for `open`, e.g. "Google Chrome"
    var profileDir: String?      // Chromium --profile-directory
    var args: [String]           // extra args (e.g. Firefox ["-P", "dev"])
    var detail: String? = nil    // extra info for display (e.g. account email)
}

/// A browser installed on the system and its profiles.
struct DetectedBrowser {
    var appName: String
    var shortName: String
    var bundleId: String
    var appPath: String
    var targets: [DetectedTarget]
}

enum BrowserDetector {
    private enum Engine { case chromium, firefox, webkit, other }

    private struct Known {
        let bundleId: String
        let shortName: String
        let engine: Engine
        let supportDir: String?   // relative to ~/Library/Application Support
    }

    // Ordered so the first installed entry makes a sensible default.
    private static let known: [Known] = [
        Known(bundleId: "com.google.Chrome",            shortName: "Chrome",        engine: .chromium, supportDir: "Google/Chrome"),
        Known(bundleId: "com.google.Chrome.beta",       shortName: "Chrome Beta",   engine: .chromium, supportDir: "Google/Chrome Beta"),
        Known(bundleId: "com.google.Chrome.dev",        shortName: "Chrome Dev",    engine: .chromium, supportDir: "Google/Chrome Dev"),
        Known(bundleId: "com.google.Chrome.canary",     shortName: "Chrome Canary", engine: .chromium, supportDir: "Google/Chrome Canary"),
        Known(bundleId: "com.apple.Safari",             shortName: "Safari",        engine: .webkit,   supportDir: nil),
        Known(bundleId: "com.microsoft.edgemac",        shortName: "Edge",          engine: .chromium, supportDir: "Microsoft Edge"),
        Known(bundleId: "com.brave.Browser",            shortName: "Brave",         engine: .chromium, supportDir: "BraveSoftware/Brave-Browser"),
        Known(bundleId: "com.brave.Browser.beta",       shortName: "Brave Beta",    engine: .chromium, supportDir: "BraveSoftware/Brave-Browser-Beta"),
        Known(bundleId: "com.vivaldi.Vivaldi",          shortName: "Vivaldi",       engine: .chromium, supportDir: "Vivaldi"),
        Known(bundleId: "org.chromium.Chromium",        shortName: "Chromium",      engine: .chromium, supportDir: "Chromium"),
        Known(bundleId: "company.thebrowser.Browser",   shortName: "Arc",           engine: .other,    supportDir: nil),
        Known(bundleId: "company.thebrowser.dia",       shortName: "Dia",           engine: .other,    supportDir: nil),
        Known(bundleId: "org.mozilla.firefox",          shortName: "Firefox",       engine: .firefox,  supportDir: "Firefox"),
        Known(bundleId: "org.mozilla.firefoxdeveloperedition", shortName: "Firefox Dev", engine: .firefox, supportDir: "Firefox"),
        Known(bundleId: "com.operasoftware.Opera",      shortName: "Opera",         engine: .other,    supportDir: nil),
        Known(bundleId: "com.kagi.kagimacOS",           shortName: "Orion",         engine: .webkit,   supportDir: nil),
    ]

    static func detect() -> [DetectedBrowser] {
        let ws = NSWorkspace.shared
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        var browsers: [DetectedBrowser] = []
        for k in known {
            guard let appURL = ws.urlForApplication(withBundleIdentifier: k.bundleId) else { continue }
            let appName = appURL.deletingPathExtension().lastPathComponent

            var targets: [DetectedTarget]
            switch k.engine {
            case .chromium:
                let dir = k.supportDir.map { support.appendingPathComponent($0) }
                targets = dir.map { chromiumProfiles(userDataDir: $0, appName: appName, shortName: k.shortName) } ?? []
                if targets.isEmpty {
                    targets = [DetectedTarget(key: "", displayName: k.shortName, profileLabel: nil,
                                              app: appName, profileDir: "Default", args: [])]
                }
            case .firefox:
                let dir = k.supportDir.map { support.appendingPathComponent($0) }
                targets = dir.map { firefoxProfiles(profileRoot: $0, appName: appName, shortName: k.shortName) } ?? []
                if targets.isEmpty {
                    targets = [DetectedTarget(key: "", displayName: k.shortName, profileLabel: nil,
                                              app: appName, profileDir: nil, args: [])]
                }
            case .webkit, .other:
                targets = [DetectedTarget(key: "", displayName: k.shortName, profileLabel: nil,
                                          app: appName, profileDir: nil, args: [])]
            }

            browsers.append(DetectedBrowser(appName: appName, shortName: k.shortName,
                                            bundleId: k.bundleId, appPath: appURL.path, targets: targets))
        }
        assignKeys(&browsers)
        return browsers
    }

    /// Flat list of every detected target (with unique keys assigned).
    static func detectTargets() -> [DetectedTarget] {
        detect().flatMap { $0.targets }
    }

    // MARK: - Chromium

    private static func chromiumProfiles(userDataDir: URL, appName: String, shortName: String) -> [DetectedTarget] {
        let localState = userDataDir.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any], !cache.isEmpty else {
            return []
        }
        // Respect the user's profile order if present, then append any extras.
        let order = (profile["profiles_order"] as? [String])?.filter { cache[$0] != nil } ?? []
        var dirs = order
        dirs += cache.keys.filter { !dirs.contains($0) }.sorted { a, b in
            if a == "Default" { return true }
            if b == "Default" { return false }
            return a < b
        }

        return dirs.compactMap { dir in
            guard let info = cache[dir] as? [String: Any] else { return nil }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dir
            var email = info["user_name"] as? String
            if let e = email, e.isEmpty || e == name { email = nil }
            return DetectedTarget(key: "", displayName: "\(shortName) — \(name)",
                                  profileLabel: name, app: appName, profileDir: dir, args: [], detail: email)
        }
    }

    // MARK: - Firefox

    private static func firefoxProfiles(profileRoot: URL, appName: String, shortName: String) -> [DetectedTarget] {
        let ini = profileRoot.appendingPathComponent("profiles.ini")
        guard let text = try? String(contentsOf: ini, encoding: .utf8) else { return [] }

        var names: [String] = []
        var current: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = line.lowercased()
                continue
            }
            guard let section = current, section.hasPrefix("[profile") else { continue }
            if line.lowercased().hasPrefix("name=") {
                let name = String(line.dropFirst("name=".count)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.append(name) }
            }
        }

        return names.map { name in
            DetectedTarget(key: "", displayName: "\(shortName) — \(name)", profileLabel: name,
                           app: appName, profileDir: nil, args: ["-P", name])
        }
    }

    // MARK: - Keys

    private static func assignKeys(_ browsers: inout [DetectedBrowser]) {
        var used = Set<String>()
        for bi in browsers.indices {
            for ti in browsers[bi].targets.indices {
                let t = browsers[bi].targets[ti]
                let base = t.profileLabel.map { "\(browsers[bi].shortName) \($0)" } ?? browsers[bi].shortName
                var key = slug(base)
                if key.isEmpty { key = "browser" }
                var unique = key
                var n = 2
                while used.contains(unique) { unique = "\(key)_\(n)"; n += 1 }
                used.insert(unique)
                browsers[bi].targets[ti].key = unique
            }
        }
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastUnderscore = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_"); lastUnderscore = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
