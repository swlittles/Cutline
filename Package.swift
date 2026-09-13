// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Cutline",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cutline", targets: ["Cutline"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "CutlineCore"),
        .executableTarget(name: "Cutline", dependencies: ["CutlineCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "CutlineVerify", dependencies: ["CutlineCore"]),
        .testTarget(name: "CutlineCoreTests", dependencies: ["CutlineCore"], resources: [.copy("Fixtures")])
    ]
)
