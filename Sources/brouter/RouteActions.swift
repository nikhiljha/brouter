import AppKit

enum RouteActions {
    @discardableResult
    static func perform(_ option: RouteOption, url: String) -> Bool {
        switch option {
        case .browser(let target): return BrowserLauncher.launch(target, url: url)
        case .copy: return copy(url)
        }
    }

    @discardableResult
    static func copy(_ url: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let copied = pasteboard.setString(url, forType: .string)
        if !copied {
            FileHandle.standardError.write(Data("[brouter] failed to copy URL\n".utf8))
        }
        return copied
    }
}
