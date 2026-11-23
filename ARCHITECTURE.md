# RouteWeaver Architecture

## Targets & Dependency Direction

```text
RouteWeaver (thin @main executable) ──▶ RouteWeaverRuntime (macOS SwiftUI App & Runtime Library)
RouteWeaverRuntime ──▶ RoutingCore (Pure Domain, Config Renderer & Traffic/DNS Tracking)
RouteWeaverRuntime ──▶ TunHelperProtocol (Shared Privileged Helper Contract)
RouteWeaverTunHelper (Privileged Root Helper) ──▶ TunHelperProtocol

RoutingCoreTests ──▶ RoutingCore
TunHelperProtocolTests ──▶ TunHelperProtocol
RouteWeaverRuntimeTests ──▶ RouteWeaverRuntime
```

- **`RoutingCore`** (`Sources/RoutingCore/`): Platform-neutral pure Swift library with zero SwiftUI/AppKit dependencies. Owns `RoutingProfile` (including referential-integrity mutations), `RuleLibrary`, `MihomoConfig` rendering/validation (including `relayGroupName(for:)`), `SubscriptionParser`, `SubscriptionUsage`, `ConnectionMonitor` (`ConnectionTracker`, `DNSLogParser`, `DNSLogTracker`, `RelayChainResolver`, `RuleMatchDisplayIndex`, `TrafficFormatter`), `TrafficHistory`, `ProfileStore`, `BundledResourceManager`, `KillSwitchRules`, and `MihomoRelease`.
- **`TunHelperProtocol`** (`Sources/TunHelperProtocol/`): Pure Foundation/Darwin shared contract depended on by both `RouteWeaverRuntime` and `RouteWeaverTunHelper`. Centralizes `TunHelperPaths`, typed `TunHelperCommand` CLI encoding/parsing, `GatewaySysctlState`/`TunDNSState`/`KillSwitchPersistedState`/`KillSwitchStatusReport` codecs, LaunchDaemon/LaunchAgent plist builders (`TunHelperPlists`), PF kill-switch rule rendering (`TunHelperPFRules`), and `ProcessInspector` (`proc_pidpath`, `isProcessAlive`, `verifyRootExecutable`, `parseLaunchctlPid`).
- **`RouteWeaverRuntime`** (`Sources/RouteWeaverRuntime/`): Testable macOS SwiftUI library (macOS 13+). Owns views, state stores, process lifecycle orchestration, macOS system/network inspection, and local Mihomo control client.
- **`RouteWeaver`** (`Sources/RouteWeaver/main.swift`): Thin executable entrypoint invoking `RouteWeaverApp.main()`.
- **`RouteWeaverTunHelper`** (`Sources/RouteWeaverTunHelper/main.swift`): Audited setuid-root privileged executable using `TunHelperProtocol` to manage TUN, LAN Gateway, system DNS takeover, LaunchDaemon, and PF Kill Switch.

## State & Update-Rate Isolation

To avoid high-frequency updates triggering full-window SwiftUI re-renders, observable state is split by update rate and domain:

| Observable Store | Update Rate | Observed By |
|---|---|---|
| `AppState` | Low (profile edits, navigation, lifecycle transitions) | Root window, toolbar, sidebar, views |
| `EngineController` | Low (`phase`, `lastError`, `isTunActive`, `isGatewayActive`, `isLaunchdManaged`, `isAttachedExternalCore`) | Forwarded to `AppState` |
| `LiveProxyStore` | Low/Medium (live proxy groups, node selection, delay tests, rule-provider updates) | `OverviewView`, `RequestMonitorView` |
| `EngineLogStore` | High (350 ms log tailing) | `EngineLogCardView` in `SettingsCoreView` only |
| `ConnectionMonitorService` | High (connection snapshots & batched DNS logs; background queue history persistence) | `RequestMonitorView`, `TrafficChartsView`, sidebar badge |
| `CoreBinaryStore` | Low (binary resolution, GitHub release check/download/install) | `CoreBinaryCardView` in `SettingsCoreView`; binary/version changes forwarded to `AppState` |
| `SubscriptionStore` | Medium (subscription fetch progress, payload cache, HostModule refresh) | `SubscriptionsView` (and its sheets), `OverviewSubscriptionUsageCard` |

`AppState.configValidationError` and `AppState.ruleMatchDisplayIndex` are cached and recomputed only when `profile` (or `controllerPort`) mutates, avoiding repeated config rendering or rule-index rebuilds during SwiftUI view evaluations.

## Seams & Test Adapters

- **`CoreRuntimeDriver` / `CoreRuntimeHandle`** (`Sources/RouteWeaverRuntime/CoreRuntimeDriver.swift`): Protocol seam behind `EngineController` unifying the four execution modes (`LaunchDaemon`, `LaunchAgent`, `RouteWeaverTunHelper`, `posix_spawn`) plus session probing/reattachment. Production adapter is `MacOSRuntimeDriver`; test adapter is `FakeRuntimeDriver` in `RouteWeaverRuntimeTests`.
- **`MihomoControlClient`** (`Sources/RouteWeaverRuntime/LocalController.swift`): Protocol seam over Mihomo's local REST & WebSocket external-controller API, exposing high-level `AsyncThrowingStream`s (`connectionSnapshots()`, `dnsLogRecords(level:)`) so `URLSession` and WebSocket loops stay inside `LocalController`. Production adapter is `LocalController`; test adapter is `FakeMihomoControlClient` in `RouteWeaverRuntimeTests`.

## View Organization

Feature views with multiple sub-views or modal sheets live in feature-scoped subdirectories:
- `Sources/RouteWeaverRuntime/Views/Monitor/`: `RequestMonitorView`, `ConnectionListView`, `ConnectionInspectorView`, `DNSLogListView`, `DNSLogInspectorView`.
- `Sources/RouteWeaverRuntime/Views/RuleGroups/`: `RuleGroupsView`, `AppPickerSheet`, `ProcessPickerSheet`, `SubconverterCatalogSheet`, `RuleSetPickerSheet`.
- `Sources/RouteWeaverRuntime/Views/Subscriptions/`: `SubscriptionsView`, `SubscriptionSheets`, `HostModuleSheets`, `NodeGroupSheets`.
- Standalone views: `MainView`, `OverviewView`, `CustomDNSView`, `NetworkTargetsView`, `TrafficChartsView`, `SettingsCoreView`, `SharedComponents`.
