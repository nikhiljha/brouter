import AppKit

/// Hands a URL to an already-running Chrome-family browser by speaking Chrome's
/// `ProcessSingleton` socket protocol directly — the same handshake a freshly
/// launched `chrome` performs before it hands off and quits.
///
/// The win: we do NOT exec a throwaway browser binary. That means no Dock
/// bounce and, crucially, nothing for an on-exec EDR/AV scanner (SentinelOne,
/// MDM ESF agents, …) to synchronously inspect — which is what intermittently
/// stalls a cold `open -n` launch for several seconds.
///
/// Everything here is best-effort: any miss (browser not running, cookie
/// mismatch, refused connection, no ACK, non-Chrome app) returns false so the
/// caller can fall back to the normal `open` path. Protocol reference:
/// chromium/src/chrome/browser/process_singleton_posix.cc
enum SingletonNotifier {
    /// Chrome-family bundle ids -> user-data-dir (relative to Application Support).
    private static let chromeFamily: [String: String] = [
        "com.google.Chrome":        "Google/Chrome",
        "com.google.Chrome.beta":   "Google/Chrome Beta",
        "com.google.Chrome.dev":    "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
    ]

    /// Attempt the singleton hand-off. Returns true only if the running browser
    /// acknowledged (ACK) the request, in which case the URL is now open.
    static func tryNotify(_ target: BrowserTarget, url: String) -> Bool {
        guard let appURL = BrowserLauncher.appURL(for: target.app),
              let bundleId = Bundle(url: appURL)?.bundleIdentifier,
              let support = chromeFamily[bundleId] else { return false }

        let userDataDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(support)

        // argv format Chrome expects: "<program> [switches] <url>".
        let exe = Bundle(url: appURL)?.executableURL?.path ?? appURL.path
        var argv = [exe]
        if let profile = target.profile, !profile.isEmpty {
            argv.append("--profile-directory=\(profile)")
        }
        argv.append(contentsOf: target.args)
        argv.append(url)

        guard notify(userDataDir: userDataDir, argv: argv) else { return false }
        // `open` would bring the browser forward; match that behaviour.
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    // MARK: - Socket handshake

    private static func notify(userDataDir: URL, argv: [String]) -> Bool {
        let fm = FileManager.default
        let socketLink = userDataDir.appendingPathComponent("SingletonSocket").path
        let cookieLink = userDataDir.appendingPathComponent("SingletonCookie").path

        // Resolve the socket symlink and validate the cookie (guards against a
        // stale/hijacked socket dir), exactly as Chrome's client does.
        guard let socketTarget = try? fm.destinationOfSymbolicLink(atPath: socketLink),
              let cookie = try? fm.destinationOfSymbolicLink(atPath: cookieLink),
              !cookie.isEmpty else { return false }
        let remoteCookieLink = (socketTarget as NSString)
            .deletingLastPathComponent.appending("/SingletonCookie")
        guard (try? fm.destinationOfSymbolicLink(atPath: remoteCookieLink)) == cookie else {
            return false
        }

        let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let pathBytes = Array(socketTarget.utf8)
        guard pathBytes.count < sunPathCapacity else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        addr.sun_len = UInt8(2 + pathBytes.count + 1)

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        // Re-check the cookie after connecting (Chrome does this too: /tmp is
        // sticky, so a stable cookie means we reached the right directory).
        guard (try? fm.destinationOfSymbolicLink(atPath: remoteCookieLink)) == cookie else {
            return false
        }

        // Message: "START" \0 <cwd> \0 <argv0> \0 <argv1> ...
        var msg = Data("START".utf8)
        msg.append(0)
        msg.append(Data(fm.homeDirectoryForCurrentUser.path.utf8))
        for arg in argv {
            msg.append(0)
            msg.append(Data(arg.utf8))
        }

        guard writeAll(fd, msg) else { return false }
        shutdown(fd, SHUT_WR)

        // Await ACK. A responsive browser replies in well under a millisecond;
        // the socket read timeout above bounds a hung one.
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(fd, &buf, buf.count)
        guard n >= 3 else { return false }
        return String(decoding: buf[0..<3], as: UTF8.self) == "ACK"
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.baseAddress else { return false }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, p, remaining)
                if n <= 0 { return false }
                p = p.advanced(by: n)
                remaining -= n
            }
            return true
        }
    }
}
