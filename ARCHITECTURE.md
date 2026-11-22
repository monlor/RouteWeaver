# RouteWeaver Architecture

## Targets & Dependency Direction

```text
RouteWeaver (macOS SwiftUI App) ──▶ RoutingCore (Pure Domain, Config Renderer & Traffic Tracking)
RouteWeaverTunHelper (Privileged Root Helper, standalone)
RoutingCoreTests ──▶ RoutingCore
```

- **`RoutingCore`** (`Sources/RoutingCore/`): Platform-neutral pure Swift library with zero SwiftUI/AppKit dependencies. Owns `RoutingProfile`, `RuleLibrary`, `MihomoConfig` rendering/validation, `SubscriptionParser`, `SubscriptionUsage`, `ConnectionMonitor` (`ConnectionTracker`, `DNSLogParser`, `TrafficFormatter`), `TrafficHistory`, `ProfileStore`, `BundledResourceManager`, and `MihomoRelease`.
- **`RouteWeaver`** (`Sources/RouteWeaver/`): Native macOS SwiftUI application (macOS 13+). Owns views, state stores, process lifecycle management, macOS system/network inspection, and local Mihomo API communication.
- **`RouteWeaverTunHelper`** (`Sources/RouteWeaverTunHelper/`): Standalone privileged executable installed via `TunHelperManager` to run Mihomo in TUN / LAN Gateway mode (managing `utun`, port 53 DNS, and `net.inet.ip.forwarding`).

## State & Update-Rate Isolation

To avoid high-frequency updates triggering full-window SwiftUI re-renders, observable state is split by update rate and domain:

| Observable Store | Update Rate | Observed By |
|---|---|---|
| `AppState` | Low (profile edits, navigation, lifecycle transitions) | Root window, toolbar, sidebar, views |
| `EngineController` | Low (`phase`, `lastError`, `isTunActive`, `isGatewayActive`, `isAttachedExternalCore`) | Forwarded to `AppState` |
| `EngineLogStore` | High (350 ms log tailing) | `EngineLogCardView` in `SettingsCoreView` only |
| `ConnectionMonitorService` | High (WebSocket connection snapshots & batched DNS logs) | `RequestMonitorView`, `TrafficChartsView`, sidebar badge |
| `CoreBinaryStore` | Low (binary resolution, GitHub release check/download) | `CoreBinaryCardView` in `SettingsCoreView`; binary/version changes forwarded to `AppState` |
| `SubscriptionStore` | Medium (subscription fetch progress, cache, HostModule refresh) | `SubscriptionsView` (and its sheets), `OverviewSubscriptionUsageCard` |

`AppState.configValidationError` is cached and recomputed only when `profile` or `controllerPort` mutates, avoiding repeated `MihomoConfig.renderDetailed(...)` serialization during SwiftUI view evaluations.

## Engine Subsystems

`EngineController` (`Sources/RouteWeaver/EngineController.swift`) is a focused `@MainActor` process lifecycle state machine backed by four dedicated modules:

- **`EngineLogStore`** (`Sources/RouteWeaver/EngineLogStore.swift`): Memory ring truncation (140 KB cap), URL redaction, background serial queue disk persistence, and off-main-thread incremental log tailing.
- **`NetworkEnvironment`** (`Sources/RouteWeaver/NetworkEnvironment.swift`): Stateless macOS `SystemConfiguration` / `getifaddrs` / `sysctl` / BSD socket inspection (`interfaceDNSServers`, `isIPForwardingEnabled`, `detailedInterfaces`, `validateAvailablePorts`).
- **`ResourcePreloader`** (`Sources/RouteWeaver/ResourcePreloader.swift`): Missing provider/ruleset scanning, validated subscription cache syncing, legacy path migration, Geo file syncing to TUN workdir, and bounded concurrent downloading.
- **`RuntimeSessionStore`** (`Sources/RouteWeaver/RuntimeSessionStore.swift`): Atomic persistence of `RuntimeCoreSession`, PID file parsing, `proc_pidpath` verification, and graceful user/TUN process termination.

## Seams

- **`MihomoControlClient`** (`Sources/RouteWeaver/LocalController.swift`): Protocol seam over Mihomo's local REST & WebSocket external-controller API. Production adapter is `LocalController`; consumed by `AppState` and `ConnectionMonitorService` so orchestration logic can be tested with stub clients without spawning a live Mihomo binary.

## View Organization

Feature views with multiple modal sheets live in feature-scoped subdirectories:
- `Sources/RouteWeaver/Views/RuleGroups/`: `RuleGroupsView`, `AppPickerSheet`, `ProcessPickerSheet`, `SubconverterCatalogSheet`, `RuleSetPickerSheet`.
- `Sources/RouteWeaver/Views/Subscriptions/`: `SubscriptionsView`, `SubscriptionSheets`, `HostModuleSheets`, `NodeGroupSheets`.
- Standalone views: `MainView`, `OverviewView`, `RequestMonitorView`, `NetworkTargetsView`, `TrafficChartsView`, `SettingsCoreView`, `SharedComponents`.
