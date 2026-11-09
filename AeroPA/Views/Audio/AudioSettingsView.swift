import SwiftUI
import AeroPACore

struct AudioSettingsView: View {
    @EnvironmentObject var app: CompanionCoordinator

    private let previewCues: [(String, String)] = [
        ("pa.welcome", "Welcome aboard"), ("pa.safety", "Safety briefing"), ("pa.takeoff", "Seats for takeoff"),
        ("pa.cruise", "Captain at cruise"), ("pa.arrival", "Welcome to destination"),
        ("sfx.chime", "Chime"), ("sfx.double_chime", "Double chime"), ("sfx.seatbelt", "Seatbelt sign")
    ]

    var body: some View {
        List {
            Section("Volume") {
                VolumeRow(title: "Announcements", icon: "speaker.wave.2.fill", value: app.volumeBinding(.pa))
                VolumeRow(title: "First officer", icon: "headphones", value: app.volumeBinding(.copilot))
                VolumeRow(title: "Cabin ambience", icon: "wind", value: app.volumeBinding(.ambience))
                VolumeRow(title: "Sound effects", icon: "bell.fill", value: app.volumeBinding(.sfx))
            }
            Section {
                Toggle("Cabin ambience", isOn: app.binding(\.ambienceEnabled))
                Toggle("Cabin speaker effect", isOn: app.binding(\.paSpeakerEffect))
                Toggle("Interphone effect on callouts", isOn: app.binding(\.copilotInterphoneEffect))
                Toggle("Synthesized voice for missing recordings", isOn: app.binding(\.speechFallback))
            } footer: {
                Text("AeroPA mixes with Aerofly's audio and never ducks or interrupts it. Cabin ambience keeps AeroPA running when you switch to Aerofly. Without it, iOS may suspend AeroPA in the background.")
            }
            Section("Preview") {
                ForEach(previewCues, id: \.0) { cue, title in
                    Button { app.preview(cue: cue) } label: {
                        HStack {
                            Text(title).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "play.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 20))
                        }
                    }
                }
                if let profile = app.currentProfile {
                    ForEach(profile.callouts.prefix(4)) { c in
                        Button { app.preview(cue: "copilot.\(c.id)") } label: {
                            HStack {
                                Text("FO: \(c.text)").foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "play.circle").foregroundStyle(Theme.accent).font(.system(size: 20))
                            }
                        }
                    }
                }
                Button("Stop all", role: .destructive) { app.stopPreview() }
            }
        }
        .navigationTitle("Audio")
        .inlineTitle()
    }
}

private struct VolumeRow: View {
    let title: String
    let icon: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(Int(value * 100))%").font(Theme.mono(13)).foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $value, in: 0...1)
        }
        .padding(.vertical, 4)
    }
}
