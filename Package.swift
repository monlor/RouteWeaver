// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "RoutingCore", targets: ["RoutingCore"])]
var targets: [Target] = [
    .target(name: "RoutingCore"),
    .testTarget(name: "RoutingCoreTests", dependencies: ["RoutingCore"])
]
#if os(macOS)
products.append(.executable(name: "RouteWeaver", targets: ["RouteWeaver"]))
targets.append(.executableTarget(name: "RouteWeaver", dependencies: ["RoutingCore"]))
#endif

let package = Package(
    name: "RouteWeaver",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
