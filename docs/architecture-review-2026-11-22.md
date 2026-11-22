# RouteWeaver 架构检查报告（2026-11-22）

## 现状概览

- **Targets**：`RoutingCore`（纯领域与配置渲染库，5,000+ 行，30 个单元测试 0.04s 全绿）、`RouteWeaver`（macOS App，11,500+ 行，0 个测试）、`RouteWeaverTunHelper`（特权 TUN 辅助进程，511 行）。
- **核心热点（按文件行数）**：
  - `Sources/RouteWeaver/EngineController.swift`：**1,662 行**（超过 1,000 行行动阈值）
  - `Sources/RouteWeaver/AppState.swift`：**1,365 行**（超过 1,000 行行动阈值，40+ 个 `@Published`）
  - `Sources/RouteWeaver/Views/RuleGroupsView.swift`：**1,279 行**
  - `Sources/RouteWeaver/Views/SubscriptionsView.swift`：**1,070 行**
  - `Sources/RoutingCore/RuleLibrary.swift`：**1,045 行**
  - `Sources/RoutingCore/MihomoConfig.swift`：**1,033 行**
  - `Sources/RouteWeaver/Views/RequestMonitorView.swift`：**988 行**
  - `Sources/RoutingCore/ConnectionMonitor.swift`：**944 行**
- **结构信号**：
  - 全仓 `Sources/` 中 **0 个 `protocol`**（应用层无接缝，无法在测试中替换网络/进程依赖）。
  - `AppState` 将 `engine.objectWillChange` 无差别转发给所有视图，而 `EngineController` 每 350ms 轮询写入 `@Published var log`，导致高频日志变化广播到全应用所有视图与 `MenuBarExtra`。
  - `AppState.configValidationError` 在每次视图计算 `canStart` / `readinessItems` 时实时执行 `MihomoConfig.renderDetailed(...)`（完整配置序列化）。

---

## Engine Log & Update-Rate Isolation（核心日志与高频状态隔离）  [Strong]

Files: `Sources/RouteWeaver/EngineController.swift` (1,662 lines), `Sources/RouteWeaver/AppState.swift` (1,365 lines), `Sources/RouteWeaver/Views/SettingsCoreView.swift` (576 lines)
Signal: 高频变化状态发布给全局观察者（`EngineController.log` 每 350ms 触发一次，经 `AppState` 转发给全部 9 个视图）；`@MainActor` 上存在同步文件写入（`persistLogChunk`）与重复计算校验（`configValidationError`）。
Problem: 只要 Mihomo 核心在运行，`startLogTail` 每 350ms 更新一次 `EngineController.log`，`AppState` 中的 `engine.objectWillChange.sink { self?.objectWillChange.send() }` 会立刻触发整个窗口（总览、规则组、订阅、网络目标、菜单栏等）重新求值 `body`，连带触发 `canStart` / `readinessItems` 重复调用 `MihomoConfig.renderDetailed`。修改日志缓冲或校验逻辑时，性能影响会扩散到全应用。
Proposal: 抽出独立的日志模块 `EngineLogStore`，隔离高频日志状态与文件 I/O，并移除 `AppState` 对 `engine.objectWillChange` 的盲目转发：

```swift
@MainActor
final class EngineLogStore: ObservableObject {
    @Published private(set) var text: String = ""
    func prepareLogFile(at url: URL)
    func loadTail(from url: URL)
    func startTailing(url: URL, shouldContinue: @escaping @MainActor () -> Bool)
    func stopTailing()
    func append(_ raw: String, persistTo url: URL?)
    func clear()
}
```

