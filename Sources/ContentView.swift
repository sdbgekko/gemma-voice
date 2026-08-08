import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var viewModel: StreamingViewModel
    @AppStorage("appearance") private var appearance: String = "system"
    @State private var showSettings = false
    /// Draft for the typed-message compose bar (0.2.39). Text is an additional
    /// modality alongside "tap to talk".
    @State private var draft: String = ""
    @FocusState private var composeFocused: Bool
    /// Photo turn (0.2.45): the library pick in flight. PhotosPicker is the
    /// SwiftUI face of PHPickerViewController — out-of-process, so no photo
    /// permission prompt. Cleared as soon as the pick is consumed.
    @State private var photoPick: PhotosPickerItem?
    /// 0.2.47: the attach button became a menu (Photo Library / Paste Image),
    /// so the picker now presents via this flag instead of a bare PhotosPicker.
    @State private var showPhotoPicker = false

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // follow system
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            if let err = viewModel.errorMessage {
                errorChip(err)
            }
            ledgerList
            dock
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(preferredScheme)
        .onAppear { viewModel.requestMicPermission() }
        .sheet(isPresented: $showSettings) {
            // Explicit injection: the enrollment flow inside Settings needs the
            // view model to pause/resume the live session, and sheets don't
            // reliably inherit environment objects across all iOS versions.
            SettingsView(appearance: $appearance)
                .environmentObject(viewModel)
        }
    }

    // MARK: - Connection bar (honest socket state + settings)

    private var connectionBar: some View {
        HStack(spacing: 8) {
            agentPicker
            // P0-1: when the socket is down this reads "disconnected — tap to
            // reconnect" and forces a fresh connection. Hit-testing is only
            // enabled while disconnected so it never swallows normal taps.
            Button(action: { viewModel.reconnect() }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)
                    Text(connectionLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(viewModel.status == .disconnected)
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // Top-left brain picker: choose which agent the voice app talks to.
    // Data-driven from VoiceAgent.all, so the full roster drops in later.
    private var agentPicker: some View {
        Menu {
            ForEach(VoiceAgent.all) { agent in
                Button {
                    viewModel.selectAgent(agent.id)
                } label: {
                    if viewModel.selectedAgentID == agent.id {
                        Label("\(agent.displayName) · \(agent.subtitle)", systemImage: "checkmark")
                    } else {
                        Text("\(agent.displayName) · \(agent.subtitle)")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(VoiceAgent.by(id: viewModel.selectedAgentID).displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundColor(.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private var connectionLabel: String {
        viewModel.status == .disconnected ? "disconnected — tap to reconnect" : "connected"
    }

    private var connectionColor: Color {
        viewModel.status == .disconnected ? Color(hex: "#9A9A9A") : Color(hex: "#22D67A")
    }

    // MARK: - Inline error chip (replaces the modal .alert for transient events)

    private func errorChip(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(msg)
                .font(.footnote)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: { viewModel.errorMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: - Ledger list

    private var ledgerList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.ledger.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.ledger) { turn in
                            SwipeToDeleteRow(turn: turn) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    viewModel.removeTurn(turn)
                                }
                            }
                            .id(turn.id)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(16)
            }
            // New card appended → scroll to it. Also re-scroll when the newest
            // card changes phase (reply lands, card grows) so the latest stays
            // in view.
            .onChange(of: viewModel.ledger.last?.id) { _, id in
                scrollToLatest(proxy, id)
            }
            .onChange(of: viewModel.ledger.last?.phase) { _, _ in
                scrollToLatest(proxy, viewModel.ledger.last?.id)
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, _ id: UUID?) {
        guard let id = id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            // Sherman's gold GEMMA logo — the hero of the idle screen.
            // Shown until the first turn lands, then the ledger takes over.
            Image("GoldGemma")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260)
                .accessibilityLabel("Gemma")
            Text("Tap to talk — your turns show up here.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Dock (live state + waveform + real labeled mute button)

    private var dock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            WaveformView(
                samples: viewModel.levelHistory,
                active: viewModel.status == .speaking_ || viewModel.status == .playing
            )
            .frame(height: 40)
            .padding(.horizontal, 24)
            // Two INDEPENDENT controls, side by side (mirrors AlohaVoice):
            // MUTE = the mic (his input, blue), SPEAKER = Gemma's voice output
            // (gold). Kept visually distinct so the two affordances never blur.
            HStack(spacing: 10) {
                muteButton
                speakerButton
            }
            composeBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom))
    }

    /// Typed-message compose bar (0.2.39) — the text twin of "tap to talk".
    /// Sends to the currently-selected agent; the reply lands in the same ledger
    /// and speaks if the speaker is on. Doesn't touch the mic, so you can type
    /// while a voice session is live, muted, or disconnected.
    private var composeBar: some View {
        HStack(spacing: 8) {
            // Photo turn (0.2.45): pick a picture, send it with whatever's in
            // the draft as the caption (empty → a sensible default question).
            // 0.2.47: the attach button is now a menu — Photo Library opens the
            // same picker; Paste Image (shown only when the clipboard holds an
            // image) sends the copied image through the identical sendPhoto
            // pipeline. hasImages is a metadata check and does NOT trigger the
            // iOS paste prompt; reading .image on tap does, which is correct.
            Menu {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                if UIPasteboard.general.hasImages {
                    Button(action: pasteCopiedImage) {
                        Label("Paste Image", systemImage: "doc.on.clipboard")
                    }
                }
            } label: {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundColor(.gemmaMicBlue)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send a photo")
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoPick,
                          matching: .images, photoLibrary: .shared())
            .onChange(of: photoPick) { _, item in
                guard let item else { return }
                photoPick = nil
                let caption = draft
                draft = ""
                composeFocused = false
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        viewModel.errorMessage = "Couldn't load that photo."
                        return
                    }
                    viewModel.sendPhoto(image, caption: caption)
                }
            }
            TextField("Type a message…", text: $draft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.tertiarySystemFill))
                .cornerRadius(18)
                .focused($composeFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(draftIsEmpty ? .secondary : .gemmaMicBlue)
            }
            .buttonStyle(.plain)
            .disabled(draftIsEmpty)
            .accessibilityLabel("Send message")
        }
    }

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard !draftIsEmpty else { return }
        let text = draft
        draft = ""
        composeFocused = false
        viewModel.sendText(text)
    }

    /// 0.2.47: send the clipboard's image as a photo turn — the same
    /// caption-from-draft + sendPhoto path the library pick uses, so the
    /// resize/JPEG/upload pipeline and server handling are unchanged.
    /// Reading .image (unlike hasImages) triggers the system paste prompt.
    private func pasteCopiedImage() {
        guard let image = UIPasteboard.general.image else {
            viewModel.errorMessage = "Couldn't read an image from the clipboard."
            return
        }
        let caption = draft
        draft = ""
        composeFocused = false
        viewModel.sendPhoto(image, caption: caption)
    }

    private var muteButton: some View {
        Button(action: { viewModel.toggleMute() }) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.status == .muted ? "mic.slash.fill" : "mic.fill")
                Text(viewModel.status == .muted ? "Tap to talk" : "Mute")
                    .font(.headline)
            }
            .foregroundColor(.white)   // white-on-gemmaMicBlue clears AA (contrast fix)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(viewModel.status == .muted ? Color(hex: "#6E6E73") : Color.gemmaMicBlue)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    /// Speaker output on/off — a SEPARATE control from mute, cutting Gemma's
    /// voice OUTPUT live (see StreamingViewModel.toggleSpeaker). Plain neutral
    /// icon button (Sherman 2026-07-13: "doesn't need to be gold, just a simple
    /// speaker icon") — the wave/slash icon carries the state, kept secondary so
    /// the mute button holds the primary emphasis. Independent of the mic.
    private var speakerButton: some View {
        Button(action: { viewModel.toggleSpeaker() }) {
            Image(systemName: viewModel.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.title2)
                .foregroundColor(viewModel.speakerOn ? .primary : .secondary)
                .frame(width: 64, height: 52)
                .background(Color(.tertiarySystemFill))
                .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.speakerOn ? "Silence Gemma's voice" : "Turn Gemma's voice on")
        .accessibilityLabel(viewModel.speakerOn
            ? "Speaker on. Tap to silence Gemma's voice."
            : "Speaker off. Tap to hear Gemma's voice.")
    }

    private var statusLabel: String {
        switch viewModel.status {
        case .muted: return "muted — tap to talk"
        case .listening: return "listening"
        case .speaking_: return "hearing you..."
        case .heardYou: return "got it — processing"
        case .thinking: return "thinking..."
        case .playing: return "speaking..."
        case .disconnected: return "disconnected — tap to reconnect"
        }
    }

    // Bug fix: the old local switch mapped BOTH .muted and .speaking_ to
    // .red (a collision that read as "error" for a normal speaking state).
    // Repoint to the single source of truth — Status.tintHex in ViewModel.swift
    // (gray muted, green speaking, gold playing, etc. — already correct there).
    private var statusColor: Color {
        Color(hex: viewModel.status.tintHex)
    }
}

#Preview {
    ContentView().environmentObject(StreamingViewModel())
}

