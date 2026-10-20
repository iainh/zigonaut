// swift-tools-version: 6.0
import Foundation
import PackageDescription
let coreLibraryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../zig-out/lib").standardizedFileURL.path
let package = Package(name: "ZigonautMac", platforms: [.macOS(.v15)], targets: [
    .systemLibrary(name: "ZigonautCore", path: "include"),
    .target(name: "ZigonautAccessibility", dependencies: ["ZigonautCore"], path: "Accessibility", linkerSettings: [.unsafeFlags(["-L", coreLibraryPath, "-lzigonaut-core"])]),
    .target(name: "ZigonautPaneLayout", dependencies: ["ZigonautCore", "ZigonautRestoration"], path: "PaneLayout", linkerSettings: [.unsafeFlags(["-L", coreLibraryPath, "-lzigonaut-core"])]),
    .target(name: "ZigonautRestoration", path: "Restoration"),
    .target(name: "ZigonautRenderSupport", dependencies: ["ZigonautCore"], path: "RenderSupport", linkerSettings: [.unsafeFlags(["-L", coreLibraryPath, "-lzigonaut-core"])]),
    .executableTarget(name: "ZigonautMac", dependencies: ["ZigonautCore", "ZigonautAccessibility", "ZigonautPaneLayout", "ZigonautRestoration", "ZigonautRenderSupport"], path: "Sources", linkerSettings: [.unsafeFlags(["-L", coreLibraryPath, "-lzigonaut-core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "ZigonautMacTests", dependencies: ["ZigonautCore", "ZigonautAccessibility", "ZigonautPaneLayout", "ZigonautRestoration", "ZigonautRenderSupport"], path: "Tests", linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", coreLibraryPath])])
])
