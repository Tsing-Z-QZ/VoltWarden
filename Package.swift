// swift-tools-version: 6.2
import PackageDescription
import Foundation

// The SwiftPM/Xcode backend can stamp the deployment target as the linked SDK.
// AppKit then chooses legacy controls even though Swift compiled against a new SDK.
let sdkQuery = Process()
let sdkOutput = Pipe()
sdkQuery.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
sdkQuery.arguments = ["--sdk", "macosx", "--show-sdk-version"]
sdkQuery.standardOutput = sdkOutput
try sdkQuery.run()
sdkQuery.waitUntilExit()
let macOSSDKVersion = String(decoding: sdkOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard sdkQuery.terminationStatus == 0,
      !macOSSDKVersion.isEmpty,
      macOSSDKVersion.allSatisfy({ $0.isNumber || $0 == "." }) else {
    fatalError("Select a valid Xcode macOS SDK with xcode-select before building Stasis.")
}
let nativeUILinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                  "-Xlinker", "14.8", "-Xlinker", macOSSDKVersion])
]

let package = Package(
    name: "StasisCustom",
    platforms: [.macOS("14.8")],
    products: [
        .executable(name: "stasis-custom", targets: ["StasisExecutable"]),
        .executable(name: "stasis-reader-helper", targets: ["ReaderHelper"]),
        .executable(name: "stasis-charging-helper", targets: ["ChargingHelperExecutable"]),
    ],
    dependencies: [
        .package(path: "Vendor/SMCKit"),
    ],
    targets: [
        .target(
            name: "Defaults",
            path: "Vendor/Defaults",
            exclude: ["Documentation.docc", "LICENSE"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(name: "ChargingPolicyTests", dependencies: ["smc_power", "StasisExecutable"], path: "Tests/ChargingPolicyTests"),
        .target(
            name: "smc_power",
            dependencies: ["SMCKit"],
            path: "SMCPower"
        ),
        .executableTarget(
            name: "StasisExecutable",
            dependencies: [
                "Defaults",
                "smc_power",
            ],
            path: "Stasis",
            exclude: ["Assets.xcassets", "L10n"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ],
            linkerSettings: nativeUILinkerSettings
        ),
        .executableTarget(
            name: "ReaderHelper",
            dependencies: ["smc_power"],
            path: "Helper",
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "ChargingHelperExecutable",
            dependencies: ["smc_power"],
            path: "ChargingHelper",
            exclude: ["com.srimanachanta.stasis.charging-helper.native.plist"]
        ),
    ]
)
