// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Sentinel",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/steelbrain/IPCamKit.git", exact: "0.3.2")
  ],
  targets: [
    .executableTarget(
      name: "Sentinel",
      dependencies: [.product(name: "IPCamKit", package: "IPCamKit")]
    )
  ]
)
