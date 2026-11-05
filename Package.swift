// swift-tools-version: 6.0
import PackageDescription

// AudiopapersKit is everything that doesn't need an Apple framework: the bridge into
// audiopapers_core, the reading session, Albert's logic and the view models. Keeping it free of
// them means it also builds and tests on Linux (scripts/test-linux.sh). On Apple platforms Python
// comes from the XCFramework scripts/bootstrap.sh fetches; on Linux, from the system's libpython.
#if os(Linux)
let pythonDependencies: [Target.Dependency] = []
let pythonTargets: [Target] = []
let pythonCSettings: [CSetting] = [.unsafeFlags(["-I/usr/include/python3.10"])]
let pythonLinkerSettings: [LinkerSetting] = [.linkedLibrary("python3.10")]
#else
let pythonDependencies: [Target.Dependency] = ["Python"]
let pythonTargets: [Target] = [.binaryTarget(name: "Python", path: "Frameworks/Python.xcframework")]
let pythonCSettings: [CSetting] = []
let pythonLinkerSettings: [LinkerSetting] = []
#endif

let package = Package(
    name: "AudiopapersKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "AudiopapersKit", targets: ["AudiopapersKit"])],
    targets: pythonTargets + [
        .target(
            name: "CPythonBridge",
            dependencies: pythonDependencies,
            cSettings: pythonCSettings,
            linkerSettings: pythonLinkerSettings
        ),
        .target(name: "AudiopapersKit", dependencies: ["CPythonBridge"]),
        .testTarget(name: "AudiopapersKitTests", dependencies: ["AudiopapersKit"]),
    ],
    swiftLanguageModes: [.v5]
)
