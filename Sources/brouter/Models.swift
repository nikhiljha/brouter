import Foundation

/// A concrete place to send a URL: an application, optionally a Chromium
/// `--profile-directory`, plus any extra command-line arguments.
struct BrowserTarget: Equatable {
    /// App name ("Google Chrome"), bundle id ("com.google.Chrome"),
    /// or full path ("/Applications/Foo.app").
    var app: String
    /// Chromium profile directory name, e.g. "Default" or "Profile 1".
    var profile: String?
    /// Extra arguments passed to the app (Chromium / Firefox flags, etc.).
    var args: [String]
    /// Display label shown in the Ask dialog. Falls back to key/app.
    var label: String?
    /// The key this target was defined under in `browsers`, if any.
    var key: String?

    init(app: String, profile: String? = nil, args: [String] = [], label: String? = nil, key: String? = nil) {
        self.app = app
        self.profile = profile
        self.args = args
        self.label = label
        self.key = key
    }

    /// Human-friendly name for UI.
    var displayName: String {
        if let label, !label.isEmpty { return label }
        if let key, !key.isEmpty {
            if let profile, !profile.isEmpty { return "\(key)" }
            return key
        }
        if let profile, !profile.isEmpty { return "\(app) — \(profile)" }
        return app
    }
}

/// A request to ask the user which target to use.
struct AskRequest {
    var url: String
    var options: [RouteOption]
    var message: String?
    var defaultIndex: Int?
}

/// The result of evaluating the JS `route()` function for a URL.
enum RouteDecision {
    /// Open immediately in the given target.
    case open(BrowserTarget)
    /// Ask the user to pick among options.
    case ask(AskRequest)
    /// No route; the agent falls back to the first browser or Safari.
    case none
    /// Copy the URL to the clipboard.
    case copy
}

enum RouteOption: Equatable {
    case browser(BrowserTarget)
    case copy

    var displayName: String {
        switch self {
        case .browser(let target): return target.displayName
        case .copy: return "Copy URL"
        }
    }

    func matches(key: String) -> Bool {
        switch self {
        case .browser(let target): return target.key == key || target.app == key
        case .copy: return false
        }
    }
}

/// Best-effort info about the app that requested the URL be opened.
struct SourceApp {
    var name: String?
    var bundleId: String?
    var path: String?

    var jsObject: [String: Any] {
        var d: [String: Any] = [:]
        d["name"] = name ?? NSNull()
        d["bundleId"] = bundleId ?? NSNull()
        d["path"] = path ?? NSNull()
        return d
    }
}
