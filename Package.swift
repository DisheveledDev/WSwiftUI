// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "WSwiftUI",
  platforms: [
    .iOS(.v13), .macOS(.v14)
  ],
  products: [
    .library(name: "WSwiftUI", targets: ["WSwiftUI"]),
    .executable(name: "WSwiftUITest", targets: ["WSwiftUITest"])
  ],
  dependencies: [
    // …
  ],
  targets: [
    .target(name: "WSwiftUI", path: "Sources/WSwiftUI"),
    .executableTarget(name: "WSwiftUITest",dependencies: ["WSwiftUI"], path: "Sources/WSwiftUITest"),
    .testTarget(name: "WSwiftUITests", dependencies: ["WSwiftUI"], path: "Tests/WSwiftUITests"),
  ]
)
