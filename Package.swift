// swift-tools-version:5.8
// AeroPACore: platform-independent flight-companion logic.
// The iOS app target (generated from project.yml) depends on this package.
import PackageDescription

let package = Package(
    name: "AeroPACore",
    defaultLocalization: "en",
    platforms: [.iOS("17.0"), .macOS("13.0")],
    products: [
        .library(name: "AeroPACore", targets: ["AeroPACore"]),
        .executable(name: "aeropa-udp-replay", targets: ["AeroPAUDPReplay"])
    ],
    targets: [
        .target(name: "AeroPACore", path: "Sources/AeroPACore"),
        // Dev tool: replays a captured/synthetic ForeFlight-format stream over UDP
        // so the real AeroflyUDPProvider can be exercised without Aerofly.
        .executableTarget(name: "AeroPAUDPReplay", dependencies: ["AeroPACore"], path: "Sources/AeroPAUDPReplay"),
        .testTarget(
            name: "AeroPACoreTests",
            dependencies: ["AeroPACore"],
            path: "Tests/AeroPACoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
