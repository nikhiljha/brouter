import Foundation

enum URLSchemes {
    enum ConfigurationError: LocalizedError {
        case invalidScheme
        case invalidBundle

        var errorDescription: String? {
            switch self {
            case .invalidScheme:
                return "Each scheme must start with an ASCII letter and contain only letters, digits, +, - or . (no : or /)."
            case .invalidBundle:
                return "Expected a brouter.app bundle with a valid Info.plist."
            }
        }
    }

    static func normalize(_ schemes: [String]) throws -> [String] {
        var result: [String] = []
        for scheme in schemes {
            guard scheme.range(of: "\\A[A-Za-z][A-Za-z0-9+.-]*\\z", options: .regularExpression) != nil else {
                throw ConfigurationError.invalidScheme
            }
            let normalized = scheme.lowercased()
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }

    static func configureBundle(at appURL: URL, schemes: [String]) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard appURL.pathExtension == "app",
              var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "com.nikhiljha.brouter" else {
            throw ConfigurationError.invalidBundle
        }
        var types = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        types.removeAll { $0["CFBundleURLName"] as? String == "brouter configured schemes" }
        let declared = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() }
        let extra = try normalize(schemes).filter { !declared.contains($0) }
        if !extra.isEmpty {
            types.append([
                "CFBundleURLName": "brouter configured schemes",
                "CFBundleTypeRole": "Viewer",
                "CFBundleURLSchemes": extra
            ])
        }
        plist["CFBundleURLTypes"] = types
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: plistURL, options: .atomic)
    }
}
