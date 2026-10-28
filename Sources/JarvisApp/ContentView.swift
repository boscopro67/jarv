import SwiftUI

// ══════════════════════════════════════════════════════════════════════
//  Un seul écran : l'orbe au centre, trois boutons en bas.
//  Mise en page 100 % adaptative (aucune largeur fixe) → rien ne déborde,
//  aucun zoom, quel que soit l'iPhone (XR compris).
// ══════════════════════════════════════════════════════════════════════

struct ContentView: View {
    @EnvironmentObject var client: JarvisClient
    @EnvironmentObject var voice: LiveVoiceClient
    @EnvironmentObject var chat: ChatStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showChat = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                    .padding(.top, 6)

                orbStage
                    .padding(.vertical, 8)

                statusBlock

                controls
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 20)
        }
        // Le texte ne grossit jamais au point de déborder.
        .dynamicTypeSize(.xSmall ... .large)
        .sheet(isPresented: $showChat) {
            ChatSheet().environmentObject(chat).environmentObject(client)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet().environmentObject(client).environmentObject(chat)
        }
        .onAppear {
            voice.onTranscript = { speaker, text in chat.record(speaker: speaker, text: text) }
            client.startMonitoring()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { client.recheckNow() }
        }
    }

    // ── Fond : noir profond avec une lueur douce derrière l'orbe ────────
    private var background: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.bgGlow, Theme.bg],
                           center: .center, startRadius: 0, endRadius: 520)
                .opacity(voice.state == .idle ? 0.55 : 0.95)
                .animation(.easeInOut(duration: 0.8), value: voice.state)
        }
        .ignoresSafeArea()
    }

    // ── En-tête ───────────────────────────────────────────────────────────
    private var header: some View {
        HStack {
            Text("J A R V I S")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.cyan)
                .lineLimit(1)
            Spacer()
            Button { showSettings = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(pcColor).frame(width: 7, height: 7)
                    Text(pcLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Capsule().stroke(Theme.dim.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var pcColor: Color {
        switch client.pcStatus {
        case .online:        return Theme.cyan
        case .checking:      return Theme.warn
        case .offline:       return Theme.dim
        case .notConfigured: return Theme.dim.opacity(0.5)
        }
    }

    private var pcLabel: String {
        switch client.pcStatus {
        case .online:        return "PC LIÉ"
        case .checking:      return "PC…"
        case .offline:       return "PC HORS LIGNE"
        case .notConfigured: return "PC NON LIÉ"
        }
    }

    // ── L'orbe (toucher pour démarrer) ────────────────────────────────────
    private var orbStage: some View {
        OrbView(state: voice.state, level: voice.level, muted: voice.muted)
            .frame(maxWidth: 340, maxHeight: 340)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if voice.state == .idle { voice.start() }
            }
    }

    // ── Texte d'état + dernière phrase ────────────────────────────────────
    private var statusBlock: some View {
        VStack(spacing: 10) {
            Text(statusText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.cyan.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Group {
                if let error = voice.errorText {
                    Text(error).foregroundColor(Theme.warn)
                } else if !voice.caption.isEmpty {
                    Text(voice.caption)
                        .foregroundColor(voice.captionIsUser ? Theme.dim : .white)
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 15))
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .top)
        }
    }

    private var statusText: String {
        switch voice.state {
        case .idle:       return "TOUCHE L'ORBE POUR PARLER"
        case .connecting: return "CONNEXION…"
        case .listening:  return voice.muted ? "MICRO COUPÉ" : "JE T'ÉCOUTE"
        case .speaking:   return "JARVIS PARLE"
        }
    }

    // ── Boutons ──────────────────────────────────────────────────────────
    private var controls: some View {
        HStack(spacing: 0) {
            roundButton(icon: voice.muted ? "mic.slash.fill" : "mic.fill",
                        active: voice.isActive && !voice.muted,
                        enabled: voice.isActive) {
                voice.toggleMute()
            }
            Spacer()
            roundButton(icon: voice.isActive ? "power" : "waveform",
                        active: voice.isActive, enabled: true, large: true) {
                if voice.isActive { voice.stop() } else { voice.start() }
            }
            Spacer()
            roundButton(icon: "text.bubble", active: false, enabled: true) {
                showChat = true
            }
        }
        .padding(.horizontal, 12)
    }

    private func roundButton(icon: String, active: Bool, enabled: Bool,
                             large: Bool = false, action: @escaping () -> Void) -> some View {
        let size: CGFloat = large ? 68 : 54
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: large ? 24 : 19, weight: .light))
                .foregroundColor(active ? Theme.cyan : Theme.dim)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.panel.opacity(0.6)))
                .overlay(Circle().stroke(active ? Theme.cyan.opacity(0.7) : Theme.dim.opacity(0.35),
                                         lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Historique + saisie au clavier
// ══════════════════════════════════════════════════════════════════════
private struct ChatSheet: View {
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("HISTORIQUE")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(Theme.cyan)
                    Spacer()
                    Button("Fermer") { dismiss() }
                        .font(.system(size: 14))
                        .foregroundColor(Theme.dim)
                }
                .padding(16)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(chat.messages) { message in
                                Bubble(message: message)
                            }
                            if chat.isThinking {
                                ProgressView().tint(Theme.cyan)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: chat.messages) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }

                HStack(spacing: 10) {
                    TextField("Écris à Jarvis…", text: $input)
                        .font(.system(size: 16))
                        .padding(12)
                        .background(Theme.panel)
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(Theme.cyan)
                    }
                }
                .padding(12)
            }
        }
        .dynamicTypeSize(.xSmall ... .large)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        chat.send(text)
    }
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.speaker == "user" { Spacer(minLength: 40) }
            Text(message.text)
                .font(.system(size: 15))
                .foregroundColor(message.speaker == "sys" ? Theme.warn : .white)
                .padding(10)
                .background(background)
                .cornerRadius(14)
                .fixedSize(horizontal: false, vertical: true)
            if message.speaker != "user" { Spacer(minLength: 40) }
        }
    }

    private var background: Color {
        switch message.speaker {
        case "user": return Theme.cyan.opacity(0.16)
        case "sys":  return .clear
        default:     return Theme.panel
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Réglages : adresse du PC (une seule fois) et clé Gemini en secours
// ══════════════════════════════════════════════════════════════════════
private struct SettingsSheet: View {
    @EnvironmentObject var client: JarvisClient
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var manualKey = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("RÉGLAGES")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .foregroundColor(Theme.cyan)
                        Spacer()
                        Button("Fermer") { dismiss() }
                            .font(.system(size: 14))
                            .foregroundColor(Theme.dim)
                    }

                    section("ADRESSE DU PC (TAILSCALE)") {
                        TextField("100.x.x.x", text: $client.remoteHost)
                            .keyboardType(.numbersAndPunctuation)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .field()
                        Button {
                            client.recheckNow()
                        } label: {
                            Text("VÉRIFIER LA LIAISON")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .foregroundColor(Theme.cyan)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cyan.opacity(0.5)))
                        }
                        if !client.detail.isEmpty {
                            Text(client.detail)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.dim)
                        }
                        Text("À saisir une seule fois. Le PC doit être allumé, Jarvis lancé, Tailscale actif sur le PC et sur le téléphone. Ensuite, le téléphone fonctionne aussi sans le PC.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.dim.opacity(0.85))
                    }

                    section("CLÉ GEMINI") {
                        Text(client.hasKey ? "Présente sur ce téléphone." : "Absente : lie le PC, ou colle-la ici.")
                            .font(.system(size: 12))
                            .foregroundColor(client.hasKey ? Theme.cyan : Theme.warn)
                        SecureField("Coller une clé (facultatif)", text: $manualKey)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .field()
                        Button {
                            client.saveKey(manualKey)
                            manualKey = ""
                        } label: {
                            Text("ENREGISTRER LA CLÉ")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .foregroundColor(Theme.dim)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.dim.opacity(0.4)))
                        }
                        .disabled(manualKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    section("HISTORIQUE") {
                        Button {
                            chat.clear()
                        } label: {
                            Text("EFFACER L'HISTORIQUE DU TÉLÉPHONE")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .foregroundColor(Theme.warn)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warn.opacity(0.4)))
                        }
                    }
                }
                .padding(20)
            }
        }
        .dynamicTypeSize(.xSmall ... .large)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(Theme.dim)
            content()
        }
    }
}

private extension View {
    func field() -> some View {
        self.font(.system(size: 16))
            .padding(12)
            .background(Theme.panel)
            .cornerRadius(10)
            .foregroundColor(.white)
    }
}