Benefits: 只有真正显示日志的 `SettingsCoreView` 观察 `EngineLogStore`，其它页面不再因日志刷新而无效重绘；日志持久化移到后台串行队列避免阻塞主线程；`AppState` 仅按 `engine.$phase` / `isTunActive` / `isGatewayActive` / `lastError` 精确同步并缓存 `configValidationError`，显著降低主线程 CPU 占用。
Proof of same behavior: `swift test` 保持 30/30 通过；新增 `EngineLogStore` 单元测试验证 URL 脱敏、140KB 截断与增量读取；通过 Lumzel 应用预览构建启动并验证启停核心、后台接管、热重载及设置页实时日志滚动与清空行为完全一致。
Plan:
1. 新增 `Sources/RouteWeaver/EngineLogStore.swift`（纯新增、独立编译），实现脱敏、截断、增量 tail 与后台持久化。
2. `EngineController` 改由 `let logStore = EngineLogStore()` 承载日志，`SettingsCoreView` 直接观察 `state.engine.logStore`。
3. 移除 `AppState` 对 `engine.objectWillChange` 的全量转发，改为精确订阅核心状态变化并缓存 `configValidationError`。

---

## Engine Subsystem Decomposition（内核控制器子系统拆分）  [Strong]

Files: `Sources/RouteWeaver/EngineController.swift` (1,662 lines), `Sources/RouteWeaver/AppState.swift` (1,365 lines)
Signal: 单文件 1,662 行（远超 1,000 行阈值）；单个 `@MainActor` 类混杂 5 种不同职责（系统网卡/DNS/端口探测、订阅与规则集预下载、日志管理、会话/PID 持久化、进程生命周期状态机）。
Problem: 目前 `AppState` 要查系统网卡或 IP 转发状态，必须静态调用 `EngineController.detailedInterfaces()`、`EngineController.interfaceDNSServers()`、`EngineController.isIPForwardingEnabled()`；修改预下载策略或端口探测时，必须在 1,600+ 行进程状态机代码中穿行，极易误触 `generation` / `cleanup` 等并发状态。
Proposal: 将 `EngineController` 中三个内聚且低耦合的子系统下沉为深模块，让 `EngineController` 回归纯粹的进程生命周期状态机（预计降至 ~550 行）：

```swift
enum NetworkEnvironment {
    static func interfaceDNSServers() -> [String: [String]]
    static func isIPForwardingEnabled() -> Bool
    static func detailedInterfaces() -> [NetworkInterfaceInfo]
    static func activeInterfaceNames() -> [String]
    static func validateAvailablePorts(in configData: Data) -> Result<Void, EnginePreflightError>
}

struct ResourcePreloader: Sendable {
    func findMissing(_ items: [PreloadResourceItem], in targetDir: URL, syncFrom: URL?, subscriptionCacheDir: URL) -> PreloadPlan
    func download(_ items: [PreloadResourceItem], to targetDir: URL, subscriptionCacheDir: URL) async -> PreloadReport
}

struct RuntimeSessionStore: Sendable {
    func load() -> RuntimeCoreSession?
    func save(_ session: RuntimeCoreSession)
    func clear(session: RuntimeCoreSession?)
    static func isProcessAlive(_ pid: pid_t) -> Bool
    static func stopProcess(pid: pid_t, isTun: Bool) async -> Bool
}
```

Benefits: 强局部性——改网卡/端口探测只改 `NetworkEnvironment`，改预下载缓存策略只改 `ResourcePreloader`，改后台接管/退出清理只改 `RuntimeSessionStore`；三个模块均不依赖 `@MainActor`，可直接脱离 UI 编写单元测试。
Proof of same behavior: `swift test` 全部通过；通过 Lumzel 应用预览验证正常模式启动、配置校验、预下载、热重载、退出保持后台运行与重新打开接管流程一致。
Plan:
1. 抽出 `Sources/RouteWeaver/NetworkEnvironment.swift`（含 `NetworkInterfaceInfo`、DNS/IP 转发/网卡枚举与端口检查），切换 `EngineController` 与 `AppState` 调用方。
2. 抽出 `Sources/RouteWeaver/ResourcePreloader.swift`，迁出 `missingPreloadItems` 与 `downloadPreloadResources`。
3. 抽出 `Sources/RouteWeaver/RuntimeSessionStore.swift`，迁出 `RuntimeCoreSession` 读写、PID 轮询辅助与进程信号终止逻辑。

---

## AppState Domain Store Extraction（按领域拆分 AppState 上帝模型）  [Strong]

