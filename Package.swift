// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kagami",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kagami", targets: ["Kagami"])
    ],
    targets: [
        // Objective-C Header für die private CGVirtualDisplay-API (CoreGraphics).
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "Kagami",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/Kagami",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),
    ]
)
