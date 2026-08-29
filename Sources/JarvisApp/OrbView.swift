import SwiftUI

private let cyan = Color(red: 0x35/255, green: 0xe6/255, blue: 0xf2/255)

struct OrbView: View {
    let state: VoiceState

    @State private var breathe = false
    @State private var ringPulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(cyan.opacity(0.45 - Double(i) * 0.12), lineWidth: 1.5)
                    .scaleEffect(ringPulse ? 1.35 + CGFloat(i) * 0.18 : 0.6)
                    .opacity(ringPulse ? 0 : 0.8)
            }
            Circle()
                .fill(
                    RadialGradient(colors: [cyan.opacity(0.9), cyan.opacity(0.05)],
                                   center: .center, startRadius: 1, endRadius: 34)
                )
                .scaleEffect(breathe ? 1.0 : 0.86)
                .shadow(color: cyan.opacity(glowIntensity), radius: 14)
        }
        .frame(width: 64, height: 64)
        .onAppear { animate() }
        .onChange(of: state) { _ in animate() }
    }

    private var glowIntensity: Double {
        switch state {
        case .idle:      return 0.25
        case .listening: return 0.55
        case .speaking:  return 0.85
        }
    }

    private func animate() {
        let breatheSpeed: Double
        let pulseSpeed: Double
        switch state {
        case .idle:      breatheSpeed = 1.8; pulseSpeed = 2.6
        case .listening: breatheSpeed = 0.9; pulseSpeed = 1.4
        case .speaking:  breatheSpeed = 0.45; pulseSpeed = 0.7
        }
        withAnimation(.easeInOut(duration: breatheSpeed).repeatForever(autoreverses: true)) {
            breathe.toggle()
        }
        withAnimation(.easeOut(duration: pulseSpeed).repeatForever(autoreverses: false)) {
            ringPulse.toggle()
        }
    }
}