/// Wraps a ledger card with swipe-to-delete. Swiping the card LEFT past a
/// threshold deletes it (and, if it's still in flight, kills its work — see
/// `StreamingViewModel.removeTurn`); a short swipe springs back. `TurnCardView`
/// is used unchanged — this only adds the reveal + gesture.
///
/// Approach (a): a custom horizontal drag, NOT a `List`/`.swipeActions` refactor.
/// The ledger is a `LazyVStack` inside a `ScrollView` with a `ScrollViewReader`
/// scroll-to-latest, a GoldGemma empty-state hero, and a bespoke card look;
/// moving to a `List` would disturb all three (row insets/separators, List's
/// own scroll semantics) for no visual gain. A drag keeps the card pixel-identical.
private struct SwipeToDeleteRow: View {
    let turn: LedgerTurn
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0

    // Swipe at least this far left (on release) to commit the delete.
    private let deleteThreshold: CGFloat = 110
    // Cap the live reveal so the card can't be dragged clear off-screen.
    private let maxReveal: CGFloat = 132

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteAffordance
            TurnCardView(turn: turn)
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            let dx = value.translation.width
                            // Left drags only, and only when the drag is clearly
                            // horizontal — vertical-dominant drags stay with the
                            // ScrollView so scrolling isn't hijacked.
                            if dx < 0, abs(dx) > abs(value.translation.height) {
                                offset = max(dx, -maxReveal)
                            }
                        }
                        .onEnded { value in
                            let dx = value.translation.width
                            if dx <= -deleteThreshold, abs(dx) > abs(value.translation.height) {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                onDelete()   // parent animates the row out
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    offset = 0
                                }
                            }
                        }
                )
        }
    }

    /// Red delete panel revealed behind the card as it slides left. Fades in
    /// with the swipe so it reads as "keep going to delete".
    private var deleteAffordance: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.red)
            .overlay(
                Image(systemName: "trash.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(.trailing, 24),
                alignment: .trailing
            )
            .opacity(Double(min(1, -offset / deleteThreshold)))
            .accessibilityHidden(true)
    }
}

