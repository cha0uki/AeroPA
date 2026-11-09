import SwiftUI
import AeroPACore

struct AirlinesView: View {
    @EnvironmentObject var app: CompanionCoordinator
    @State private var detail: AirlinePack?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Packs contain original, licensed or user-provided audio only. When a recording is missing, AeroPA reads the script with the system voice and labels it Synthesized.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(app.packs) { pack in
                        Button { detail = pack } label: {
                            AirlineCard(pack: pack, selected: pack.id == app.settings.airlineID)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button { app.reloadPacks() } label: { Label("Rescan packs", systemImage: "arrow.clockwise") }
                    .font(.system(size: 14, weight: .semibold))
                Text("Add your own pack: in the Files app, open On My iPhone › AeroPA › AirlinePacks and drop in a folder with a manifest.json (see Docs/AUDIO_PACKS.md). A user pack with the same id replaces the bundled one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .screenBackground()
        .navigationTitle("Airlines")
        .largeTitle()
        .sheet(item: $detail) { pack in
            NavigationStack { AirlineDetailView(pack: pack) }
        }
    }
}

struct AirlineMonogram: View {
    let pack: AirlinePack
    var size: CGFloat = 52

    var body: some View {
        let color = Color(hex: pack.manifest.brandColorHex) ?? Theme.surfaceRaised
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let art = pack.manifest.artwork, let image = loadImage(pack.url(for: art)) {
                image.resizable().scaledToFit().padding(size * 0.14)
            } else {
                Text(pack.manifest.shortCode)
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private func loadImage(_ url: URL) -> Image? {
        #if os(iOS)
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: ui)
        #else
        return nil
        #endif
    }
}

private struct AirlineCard: View {
    let pack: AirlinePack
    let selected: Bool

    var body: some View {
        let recorded = pack.installedAudioFileCount()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AirlineMonogram(pack: pack, size: 44)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 20))
                }
            }
            Text(pack.manifest.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text(pack.manifest.languages.map { $0.uppercased() }.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            Text(recorded > 0 ? "\(recorded) recordings" : "Synthesized voice")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((recorded > 0 ? Theme.positive : Theme.textTertiary).opacity(0.15), in: Capsule())
                .foregroundStyle(recorded > 0 ? Theme.positive : Theme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: selected ? 1.5 : 1))
    }
}

struct AirlineDetailView: View {
    @EnvironmentObject var app: CompanionCoordinator
    @Environment(\.dismiss) private var dismiss
    let pack: AirlinePack

    var body: some View {
        let missing = pack.missingAudioFiles()
        List {
            Section {
                HStack(spacing: 16) {
                    AirlineMonogram(pack: pack, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pack.manifest.name).font(.system(size: 22, weight: .bold))
                        Text(pack.isUserProvided ? "User pack" : "Bundled pack").foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 6)
                Button {
                    app.updateSettings {
                        $0.airlineID = pack.id
                        if !pack.manifest.languages.contains($0.language) { $0.language = pack.manifest.defaultLanguage }
                    }
                    dismiss()
                } label: {
                    Label(pack.id == app.settings.airlineID ? "Selected" : "Use this airline", systemImage: "checkmark")
                }
                .disabled(pack.id == app.settings.airlineID)
            }
            Section("Languages") {
                ForEach(pack.manifest.languages, id: \.self) { lang in
                    HStack {
                        Text(Locale.current.localizedString(forLanguageCode: lang) ?? lang)
                        Spacer()
                        if lang == pack.manifest.defaultLanguage { Text("Default").foregroundStyle(Theme.textTertiary) }
                    }
                }
            }
            Section {
                LabeledContent("Recorded files", value: "\(pack.installedAudioFileCount())")
                LabeledContent("Missing files", value: "\(missing.count)")
                DisclosureGroup("Expected file paths") {
                    ForEach(missing.prefix(80), id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Missing recordings fall back to the synthesized system voice when that's on in Audio settings.")
            }
            if let d = pack.manifest.disclaimer {
                Section("Notice") { Text(d).font(.system(size: 13)).foregroundStyle(Theme.textSecondary) }
            }
            if let c = pack.manifest.credits {
                Section("Credits") { Text(c).font(.system(size: 13)) }
            }
        }
        .navigationTitle(pack.manifest.name)
        .inlineTitle()
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
