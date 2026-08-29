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
            case .connected:
                ChatScreen()
            default:
                LoginScreen()
            }
        }
        .onAppear { client.start() }
    }
}

// ── Écran de connexion ──────────────────────────────────────────────────
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

            VStack(alignment: .leading, spacing: 6) {
                Text("ADRESSE IP DU PC").font(.caption).foregroundColor(dimTxt)
                TextField("192.168.0.6", text: $client.serverIP)
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
                Text("CODE (Remote Control sur JARVIS)").font(.caption).foregroundColor(dimTxt)
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
                client.login(pin: pin)
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
            .disabled(pin.count < 6 || client.serverIP.isEmpty)

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
                Circle().fill(client.jarvisActive ? .green : dimTxt).frame(width: 8, height: 8)
                Text(client.jarvisActive ? "ACTIVE" : "SLEEPING")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(dimTxt)
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
                    }
                    .padding(14)
                    .id("bottom")
                }
                .onChange(of: client.messages) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField("Écris une commande…", text: $input)
                    .padding(10)
                    .background(panel)
                    .cornerRadius(8)
                    .foregroundColor(.white)

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
