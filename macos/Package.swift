// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ZigonautMac", platforms: [.macOS(.v15)], targets: [
    .systemLibrary(name: "ZigonautCore", path: "include"),
    .executableTarget(name: "ZigonautMac", dependencies: ["ZigonautCore"], path: "Sources", linkerSettings: [.unsafeFlags(["-L", "../zig-out/lib", "-lzigonaut-core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
])
