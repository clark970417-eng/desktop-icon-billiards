// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DesktopIconBilliards",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BilliardsCore", targets: ["BilliardsCore"]),
        .executable(name: "DesktopIconBilliards", targets: ["DesktopIconBilliards"])
    ],
    targets: [
        .target(name: "BilliardsCore"),
        .executableTarget(name: "DesktopIconBilliards", dependencies: ["BilliardsCore"]),
        .testTarget(name: "BilliardsCoreTests", dependencies: ["BilliardsCore"])
    ]
)
