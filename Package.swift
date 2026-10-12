// swift-tools-version:5.9
import PackageDescription

// InkbookCore is platform-independent (iOS, macOS, Linux) so the notebook model, storage,
// brush math, Goodnotes import and agent bridge can be unit-tested without an iPad.
// The iPad UI lives in App/ and is built through project.yml (XcodeGen).
let package = Package(
    name: "InkbookCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "InkbookCore", targets: ["InkbookCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "InkbookCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .testTarget(
            name: "InkbookCoreTests",
            dependencies: ["InkbookCore"]
        ),
    ]
)
