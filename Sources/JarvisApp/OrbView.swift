import SwiftUI

enum Theme {
    static let bg     = Color(red: 0x02/255, green: 0x08/255, blue: 0x0b/255)
    static let bgGlow = Color(red: 0x05/255, green: 0x1c/255, blue: 0x24/255)
    static let cyan   = Color(red: 0x35/255, green: 0xe6/255, blue: 0xf2/255)
    static let dim    = Color(red: 0x4f/255, green: 0x8b/255, blue: 0x93/255)
    static let panel  = Color(red: 0x04/255, green: 0x14/255, blue: 0x1a/255)
    static let warn   = Color(red: 1.0, green: 0.62, blue: 0.25)
}

/// L'orbe de JARVIS : minimaliste, il respire au repos, réagit à ta voix quand
/// il écoute, et ondule quand il parle. Aucune taille fixe : il remplit la
/// place qu'on lui donne (donc rien ne déborde, quel que soit l'iPhone).
struct OrbView: View {
    let state: VoiceState
    let level: CGFloat      // 0…1, niveau sonore en direct
    let muted: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                orb(t: timeline.date.timeIntervalSinceReferenceDate, side: side)
                    .frame(width: side, height: side)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }

    private var tint: Color { muted ? Theme.dim : Theme.cyan }

    private var energy: Double {
        switch state {
        case .idle:       return 0.0
        case .connecting: return 0.35
        case .listening:  return 0.55
        case .speaking:   return 1.0
        }
    }

    private func orb(t: Double, side: CGFloat) -> some View {
        let breathSpeed = state == .speaking ? 2.4 : (state == .idle ? 0.7 : 1.3)
        let breath = (sin(t * breathSpeed) + 1) / 2            // 0…1
        let boost = Double(level)
        let coreScale = 0.50 + 0.04 * breath + 0.20 * boost * (state == .idle ? 0 : 1)
        let glow = (state == .idle ? 0.18 : 0.30) + 0.35 * energy * breath + 0.4 * boost

        return ZStack {
            // Halo diffus
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.22 + 0.25 * boost), .clear],
                                     center: .center, startRadius: side * 0.1, endRadius: side * 0.5))
                .scaleEffect(1.0 + 0.04 * breath)

            // Anneau fin extérieur, discontinu, qui tourne lentement
            Circle()
                .stroke(tint.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 9]))
                .scaleEffect(0.98)
                .rotationEffect(.degrees(t * (state == .idle ? 4 : 10)))

            // Deux arcs qui tournent en sens inverse
            Circle()
                .trim(from: 0.0, to: 0.22)
                .stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .scaleEffect(0.84)
                .rotationEffect(.degrees(t * (18 + 40 * energy)))
            Circle()
                .trim(from: 0.5, to: 0.64)
                .stroke(tint.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .scaleEffect(0.74)
                .rotationEffect(.degrees(-t * (14 + 30 * energy)))

            // Onde qui part du cœur quand il parle ou écoute
            Circle()
                .stroke(tint.opacity(0.5 * (1 - breath) * energy), lineWidth: 1.2)
                .scaleEffect(0.52 + 0.40 * breath)

            // Cœur
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.9), tint.opacity(0.95), tint.opacity(0.06)],
                                     center: .center, startRadius: 1, endRadius: side * 0.26))
                .scaleEffect(coreScale)
                .shadow(color: tint.opacity(glow), radius: side * 0.07)
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
