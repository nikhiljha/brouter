import AppKit
import XCTest
@testable import brouter

final class RouterTests: XCTestCase {
    private func withDirectory(test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    private func withRouter(_ source: String, test: (Router) throws -> Void) throws {
        try withDirectory { directory in
            let config = directory.appendingPathComponent("config.js")
            try source.write(to: config, atomically: true, encoding: .utf8)
            try test(Router(configURL: config))
        }
    }

    func testPickerResolvesCopyAndExplicitAppWithoutLosingURL() throws {
        try withRouter("""
        const browsers = { primary: { app: "Google Chrome", profile: "Default", label: "Primary" } };
        function route(url, ctx) {
          return { ask: { options: ["primary", { copy: true }, { app: "com.example.handler", label: "Example App" }], default: "primary" } };
        }
        """) { router in
            let url = "exampleapp://synthetic-callback?value=a%2Bb%26c#fragment"
            guard case .ask(let request) = router.route(url: url, sourceApp: nil) else {
                return XCTFail("Expected an Ask request")
            }
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.options.map(\.displayName), ["Primary", "Copy URL", "Example App"])
            XCTAssertEqual(request.defaultIndex, 0)
            XCTAssertEqual(request.options[1], .copy)
            guard case .browser(let target) = request.options[2] else { return XCTFail("Expected Example App") }
            XCTAssertEqual(BrowserLauncher.openArguments(for: target, url: url), ["-b", "com.example.handler", url])
        }
    }

    func testCopyRequiresBooleanTrueAndReceivesCustomURLContext() throws {
        try withRouter("""
        const route = (url, ctx) => ({ copy: ctx.scheme === "custom+test" && ctx.url === url && ctx.query.value === "a+b&c" });
        """) { router in
            guard case .copy = router.route(url: "CUSTOM+TEST:callback?value=a%2Bb%26c", sourceApp: nil) else {
                return XCTFail("Expected copy with normalized scheme and decoded query")
            }
            guard case .none = router.route(url: "custom+test:callback?value=other", sourceApp: nil) else {
                return XCTFail("copy: false must not copy")
            }
        }
        for value in ["\"true\"", "1", "null"] {
            try withRouter("function route() { return { copy: \(value) }; }") { router in
                guard case .none = router.route(url: "custom:synthetic", sourceApp: nil) else {
                    return XCTFail("Only a boolean true should copy")
                }
            }
        }
    }

    func testExistingBrowserRoutesAndAskOptionsRemainCompatible() throws {
        try withRouter("""
        const browsers = { primary: { app: "Google Chrome", profile: "Default" }, safari: { app: "Safari" } };
        function route(url, ctx) {
          if (ctx.path === "/all") return { ask: true };
          if (ctx.path === "/options") return { ask: { options: [{ browser: "primary" }, { copy: true }], default: 1 } };
          if (ctx.path === "/string") return "primary";
          if (ctx.path === "/inline") return { app: "Safari" };
          return { browser: "primary" };
        }
        """) { router in
            let chrome = BrowserTarget(app: "Google Chrome", profile: "Default", key: "primary")
            for url in ["https://example.test/string", "other://example.test/reference"] {
                guard case .open(let target) = router.route(url: url, sourceApp: nil) else { return XCTFail("Expected browser") }
                XCTAssertEqual(target, chrome)
                XCTAssertEqual(BrowserLauncher.openArguments(for: target, url: url), ["-n", "-a", "Google Chrome", "--args", "--profile-directory=Default", url])
            }
            guard case .open(let inline) = router.route(url: "https://example.test/inline", sourceApp: nil) else { return XCTFail("Expected inline target") }
            XCTAssertEqual(inline.app, "Safari")
            guard case .ask(let all) = router.route(url: "https://example.test/all", sourceApp: nil) else { return XCTFail("Expected all browsers") }
            XCTAssertEqual(all.options, [.browser(chrome), .browser(BrowserTarget(app: "Safari", key: "safari"))])
            guard case .ask(let options) = router.route(url: "https://example.test/options", sourceApp: nil) else { return XCTFail("Expected options") }
            XCTAssertEqual(options.options, [.browser(chrome), .copy])
            XCTAssertEqual(options.defaultIndex, 1)
        }
    }

    func testSchemeConfigurationIsOptionalNormalizedAndStrict() throws {
        for (source, expected) in [("", []), ("const schemes = ['ExampleApp', 'exampleapp', 'exampleapp2', 'custom+v1.2-test'];", ["exampleapp", "exampleapp2", "custom+v1.2-test"])] {
            try withRouter(source) { router in
                XCTAssertTrue(router.load())
                XCTAssertEqual(router.schemes, expected)
            }
        }
        for value in ["null", "'custom'", "['custom', 1]", "['']", "['1custom']", "['custom://']", "['custom:']", "[' custom']", "['custom\\n']", "['cüstom']"] {
            try withRouter("const schemes = \(value);") { router in
                XCTAssertFalse(router.load(), value)
                XCTAssertNotNil(router.lastError)
                XCTAssertTrue(router.schemes.isEmpty)
            }
        }
    }

    func testAppURLResolvesNamesBundleIDsAndPaths() {
        for (app, bundleId) in [("Safari", "com.apple.Safari"), ("Terminal", "com.apple.Terminal"), ("com.apple.Safari", "com.apple.Safari")] {
            let url = BrowserLauncher.appURL(for: app)
            XCTAssertEqual(url.flatMap { Bundle(url: $0)?.bundleIdentifier }, bundleId, app)
        }
        XCTAssertNotNil(BrowserLauncher.appURL(for: "/System/Applications/Utilities/Terminal.app"))
        XCTAssertNil(BrowserLauncher.appURL(for: "No Such App \(UUID().uuidString)"))
    }

    func testCopyReplacesPasteboardContentsWithOriginalURL() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("brouter-tests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old rich text", forType: .html)
        let url = "exampleapp2://synthetic-callback?value=a%2Bb%26c#fragment"
        XCTAssertTrue(RouteActions.copy(url, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), url)
        XCTAssertNil(pasteboard.string(forType: .html))
    }

    func testBundleSchemesReplaceOnlyManagedDeclarations() throws {
        try withDirectory { directory in
            let app = directory.appendingPathComponent("brouter.app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plistURL = contents.appendingPathComponent("Info.plist")
            let original: [String: Any] = [
                "CFBundleIdentifier": "com.nikhiljha.brouter",
                "LSUIElement": true,
                "CFBundleURLTypes": [["CFBundleURLName": "web", "CFBundleURLSchemes": ["http", "https"]]]
            ]
            try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: plistURL)
            for schemes in [["HTTP", "exampleapp", "EXAMPLEAPP", "exampleapp2"], ["other"], []] {
                try URLSchemes.configureBundle(at: app, schemes: schemes)
                let data = try Data(contentsOf: plistURL)
                let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
                let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
                let declared = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
                XCTAssertEqual(declared, try URLSchemes.normalize(["http", "https"] + schemes))
                XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
                XCTAssertEqual(types.first?["CFBundleURLName"] as? String, "web")
            }
            let before = try Data(contentsOf: plistURL)
            XCTAssertThrowsError(try URLSchemes.configureBundle(at: app, schemes: ["bad://"]))
            XCTAssertEqual(try Data(contentsOf: plistURL), before)
        }
    }
}