struct WaveformView: View {
    let samples: [Float]
    let active: Bool

    // Tuned so a modest level (~0.1) fills about half the bar height.
    private func normalized(_ v: Float) -> CGFloat {
        CGFloat(min(1.0, max(0.04, Double(v) * 5.5)))
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(gold)
                        .frame(width: max(2, (geo.size.width - CGFloat(samples.count - 1) * 3) / CGFloat(samples.count)),
                               height: max(3, geo.size.height * normalized(v)))
                        .opacity(active ? 1.0 : 0.35)
                        .animation(.linear(duration: 0.08), value: v)
                }
            }
        }
    }

    // Soft gold to echo the logo.
    private var gold: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.85, green: 0.70, blue: 0.32),
                Color(red: 0.95, green: 0.80, blue: 0.40),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Design color tokens
//
// Two WCAG contrast fixes plus a hex helper so Status.tintHex (defined in
// ViewModel.swift) can drive SwiftUI colors directly.

extension UIColor {
    /// "#RRGGBB" (leading '#' optional). Falls back to opaque black on a
    /// malformed string rather than trapping.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v & 0xFF0000) >> 16) / 255
        let g = CGFloat((v & 0x00FF00) >> 8) / 255
        let b = CGFloat(v & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(UIColor(hex: hex)) }

    /// Contrast fix: brand gold #D4A44A is only 2.28:1 as TEXT on white (AA
    /// fail). Keep #D4A44A for accents/fills/glows, but text uses this token —
    /// #D4A44A in dark mode (on the dark ground it clears AA), darkened to
    /// #8A6414 in light mode (~4.6:1 on white). Dynamic so the appearance
    /// picker resolves it live.
    static let gemmaGoldText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: "#D4A44A")
                                           : UIColor(hex: "#8A6414")
    })

    /// Contrast fix: white label on system blue is ~3.26:1 (borderline).
    /// #2E6FD6 lifts white-on-blue to ~4.6:1 (AA).
    static let gemmaMicBlue = Color(hex: "#2E6FD6")

    /// Speaker-button fill when sound is ON. Deep gold echoes the GEMMA logo /
    /// waveform while staying DISTINCT from the blue mic/mute button. Chosen dark
    /// enough that the white label clears AA (white on #8A6414 ≈ 5.4:1); the
    /// lighter brand gold #D4A44A would fail as a white-text ground (~2.3:1).
    static let gemmaSpeakerGold = Color(hex: "#8A6414")
}
