// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhotoBackup",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PhotoBackup", targets: ["PhotoBackup"]),
        .library(name: "PhotoBackupCore", targets: ["PhotoBackupCore"])
    ],
    targets: [
        .target(
            name: "PhotoBackupCore",
            path: "Sources/PhotoBackupCore"
        ),
        .executableTarget(
            name: "PhotoBackup",
            dependencies: ["PhotoBackupCore"],
            path: "Sources/PhotoBackup"
        ),
        .testTarget(
            name: "PhotoBackupCoreTests",
            dependencies: ["PhotoBackupCore"],
            path: "Tests/PhotoBackupCoreTests"
        )
    ]
)
