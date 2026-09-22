import AppKit
import SwiftUI

/// A panel subclass that can become key even while borderless,
/// so keyboard selection works.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A generic option shown in the native picker.
struct PickerOption {
    let title: String
    let subtitle: String?
    let icon: NSImage
}

final class AskDialogController: NSObject, NSWindowDelegate {
    private var panel: KeyablePanel?
    private var completion: ((Int?) -> Void)?
    private var keyMonitor: Any?
    private var retainSelf: AskDialogController?
    private var optionCount = 0
    private var didFinish = false

    // MARK: - Browser convenience

    func present(_ request: AskRequest, completion: @escaping (RouteOption?) -> Void) {
        let opts = request.options.map { option -> PickerOption in
            switch option {
            case .copy:
                return PickerOption(title: option.displayName, subtitle: "Copy the original link to the clipboard",
                                    icon: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy URL") ?? NSImage())
            case .browser(let t):
                var sub: [String] = []
                if t.displayName != t.app { sub.append(t.app) }
                if let p = t.profile, !p.isEmpty { sub.append(p) }
                return PickerOption(title: t.displayName,
                                    subtitle: sub.isEmpty ? nil : sub.joined(separator: " · "),
                                    icon: BrowserLauncher.icon(for: t))
            }
        }
        let host = URLComponents(string: request.url)?.host ?? request.url
        presentPicker(caption: request.message ?? "Open link in…",
                      title: host, detail: request.url,
                      options: opts, defaultIndex: request.defaultIndex ?? 0) { idx in
            completion(idx.map { request.options[$0] })
        }
    }

    // MARK: - Generic picker

    func presentPicker(caption: String, title: String, detail: String?,
                       options: [PickerOption], defaultIndex: Int,
                       completion: @escaping (Int?) -> Void) {
        self.completion = completion
        self.optionCount = options.count
        self.retainSelf = self
        let def = min(max(defaultIndex, 0), max(options.count - 1, 0))

        let view = AskView(
            caption: caption, title: title, detail: detail,
            options: options.enumerated().map { OptionVM(index: $0.offset, option: $0.element) },
            defaultIndex: def,
            onSelect: { [weak self] in self?.finish(index: $0) },
            onCancel: { [weak self] in self?.finish(index: nil) }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        positionOnActiveScreen(panel, size: size)
        self.panel = panel
        installKeyMonitor(optionCount: options.count, defaultIndex: def)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionOnActiveScreen(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { panel.center(); return }
        let x = frame.midX - size.width / 2
        let y = frame.midY - size.height / 2 + frame.height * 0.08
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func installKeyMonitor(optionCount: Int, defaultIndex: Int) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: self.finish(index: nil); return nil          // esc
            case 36, 76: self.finish(index: defaultIndex); return nil  // return / enter
            default: break
            }
            if let chars = event.charactersIgnoringModifiers, let n = Int(chars), n >= 1, n <= optionCount {
                self.finish(index: n - 1); return nil
            }
            return event
        }
    }

    private func finish(index: Int?) {
        guard !didFinish else { return }
        didFinish = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        completion?(index)
        completion = nil
        if NSApp.windows.allSatisfy({ !$0.isVisible }) { NSApp.hide(nil) }
        DispatchQueue.main.async { self.retainSelf = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        finish(index: nil)
    }
}

// MARK: - SwiftUI

struct OptionVM: Identifiable {
    let id = UUID()
    let index: Int
    let option: PickerOption
}

struct AskView: View {
    let caption: String
    let title: String
    let detail: String?
    let options: [OptionVM]
    let defaultIndex: Int
    let onSelect: (Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(spacing: 6) {
                ForEach(options) { vm in
                    OptionRow(
                        index: vm.index,
                        option: vm.option,
                        isDefault: vm.index == defaultIndex,
                        action: { onSelect(vm.index) }
                    )
                }
            }
            footer
        }
        .padding(18)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1).truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            keyHint("1–9", "select")
            keyHint("↩", "default")
            keyHint("esc", "cancel")
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }
}

private struct OptionRow: View {
    let index: Int
    let option: PickerOption
    let isDefault: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(nsImage: option.icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let sub = option.subtitle {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isDefault ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if hovering { return Color.primary.opacity(0.10) }
        if isDefault { return Color.accentColor.opacity(0.10) }
        return Color.primary.opacity(0.04)
    }
}
