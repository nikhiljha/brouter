import Foundation
import JavaScriptCore

/// Loads and evaluates the user's `config.js`, exposing routing decisions.
///
/// The config defines two globals:
///   - `browsers`: an object mapping a key to `{ app, profile?, args?, label? }`
///   - `route(url, ctx)`: a function returning a routing decision
final class Router {
    let configURL: URL

    private var context: JSContext?
    private var lastModified: Date?
    private(set) var lastError: String?
    private(set) var schemes: [String] = []

    init(configURL: URL) {
        self.configURL = configURL
    }

    // MARK: - Loading

    /// Reload the config if it changed on disk (or has never been loaded).
    func reloadIfNeeded() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate]) as? Date
        if context != nil, let mtime, let lastModified, mtime <= lastModified {
            return
        }
        load()
        lastModified = mtime
    }

    /// Force a reload of the config from disk.
    @discardableResult
    func load() -> Bool {
        lastError = nil
        schemes = []
        guard let source = try? String(contentsOf: configURL, encoding: .utf8) else {
            lastError = "Could not read config at \(configURL.path)"
            context = nil
            return false
        }

        let ctx = JSContext()!
        ctx.exceptionHandler = { [weak self] _, exception in
            let msg = exception?.toString() ?? "unknown JS error"
            self?.lastError = msg
            FileHandle.standardError.write(Data("[brouter] JS error: \(msg)\n".utf8))
        }
        installConsole(in: ctx)

        ctx.evaluateScript(source, withSourceURL: configURL)
        if lastError == nil {
            let value = ctx.evaluateScript("typeof schemes === 'undefined' ? [] : schemes")
            if let value, value.isArray, let raw = value.toArray() as? [String] {
                do {
                    schemes = try URLSchemes.normalize(raw)
                } catch {
                    lastError = error.localizedDescription
                }
            } else {
                lastError = "schemes must be an array of URL scheme names"
            }
        }
        if let err = lastError {
            FileHandle.standardError.write(Data("[brouter] config failed to load: \(err)\n".utf8))
            context = nil
            return false
        }
        context = ctx
        return true
    }

    private func installConsole(in ctx: JSContext) {
        let logger: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() ?? []
            let parts = args.compactMap { ($0 as? JSValue)?.toString() }
            FileHandle.standardError.write(Data("[brouter:js] \(parts.joined(separator: " "))\n".utf8))
        }
        let console = JSValue(newObjectIn: ctx)
        console?.setObject(logger, forKeyedSubscript: "log" as NSString)
        console?.setObject(logger, forKeyedSubscript: "warn" as NSString)
        console?.setObject(logger, forKeyedSubscript: "error" as NSString)
        console?.setObject(logger, forKeyedSubscript: "info" as NSString)
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)
        ctx.setObject(logger, forKeyedSubscript: "log" as NSString)
    }

    // MARK: - Browsers

    /// All browsers defined in config, in declaration order.
    ///
    /// Note: `const`/`let browsers` is a lexical binding, not a property of the
    /// global object, so we must read it via `evaluateScript` (which sees the
    /// global lexical scope) rather than `objectForKeyedSubscript`.
    func allBrowsers() -> [BrowserTarget] {
        guard let ctx = context else { return [] }
        let guarded = "((typeof browsers !== 'undefined' && browsers) ? browsers : null)"
        guard let browsersVal = ctx.evaluateScript(guarded), browsersVal.isObject else { return [] }
        guard let keysVal = ctx.evaluateScript("Object.keys(\(guarded) || {})"),
              let keys = keysVal.toArray() as? [String] else { return [] }
        return keys.compactMap { key in
            guard let v = browsersVal.objectForKeyedSubscript(key) else { return nil }
            return parseTarget(v, key: key)
        }
    }

    private func browserMap() -> [String: BrowserTarget] {
        var map: [String: BrowserTarget] = [:]
        for t in allBrowsers() { if let k = t.key { map[k] = t } }
        return map
    }

    // MARK: - Routing

    func route(url: String, sourceApp: SourceApp?) -> RouteDecision {
        reloadIfNeeded()
        guard let ctx = context else { return .none }
        // `route` may be a function declaration or a `const`/`let` arrow, so
        // resolve it through the lexical scope.
        guard let routeFn = ctx.evaluateScript("typeof route === 'function' ? route : null"),
              routeFn.isObject else {
            FileHandle.standardError.write(Data("[brouter] config has no route() function\n".utf8))
            return .none
        }

        let result = routeFn.call(withArguments: [url, contextObject(for: url, sourceApp: sourceApp)])
        guard let result, !result.isUndefined, !result.isNull else { return .none }
        return decision(from: result, url: url)
    }

    /// Build the `ctx` object passed as the 2nd argument to `route()`.
    private func contextObject(for url: String, sourceApp: SourceApp?) -> [String: Any] {
        var d: [String: Any] = ["url": url]
        if let comps = URLComponents(string: url) {
            d["scheme"] = comps.scheme?.lowercased() ?? NSNull()
            d["host"] = comps.host ?? ""
            d["hostname"] = comps.host ?? ""
            d["port"] = comps.port ?? NSNull()
            d["path"] = comps.path
            d["pathname"] = comps.path
            d["hash"] = comps.fragment ?? NSNull()
            d["username"] = comps.user ?? NSNull()
            d["search"] = comps.percentEncodedQuery ?? NSNull()
            var query: [String: Any] = [:]
            for item in comps.queryItems ?? [] { query[item.name] = item.value ?? NSNull() }
            d["query"] = query
        }
        d["sourceApp"] = sourceApp?.jsObject ?? NSNull()
        return d
    }

    // MARK: - Decision parsing

    private func decision(from value: JSValue, url: String) -> RouteDecision {
        if value.isString {
            let s = value.toString() ?? ""
            return .open(resolve(key: s))
        }
        if value.isBoolean || value.isNumber { return .none }
        if value.isObject {
            if isCopy(value) { return .copy }
            let askVal = value.objectForKeyedSubscript("ask")
            if let askVal, !askVal.isUndefined {
                return .ask(buildAsk(askVal, url: url))
            }
            if let target = parseTarget(value, key: nil) {
                return .open(target)
            }
            // { browser: "key" }
            if let b = value.objectForKeyedSubscript("browser"), b.isString {
                return .open(resolve(key: b.toString() ?? ""))
            }
        }
        return .none
    }

    private func buildAsk(_ askVal: JSValue, url: String) -> AskRequest {
        var options: [RouteOption] = []
        var message: String?
        var defaultIndex: Int?

        func optionsFromArray(_ v: JSValue) -> [RouteOption] {
            guard let raw = v.toArray() else { return [] }
            var out: [RouteOption] = []
            for (i, _) in raw.enumerated() {
                if let item = v.atIndex(i), let option = resolveOption(item) { out.append(option) }
            }
            return out
        }

        if askVal.isArray {
            options = optionsFromArray(askVal)
        } else if askVal.isObject {
            if let optsVal = askVal.objectForKeyedSubscript("options"), optsVal.isArray {
                options = optionsFromArray(optsVal)
            }
            if let m = askVal.objectForKeyedSubscript("message"), m.isString { message = m.toString() }
            if let d = askVal.objectForKeyedSubscript("default"), !d.isUndefined, !d.isNull {
                if d.isNumber {
                    defaultIndex = Int(d.toInt32())
                } else if d.isString {
                    let key = d.toString() ?? ""
                    defaultIndex = options.firstIndex { $0.matches(key: key) }
                }
            }
        }
        // `ask: true` / `ask: "all"` / empty -> all defined browsers.
        if options.isEmpty { options = allBrowsers().map(RouteOption.browser) }
        return AskRequest(url: url, options: options, message: message, defaultIndex: defaultIndex)
    }

    /// Resolve a route option that may be a string key or an inline object.
    /// Returns nil for values that aren't a valid option.
    private func resolveOption(_ v: JSValue) -> RouteOption? {
        if v.isObject, isCopy(v) { return .copy }
        if v.isString { return .browser(resolve(key: v.toString() ?? "")) }
        if v.isObject, let t = parseTarget(v, key: nil) { return .browser(t) }
        if v.isObject, let b = v.objectForKeyedSubscript("browser"), b.isString {
            return .browser(resolve(key: b.toString() ?? ""))
        }
        return nil
    }

    private func isCopy(_ value: JSValue) -> Bool {
        guard let copy = value.objectForKeyedSubscript("copy") else { return false }
        return copy.isBoolean && copy.toBool()
    }

    /// Resolve a string returned by route(): a key into `browsers`, or an app name.
    private func resolve(key: String) -> BrowserTarget {
        if let t = browserMap()[key] { return t }
        return BrowserTarget(app: key)
    }

    /// Parse a JS object (or string) into a BrowserTarget.
    private func parseTarget(_ v: JSValue, key: String?) -> BrowserTarget? {
        if v.isString {
            return BrowserTarget(app: v.toString() ?? "", key: key)
        }
        guard v.isObject else { return nil }
        guard let appVal = v.objectForKeyedSubscript("app"), appVal.isString, let app = appVal.toString(), !app.isEmpty else {
            return nil
        }
        var profile: String?
        if let p = v.objectForKeyedSubscript("profile"), p.isString { profile = p.toString() }
        var label: String?
        if let l = v.objectForKeyedSubscript("label"), l.isString { label = l.toString() }
        var args: [String] = []
        if let a = v.objectForKeyedSubscript("args"), a.isArray, let raw = a.toArray() {
            args = raw.compactMap { $0 as? String }
        }
        return BrowserTarget(app: app, profile: profile, args: args, label: label, key: key)
    }
}
