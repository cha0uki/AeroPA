import SwiftUI
import AeroPACore

struct LiveFlightView: View {
    @EnvironmentObject var app: CompanionCoordinator
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "All", audio = "Audio", events = "Events"
    }

    private var entries: [TimelineEntry] {
        let list = app.timeline.reversed()
        switch filter {
        case .all: return Array(list)
        case .audio: return list.filter { [.announcement, .callout, .sound].contains($0.kind) }
        case .events: return list.filter { [.phase, .event, .connection, .warning].contains($0.kind) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(text: "Current phase")
                            Text(app.phase.displayName).font(.system(size: 24, weight: .bold, design: .rounded))
                        }
                        Spacer()
                        ConnectionPill()
                    }
                }
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if entries.isEmpty {
                    Text(app.isActive ? "Waiting for the first event…" : "Start the companion to begin the flight timeline.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { TimelineRow(entry: $0) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .screenBackground()
        .navigationTitle("Live Flight")
        .largeTitle()
    }
}

struct TimelineRow: View {
    let entry: TimelineEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.14), in: Circle())
                Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.title)
                        .font(.system(size: entry.kind == .phase ? 16 : 15, weight: entry.kind == .phase ? .bold : .semibold))
                    Spacer()
                    Text(entry.date, style: .time)
                        .font(Theme.mono(12, weight: .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let d = entry.detail {
                    Text(d).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(4)
                }
            }
            .padding(.bottom, 18)
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch entry.kind {
        case .phase: return "airplane"
        case .event: return "smallcircle.filled.circle"
        case .announcement: return "speaker.wave.2.fill"
        case .callout: return "headphones"
        case .sound: return "bell.fill"
        case .warning: return "exclamationmark"
        case .connection: return "antenna.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .phase, .announcement: return Theme.accent
        case .callout: return Theme.positive
        case .warning: return Theme.caution
        case .connection, .event, .sound: return Theme.textSecondary
        }
    }
}
