import AppKit
import SwiftUI

/// A short message near the top of the screen that fades away by itself.
/// It does not take clicks, so it never gets in the way.
@MainActor
final class Toast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ title: String, _ text: String, seconds: TimeInterval = 9) {
        hide()
        guard let screen = NSScreen.main else { return }
        let view = NSHostingView(rootView: ToastView(title: title, text: text))
        let size = view.fittingSize
        let area = screen.visibleFrame
        let frame = CGRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 14,
                           width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // Above the weather, which sits at the floating level.
        p.level = .modalPanel
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = view
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; p.animator().alphaValue = 1 }
        panel = p

        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func fadeOut() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.6; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }
}

private struct ToastView: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(6)
    }
}
