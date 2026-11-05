// swift-tools-version: 6.0
import PackageDescription

// Stand-ins for the Apple frameworks the app uses, declaring only what it calls, so the app's own
// code can be type-checked on Linux (scripts/typecheck-linux.sh). This catches mistakes in the app's
// own code, not misuse of Apple's APIs: only Xcode can do that.
let stubs = ["ImageIO", "Security", "UniformTypeIdentifiers", "OnnxRuntimeBindings", "UserNotifications", "BackgroundTasks", "AVFoundation", "Speech", "MediaPlayer", "UIKit", "PDFKit", "SwiftUI"]
let dependencies: [String: [Target.Dependency]] = [
    "Security": ["ImageIO"],
    "AVFoundation": ["ImageIO"],
    "Speech": ["AVFoundation"],
    "UIKit": ["ImageIO"],
    "PDFKit": ["UIKit"],
    "SwiftUI": ["UIKit"],
]

let package = Package(
    name: "AppleStubs",
    dependencies: [.package(name: "AudiopapersKit", path: "../..")],
    targets: stubs.map { .target(name: $0, dependencies: dependencies[$0] ?? [], swiftSettings: [.swiftLanguageMode(.v5)]) } + [
        .target(
            name: "App",
            dependencies: stubs.map { Target.Dependency(stringLiteral: $0) } + [.product(name: "AudiopapersKit", package: "AudiopapersKit")],
            exclude: ["Resources", "Assets.xcassets"],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-parse-as-library"])]
        ),
    ]
)
