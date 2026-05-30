import Foundation

enum ConfigGenerator {
    /// Produce a starter `config.js` populated with the detected browsers.
    static func starter(_ browsers: [DetectedBrowser]) -> String {
        let allTargets = browsers.flatMap { $0.targets }
        let firstKey = allTargets.first?.key ?? "safari"

        var s = ""
        s += "// brouter config — plain JavaScript, evaluated by JavaScriptCore.\n"
        s += "// Auto-generated \(timestamp()) from the browsers detected on this Mac.\n"
        s += "// Edit freely; brouter reloads on save. See `brouter detect` to re-list browsers.\n"
        s += "//\n"
        s += "// Test without clicking links:\n"
        s += "//   brouter route https://github.com/foo/bar\n"
        s += "//   brouter validate\n\n"

        s += "// --- Browsers / profiles detected on this machine -------------------------\n"
        s += "const browsers = {\n"
        for b in browsers {
            s += "  // \(b.shortName)\n"
            for t in b.targets {
                var fields = ["app: \(js(t.app))"]
                if let p = t.profileDir { fields.append("profile: \(js(p))") }
                if !t.args.isEmpty { fields.append("args: [\(t.args.map(js).joined(separator: ", "))]") }
                fields.append("label: \(js(t.displayName))")
                s += "  \(pad(t.key + ":", 22)) { \(fields.joined(separator: ", ")) },\n"
            }
        }
        s += "};\n\n"

        s += "// --- Routing --------------------------------------------------------------\n"
        s += "// Return a key from `browsers`, an inline { app, profile, args }, or an Ask\n"
        s += "// request like { ask: true } / { ask: [\"key1\", \"key2\"] }.\n"
        s += "function route(url, ctx) {\n"
        s += "  const is = (d) => ctx.host === d || ctx.host.endsWith(\".\" + d);\n\n"
        s += "  // Examples — uncomment and adapt:\n"
        if let work = suggestKey(allTargets, contains: ["work", "profile_1"]) {
            s += "  // if (is(\"github.com\") || is(\"slack.com\")) return \(js(work));\n"
        } else {
            s += "  // if (is(\"github.com\")) return \(js(firstKey));\n"
        }
        s += "  // if (is(\"figma.com\")) return { ask: true };\n"
        s += "  // if (ctx.sourceApp && ctx.sourceApp.bundleId === \"com.tinyspeck.slackmacgap\") return \(js(firstKey));\n\n"
        s += "  // Default for everything else:\n"
        s += "  return \(js(firstKey));\n"
        s += "}\n"
        s += "\n// vim: set ft=javascript ts=2 sw=2 et :\n"
        return s
    }

    private static func suggestKey(_ targets: [DetectedTarget], contains needles: [String]) -> String? {
        for n in needles {
            if let t = targets.first(where: { $0.key.contains(n) }) { return t.key }
        }
        return nil
    }

    private static func js(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
