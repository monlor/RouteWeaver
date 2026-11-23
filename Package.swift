// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "RoutingCore", targets: ["RoutingCore"])]
var targets: [Target] = [
    .target(name: "RoutingCore"),
    .testTarget(name: "RoutingCoreTests", dependencies: ["RoutingCore"])
]
#if os(macOS)
products.append(.library(name: "TunHelperProtocol", targets: ["TunHelperProtocol"]))
products.append(.library(name: "RouteWeaverRuntime", targets: ["RouteWeaverRuntime"]))
products.append(.executable(name: "RouteWeaver", targets: ["RouteWeaver"]))
products.append(.executable(name: "RouteWeaverTunHelper", targets: ["RouteWeaverTunHelper"]))
targets.append(.target(name: "TunHelperProtocol"))
targets.append(.testTarget(name: "TunHelperProtocolTests", dependencies: ["TunHelperProtocol"]))
targets.append(.target(name: "RouteWeaverRuntime", dependencies: ["RoutingCore", "TunHelperProtocol"]))
targets.append(.testTarget(name: "RouteWeaverRuntimeTests", dependencies: ["RouteWeaverRuntime", "RoutingCore", "TunHelperProtocol"]))
targets.append(.executableTarget(name: "RouteWeaver", dependencies: ["RouteWeaverRuntime"]))
targets.append(.executableTarget(name: "RouteWeaverTunHelper", dependencies: ["TunHelperProtocol"]))
#endif

let package = Package(
    name: "RouteWeaver",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
