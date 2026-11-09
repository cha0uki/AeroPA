import SwiftUI
import AeroPACore

@main
struct AeroPAApp: App {
    @StateObject private var coordinator = AppEnvironment.makeCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { coordinator.startMonitoring() }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: coordinator.sceneDidBecomeActive()
            case .background: coordinator.sceneDidEnterBackground()
            default: break
            }
        }
    }
}

/// Builds the production object graph. The only place concrete types are chosen.
enum AppEnvironment {
    static func makeCoordinator() -> CompanionCoordinator {
        let bundle = Bundle.main
        let userPacks = userPacksDirectory()
        let locations = ResourceLocations(
            bundledAirlines: bundle.url(forResource: "Airlines", withExtension: nil),
            shared: bundle.url(forResource: "Shared", withExtension: nil),
            userAirlines: userPacks)
        return CompanionCoordinator(locations: locations,
                                    logStore: FlightLogStore(),
                                    output: AVAudioOutput())
    }

    /// Documents/AirlinePacks. Visible in the Files app (UIFileSharingEnabled),
    /// so users can drop in their own original or licensed recordings.
    static func userPacksDirectory() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("AirlinePacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

struct RootView: View {
    @EnvironmentObject var app: CompanionCoordinator

    var body: some View {
        TabView {
            NavigationStack { DashboardView() }
                .tabItem { Label("Flight", systemImage: "airplane") }
            NavigationStack { LiveFlightView() }
                .tabItem { Label("Live", systemImage: "list.bullet.rectangle") }
            NavigationStack { AirlinesView() }
                .tabItem { Label("Airlines", systemImage: "square.grid.2x2") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
    }
}