Files: `Sources/RouteWeaver/AppState.swift` (1,365 lines), `Sources/RouteWeaver/Views/SettingsCoreView.swift`, `Sources/RouteWeaver/Views/SubscriptionsView.swift`, `Sources/RouteWeaver/Views/OverviewView.swift`
Signal: 视图模型 1,365 行、40+ 个 `@Published` 属性，涵盖 8 个独立业务领域（配置方案文档、内核更新、订阅与 HostModule、实时节点组轮询、核心启停/热重载、系统与 TUN 权限、就绪态评估、剪贴板/提示）。
Problem: 新增一个订阅字段或调整内核更新逻辑都要改动全应用共享的 `AppState`，任何一处 `@Published` 变更（如单个订阅拉取进度 `fetchingSubscriptionIDs` 或内核更新检查 `isCheckingCoreUpdate`）都会触发无关页面重绘；同时 `NSOpenPanel` / `NSSavePanel` / `NSAlert` 弹窗逻辑也直接混在状态方法里。
Proposal: 保持 `AppState` 作为轻量协调器与 `profile` 文档宿主，分批拆出内聚度最高的独立子 Store（每个视图只观察自己需要的子 Store）：

```swift
@MainActor
final class CoreBinaryStore: ObservableObject {
    @Published private(set) var binary: URL?
    @Published private(set) var source: CoreBinarySource = .none
    @Published private(set) var version: String?
    @Published private(set) var latestRelease: MihomoRelease?
    @Published private(set) var isCheckingUpdate = false
    @Published private(set) var isUpdating = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    func refresh(); func checkUpdate(); func installUpdate(isEngineRunning: Bool) async; func resetToBundled()
}

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var cache: [UUID: SubscriptionNodeCacheEntry] = [:]
    @Published private(set) var fetchingIDs: Set<UUID> = []
    @Published private(set) var fetchErrors: [UUID: String] = [:]
    @Published private(set) var updatingHostModuleIDs: Set<UUID> = []
    func load(from directory: URL)
    func fetch(_ sub: ProxySubscription, fallbackProxyPort: Int?, in directory: URL) async
}
```

Benefits: `AppState` 体积减半，每个领域的异步任务和状态完全局部化；视图依赖边界变清晰（例如 `SubscriptionsView` 观察 `SubscriptionStore`，`SettingsCoreView` 观察 `CoreBinaryStore`）。
Proof of same behavior: `swift test` 通过；通过 Lumzel 应用预览逐一验证内核版本检查/更新、订阅拉取与缓存保留、HostModule 更新、切换配置目录重新加载缓存。
Plan:
1. 抽出 `CoreBinaryStore` 并接入 `AppState` 与 `SettingsCoreView`。
2. 抽出 `SubscriptionStore` 并接入 `AppState` 与 `SubscriptionsView`。
3. （可选后续）抽出 `LiveProxyStore` 接管 `activeProxyGroups`、`groupStatus`、节点切换与延迟测速轮询。

---

## LocalController Seam for App-Layer Testing（为本地控制接口引入可测试接缝）  [Worth exploring]

Files: `Sources/RouteWeaver/LocalController.swift` (306 lines), `Sources/RouteWeaver/ConnectionMonitorService.swift` (345 lines), `Sources/RouteWeaver/AppState.swift` (1,365 lines)
Signal: 全仓 0 个 `protocol`，`RouteWeaver` 应用目标没有可替换依赖的接缝，导致热重载、节点切换与连接监控回退逻辑无法被自动化测试覆盖。
Problem: `ConnectionMonitorService` 和 `AppState` 直接持有具体类型 `LocalController`，任何测试都必须真正启动一个 Mihomo 进程并监听本机端口，导致应用层编排逻辑零测试覆盖。
Proposal: 为 Mihomo 本地控制接口建立 `MihomoControlClient` 协议，提供生产适配器 `LocalController` 与测试适配器 `FakeMihomoControlClient`：

```swift
protocol MihomoControlClient: Sendable {
    var port: Int { get }
    var secret: String { get }
    var trackedGroups: [String] { get }
    func reloadConfig(payload: Data) async throws
    func proxyGroups() async throws -> [String: LocalController.ProxyGroup]
    func select(group: String, node: String) async throws
    func testGroupDelay(group: String) async throws -> [String: Int]
    func connections() async throws -> MihomoConnectionsSnapshot
    func closeConnection(id: String) async throws
    func closeAllConnections() async throws
}
```

