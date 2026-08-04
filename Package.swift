// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Castr",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "CastrCore", targets: ["CastrCore"]),
        .library(name: "CastrBLE", targets: ["CastrBLE"]),
        .executable(name: "castr-collect", targets: ["castr-collect"]),
        .executable(name: "castr-analyze", targets: ["castr-analyze"]),
        .executable(name: "castr-selftest", targets: ["castr-selftest"]),
    ],
    targets: [
        // Pure Foundation: frame parsing, CSV, synthetic data. No CoreBluetooth,
        // no UI, no platform assumptions — this is the testable core.
        .target(name: "CastrCore"),

        // CoreBluetooth transport. Builds for both macOS and iOS.
        .target(name: "CastrBLE", dependencies: ["CastrCore"]),

        // macOS command-line collector.
        //
        // The linker flags embed an Info.plist directly into the __TEXT segment.
        // Without it, CoreBluetooth on macOS 11+ can return .unauthorized for a
        // bare CLI binary *silently*, with no permission prompt ever shown.
        .executableTarget(
            name: "castr-collect",
            dependencies: ["CastrCore", "CastrBLE"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/castr-collect-Info.plist",
                ])
            ]
        ),

        // Offline analysis. No CoreBluetooth, so it builds anywhere Swift does.
        .executableTarget(name: "castr-analyze", dependencies: ["CastrCore"]),

        // Not a .testTarget: XCTest ships inside Xcode, not the Command Line
        // Tools, so `swift test` cannot run on a CLT-only machine — which is
        // exactly the setup this project targets. A plain executable runs
        // anywhere: `swift run castr-selftest`.
        .executableTarget(name: "castr-selftest", dependencies: ["CastrCore"]),
    ]
)
