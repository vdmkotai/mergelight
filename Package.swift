// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Mergelight",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Mergelight", targets: ["Mergelight"])],
  targets: [
    // Everything that can be tested without a window server: models, GitHub API, refresh logic.
    .target(name: "MergelightKit"),
    // AppKit shell: status item, panel, settings, notifications.
    .executableTarget(name: "Mergelight", dependencies: ["MergelightKit"]),
    .testTarget(
      name: "MergelightKitTests", dependencies: ["MergelightKit"], resources: [.copy("Fixtures")]),
  ]
)
