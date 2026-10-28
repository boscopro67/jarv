import SwiftUI

private let bg     = Color(red: 0x03/255, green: 0x0a/255, blue: 0x0d/255)
private let cyan   = Color(red: 0x35/255, green: 0xe6/255, blue: 0xf2/255)
private let panel  = Color(red: 0x04/255, green: 0x14/255, blue: 0x1a/255)
private let dimTxt = Color(red: 0x4f/255, green: 0x8b/255, blue: 0x93/255)

struct ContentView: View {
    @EnvironmentObject var client: JarvisClient

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            switch client.state {
            case .connected, .offline:
                ChatScreen()
            case .home:
                HomeView()
            case .searching, .connecting:
                SearchingScreen()
            case .needsPin, .error:
                LoginScreen()
            }
        }
        // Plus de connexion automatique à l'ouverture : l'appli attend que
        // tu tapes le bloc JARVIS sur l'écran d'accueil.
    }
}

// ── Écran d'accueil — le bloc "JARVIS" qui donne accès au PC ───────────
private struct HomeView: View {
    @EnvironmentObject var client: JarvisClient

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Text("J A R V I S")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(dimTxt)
                .tracking(3)

            Button {
                client.start()
            } label: {
                VStack(spacing: 16) {
                    OrbView(state: .idle)
                    Text("JARVIS")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(cyan)
                    Text("Accéder au PC")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(dimTxt)
                }
                .frame(width: 210, height: 210)
                .background(panel)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(cyan.opacity(0.35)))
                .cornerRadius(22)
            }
            .buttonStyle(.plain)

            Spacer()
            Spacer()
        }
    }
}

// ── Écran affiché pendant la découverte automatique — aucune saisie ────
private struct SearchingScreen: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().tint(cyan).scaleEffect(1.3)
            Text("Connexion à JARVIS…")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(dimTxt)
            Spacer()
        }
    }
}

// ── Écran de connexion (SECOURS uniquement, si la découverte auto échoue) ──
private struct LoginScreen: View {
    @EnvironmentObject var client: JarvisClient
    @State private var pin: String = ""

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("J A R V I S")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(cyan)
                .tracking(4)

            Text("Indique l'adresse du PC (celle de Tailscale, 100.x.x.x).\nElle est gardée : tu ne la saisis qu'une fois.")
                .font(.system(size: 11))
                .foregroundColor(dimTxt)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 6) {
                Text("ADRESSE DU PC (Tailscale)").font(.caption).foregroundColor(dimTxt)
                TextField("100.x.x.x", text: $client.remoteHost)
                    .keyboardType(.numbersAndPunctuation)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(12)
                    .background(panel)
                    .cornerRadius(8)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 6) {
                Text("CODE (facultatif — Remote Control sur JARVIS)").font(.caption).foregroundColor(dimTxt)
                TextField("AB12CD", text: $pin)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .padding(12)
                    .background(panel)
                    .cornerRadius(8)
                    .foregroundColor(.white)
                    .onChange(of: pin) { pin = String($0.uppercased().prefix(6)) }
            }
            .padding(.horizontal, 32)

            if case .error(let msg) = client.state {
                Text(msg).font(.caption).foregroundColor(.red).padding(.horizontal, 32)
            }
            if client.state == .connecting {
                ProgressView().tint(cyan)
            }

            Button {
                if pin.count == 6 {
                    client.login(pin: pin)
                } else {
                    client.start()
                }
            } label: {
                Text("SE CONNECTER")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(cyan.opacity(0.12))
                    .foregroundColor(cyan)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(cyan.opacity(0.5)))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 32)
            .disabled(client.remoteHost.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                client.retryAutomatically()
            } label: {
                Text("Réessayer la découverte automatique")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(dimTxt)
            }

            Button {
                client.enterOffline()
            } label: {
                Text("Continuer en mode autonome (sans le PC)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(cyan)
            }

            Spacer()
            Spacer()
        }
    }
}

// ── Fil de discussion + barre de commande ───────────────────────────────
private struct ChatScreen: View {
    @EnvironmentObject var client: JarvisClient
    @StateObject private var audio = AudioStreamer()
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("JARVIS").font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(cyan)
                Spacer()
                if client.state == .offline {
                    Text("MODE AUTONOME")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    Button {
                        client.start()
                    } label: {
                        Image(systemName: "arrow.clockwise").foregroundColor(dimTxt)
                    }
                    Button {
                        client.openSettings()
                    } label: {
                        Image(systemName: "gearshape").foregroundColor(dimTxt)
                    }
                } else {
                    Circle().fill(client.jarvisActive ? .green : dimTxt).frame(width: 8, height: 8)
                    Text(client.jarvisActive ? "ACTIVE" : "SLEEPING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(dimTxt)
                }
                Button {
                    audio.stop()
                    client.disconnect()
                } label: {
                    Image(systemName: "power").foregroundColor(dimTxt)
                }
            }
            .padding(14)
            .background(panel)

            // L'orbe — pulse doucement au repos, s'accélère en écoute,
            // ondule plus intensément quand JARVIS parle.
            OrbView(state: audio.voiceState)
                .padding(.top, 18)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(client.messages) { m in
                            MessageBubble(message: m)
                        }
                        if client.isThinking {
                            ProgressView().tint(cyan)
                        }
                    }
                    .padding(14)
                    .id("bottom")
                }
                .onChange(of: client.messages) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField(client.state == .offline ? "Écris à Jarvis…" : "Écris une commande…", text: $input)
                    .padding(10)
                    .background(panel)
                    .cornerRadius(8)
                    .foregroundColor(.white)

                // Réveil et micro passent par le PC : masqués en mode autonome.
                if client.state != .offline {
                    Button {
                        client.wake()
                    } label: {
                        Image(systemName: "sun.max.fill").foregroundColor(cyan)
                    }

                    // Bouton micro — active/désactive le chat vocal en direct.
                    // C'est lui qui allume l'orbe (voiceState passe à .listening).
                    Button {
                        toggleMic()
                    } label: {
                        Image(systemName: audio.isActive ? "mic.fill" : "mic")
                            .foregroundColor(audio.isActive ? cyan : dimTxt)
                    }
                }

                Button {
                    guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    client.sendCommand(input)
                    input = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").foregroundColor(cyan)
                }
            }
            .padding(12)
            .background(panel)
        }
        .onDisappear { audio.stop() }
    }

    private func toggleMic() {
        if audio.isActive {
            audio.stop()
        } else if let token = client.currentToken {
            audio.start(serverIP: client.serverIP, token: token)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.speaker == "user" { Spacer(minLength: 40) }
            Text(message.text)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .padding(10)
                .background(bubbleColor)
                .cornerRadius(12)
            if message.speaker != "user" { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        switch message.speaker {
        case "user": return cyan.opacity(0.18)
        case "sys":  return .clear
        default:     return panel
        }
    }
}
