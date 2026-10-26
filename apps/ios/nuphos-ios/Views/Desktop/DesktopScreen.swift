import SwiftUI

/// A conversation's desktop, full screen. Held upright, the picture sits on
/// top with the controls, a row of keys and a trackpad below it; sideways, the
/// picture fills the screen and takes touch directly.
struct DesktopScreen: View {
    @State private var desktop: DesktopSession
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboard = false
    /// The screen's space without the keyboard, which decides the layout.
    @State private var size = CGSize(width: 1, height: 2)

    init(desktop: DesktopSession, title: String) {
        _desktop = State(initialValue: desktop)
        self.title = title
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if size.height > size.width {
                // The keyboard covers the trackpad rather than squeezing the picture.
                uprightLayout(width: size.width).ignoresSafeArea(.keyboard)
            } else {
                sidewaysLayout
            }
            DesktopKeyInput(desktop: desktop, shown: $keyboard)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            status
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { size = geometry.size }
                    .onChange(of: geometry.size) { _, new in size = new }
            }
            .ignoresSafeArea(.keyboard)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { desktop.start() }
        .onDisappear { desktop.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app closes the stream, which hands the desktop back.
            if phase == .active { desktop.start() } else if phase == .background { desktop.stop() }
        }
        .onChange(of: desktop.controlling) { _, controlling in if !controlling { keyboard = false } }
    }

    // MARK: - Layouts

    private func uprightLayout(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            header
            DesktopCanvas(desktop: desktop)
                .frame(height: ((width - 16) / 1.6).rounded())
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 8)
            controls
                .padding(.horizontal, 8)
            keyRow
                .padding(.horizontal, 8)
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                if desktop.controlling {
                    Text("Drag to move the pointer. Tap to click, two fingers to scroll.")
                        .font(Theme.Text.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .allowsHitTesting(false)
                    DesktopTrackpad(desktop: desktop)
                } else {
                    takeOverPrompt
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var sidewaysLayout: some View {
        DesktopCanvas(desktop: desktop)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    closeButton
                    Spacer()
                    if desktop.controlling { keyboardButton }
                    controlButton
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom) {
                if keyboard { keyRow.padding(8).background(.ultraThinMaterial) }
            }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            closeButton
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Text.label.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(stateLine)
                    .font(Theme.Text.micro)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                #if DEBUG
                if !desktop.stats.isEmpty {
                    Text(verbatim: desktop.stats)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                #endif
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var stateLine: LocalizedStringKey {
        switch desktop.phase {
        case .live where desktop.controlling:
            desktop.isMacScreen ? "You're in control · the agent can still use it too" : "You're in control · the agent waits"
        case .live: "Watching the agent's desktop"
        case .connecting: "Connecting…"
        case .signIn: "Sign in to the Mac"
        case .failed: "Disconnected"
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            keyboardButton.disabled(!desktop.controlling)
            Spacer()
            controlButton
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Close desktop")
    }

    private var keyboardButton: some View {
        Button { keyboard.toggle() } label: {
            Image(systemName: keyboard ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(keyboard ? 0.24 : 0.12)))
        }
        .foregroundStyle(.white)
        .accessibilityLabel(keyboard ? "Hide keyboard" : "Show keyboard")
    }

    private var controlButton: some View {
        Button { desktop.setControlling(!desktop.controlling) } label: {
            Label(desktop.controlling ? "Hand back" : "Take over", systemImage: desktop.controlling ? "hand.raised.slash" : "hand.point.up.left")
                .font(Theme.Text.label.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(desktop.controlling ? Color.white.opacity(0.12) : Theme.brand))
        }
        .foregroundStyle(.white)
        .disabled(desktop.phase != .live)
    }

    private var takeOverPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 28, weight: .light))
            Text(desktop.isMacScreen
                 ? "Take over to click, type and scroll on the Mac from here."
                 : "Take over to click, type and scroll here. The agent waits until you hand the desktop back.")
                .font(Theme.Text.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.45))
        .padding(28)
    }

    /// esc, tab and the modifiers, which latch for the next key or click, then the arrows.
    private var keyRow: some View {
        HStack(spacing: 6) {
            DesktopKeyCap("esc") { desktop.key(RFBKeysym.escape) }
            DesktopKeyCap("tab") { desktop.key(RFBKeysym.tab) }
            DesktopKeyCap("⌃", latched: desktop.latched.contains(RFBKeysym.control)) { desktop.toggleLatch(RFBKeysym.control) }
            DesktopKeyCap("⌥", latched: desktop.latched.contains(RFBKeysym.option)) { desktop.toggleLatch(RFBKeysym.option) }
            DesktopKeyCap("⌘", latched: desktop.latched.contains(RFBKeysym.command)) { desktop.toggleLatch(RFBKeysym.command) }
            DesktopKeyCap("⇧", latched: desktop.latched.contains(RFBKeysym.shift)) { desktop.toggleLatch(RFBKeysym.shift) }
            DesktopKeyCap("←") { desktop.key(RFBKeysym.left) }
            DesktopKeyCap("↑") { desktop.key(RFBKeysym.up) }
            DesktopKeyCap("↓") { desktop.key(RFBKeysym.down) }
            DesktopKeyCap("→") { desktop.key(RFBKeysym.right) }
        }
        .disabled(!desktop.controlling)
        .opacity(desktop.controlling ? 1 : 0.4)
    }

    @ViewBuilder
    private var status: some View {
        switch desktop.phase {
        case .connecting where desktop.screenSize == .zero:
            ProgressView("Connecting…")
                .tint(.white)
                .foregroundStyle(.white.opacity(0.7))
        case .signIn(let failed):
            DesktopSignIn(failed: failed, signIn: { desktop.signIn(user: $0, password: $1) }) { dismiss() }
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 34, weight: .light))
                Text(message)
                    .font(Theme.Text.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                    Button("Try again") { desktop.retry() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                }
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(maxWidth: 360)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.12)))
            .padding(24)
        default:
            EmptyView()
        }
    }
}

private struct DesktopKeyCap: View {
    let label: String
    var latched = false
    let action: () -> Void

    init(_ label: String, latched: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.latched = latched
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: label.count > 1 ? 13 : 17, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(latched ? Theme.brand : Color.white.opacity(0.12)))
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }
}

/// Asks for an account on the Mac when its screen wants one. The account goes
/// to the Mac encrypted end to end and is kept only while Nuphos runs.
private struct DesktopSignIn: View {
    let failed: Bool
    let signIn: (String, String) -> Void
    let cancel: () -> Void

    @State private var user = ""
    @State private var password = ""
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to the Mac")
                .font(Theme.Text.body.weight(.semibold))
            Text(failed ? "The Mac did not accept that account. Try again." : "Use an account on this Mac, as Screen Sharing asks for.")
                .font(Theme.Text.caption)
                .foregroundStyle(failed ? Theme.warning : .white.opacity(0.6))
            TextField("Account name", text: $user)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit(submit)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Sign in", action: submit)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .disabled(user.isEmpty || password.isEmpty)
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: 360)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.12)))
        .padding(24)
        .onAppear { focus = true }
    }

    private func submit() {
        guard !user.isEmpty, !password.isEmpty else { return }
        signIn(user, password)
        password = ""
    }
}
