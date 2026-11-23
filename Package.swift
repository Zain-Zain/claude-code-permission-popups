// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PermissionPopups",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PermissionCore"),
        .executableTarget(name: "permission-hook", dependencies: ["PermissionCore"]),
        .executableTarget(name: "PermissionApp", dependencies: ["PermissionCore"]),
        .testTarget(
            name: "PermissionCoreTests",
            dependencies: ["PermissionCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