Benefits: 让应用层最容易回归的编排逻辑（热重载失败回滚、WebSocket 断开降级 HTTP 轮询、节点切换状态同步）能够在不启动外部进程的情况下 100% 单元测试。
Proof of same behavior: 现有 30 个 `RoutingCoreTests` 保持全绿，并新增针对热重载与连接监控回退路径的单元测试。
Plan:
1. 在 `LocalController.swift` 定义 `MihomoControlClient` 并让 `LocalController` 遵循它。
2. `ConnectionMonitorService` 与 `AppState` 改为依赖 `any MihomoControlClient`。
3. 添加测试适配器与核心编排单元测试。

---

## Feature-Scoped View Folders（超大视图文件按功能拆分子文件）  [Worth exploring]

Files: `Sources/RouteWeaver/Views/RuleGroupsView.swift` (1,279 lines), `Sources/RouteWeaver/Views/SubscriptionsView.swift` (1,070 lines)
Signal: 两个视图文件超过 1,000 行，各自内嵌 4–6 个独立 Sheet 视图。
Problem: 调整某个弹窗（如 `SubconverterCatalogSheet`、`NodeGroupEditorSheet`、`RegionalGroupsGeneratorSheet`）需要在上千行文件中定位，代码评审与并发修改冲突多。
Proposal: 纯文件组织重构，不改变任何外部接口：
- `Views/RuleGroups/`：`RuleGroupsView.swift`、`AppPickerSheet.swift`、`ProcessPickerSheet.swift`、`SubconverterCatalogSheet.swift`、`RuleSetPickerSheet.swift`。
- `Views/Subscriptions/`：`SubscriptionsView.swift`、`SubscriptionSheets.swift`、`NodeGroupEditorSheet.swift`、`RegionalGroupsGeneratorSheet.swift`、`HostModuleSheets.swift`。
Benefits: 提升代码可读性与修改局部性，降低 Swift 编译器类型检查单文件压力。
Proof of same behavior: 零逻辑变更，编译通过且界面预览截图与交互完全一致。
Plan:
1. 拆分 `Views/RuleGroupsView.swift` 为 `Views/RuleGroups/`（1 commit）。
2. 拆分 `Views/SubscriptionsView.swift` 为 `Views/Subscriptions/`（1 commit）。

---

## 首选推荐（Top Recommendation）

推荐按顺序先做 **#1（Engine Log & Update-Rate Isolation）**，紧接着做 **#2（Engine Subsystem Decomposition）**：

1. **#1 收益最高且风险最低**：它直接消除每 350ms 触发一次的全应用 SwiftUI 无效重绘与主线程同步磁盘写日志，同时为 #2 拆分 `EngineController` 腾出最干净的切口。
2. **#2 紧随其后**：把 `EngineController.swift` 从 1,662 行瘦身到 ~550 行，拆出 `NetworkEnvironment`、`ResourcePreloader`、`RuntimeSessionStore` 三个无 UI 依赖的深模块，彻底理顺 `AppState` 与 `EngineController` 的边界。

完成 #1 和 #2 后，再决定是否继续推进 **#3（AppState 拆分子 Store）**。

---

## 评估后暂不推荐（Considered, not recommended）

- **拆分 `RoutingCore/MihomoConfig.swift`（1,033 行）与 `ConnectionMonitor.swift`（944 行）**：虽然行数偏高，但两者均为内聚的纯领域模块，无 UI/IO 副作用，且已有 30 个快速单元测试（0.04s）兜底；当前维护成本不高，暂不必为了行数强拆。
- **拆分 `RoutingCore/RuleLibrary.swift`（1,045 行）**：其中约 470 行是静态 `SubconverterCatalog` 预设清单数据；等后续预设规模继续膨胀时再单独提取数据文件即可。
- **将 `ObservableObject` 全量迁移至 `@Observable`**：`Package.swift` 当前最低支持 `.macOS(.v13)`，而 `@Observable` 需要 macOS 14+；在确定放弃 macOS 13 支持前不建议迁移。
