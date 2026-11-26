# RouteWeaver iOS 部署指南

本文档说明如何构建 `MihomoKit.xcframework` 内核、生成 Xcode 工程、配置签名与 App Group 并部署到 iPhone，以及配置不限速的 `lumzel/relay` 中继服务。

---

## 1. 环境准备

- macOS + Xcode 15+（包含 iOS SDK）
- Go 1.24+（`brew install go`）
- XcodeGen（`brew install xcodegen`）

---

## 2. 构建 MihomoKit.xcframework

在项目根目录执行：

```bash
./iOS/Scripts/build-mihomo-ios.sh
```

脚本会自动检查并安装 `gomobile` / `gobind`、拉取 `github.com/metacubex/mihomo` 依赖，并编译输出：

- `iOS/Frameworks/MihomoKit.xcframework`（支持真机 `ios` 与模拟器 `iossimulator`）

> 提示：在未构建 `MihomoKit.xcframework` 之前，`iOS/Shared/MihomoEngineAdapter.swift` 会自动启用编译安全的 stub 回退模式，确保 Xcode 工程可直接编译运行；构建出 `MihomoKit.xcframework` 后再重新生成并编译，即可自动切换为完整 Mihomo 内核。

---

## 3. 生成 Xcode 工程

```bash
cd iOS && xcodegen generate
```

生成完成后打开 `iOS/RouteWeaver.xcodeproj`。

---

## 4. Xcode Signing 与 App Group 配置

`RouteWeaver` iOS 包含主应用与 `PacketTunnel`（`NEPacketTunnelProvider`）两个 Target，需要保持一致的签名团队与 App Group：

1. **Signing & Capabilities（两个 Target 均需配置）**：
   - 选中主应用 Target 与 `PacketTunnel` Extension Target。
   - 选择你的 Apple Developer **Team**，并修改唯一的 **Bundle Identifier**（例如 `com.example.routeweaver` 与 `com.example.routeweaver.PacketTunnel`）。
2. **App Groups**：
   - 在两个 Target 的 **App Groups** 中添加并勾选同一个组 ID（例如 `group.com.example.routeweaver`），用于主应用与 `PacketTunnel` 共享配置和状态。
3. **Network Extensions**：
   - 确保两个 Target 已开启 **Network Extensions** capability，并勾选 **Packet Tunnel**（以及主应用所需的 **Personal VPN**）。

---

## 5. 部署到 iPhone 真机

1. 使用数据线连接 iPhone，并在 iPhone 上启用 **设置 -> 隐私与安全性 -> 开发者模式**。
2. 在 Xcode 顶部设备栏选择你的 iPhone，按 `Cmd + R` 编译安装。
3. 首次运行如果提示未受信任的开发者证书，前往 iPhone **设置 -> 通用 -> VPN 与设备管理** 中信任开发者证书。
4. 首次启动隧道时，在系统弹窗中允许添加 VPN 配置。

---

## 6. Docker 部署 `ghcr.io/lumzel/relay:latest`（不限速配置）

在公网服务器或 Docker 宿主机上部署不限速、不限总流量的中继服务时，将单路由速率限制设为 `0`、总流量配额设为 `uint64` 最大值 `18446744073709551615`：

```bash
docker run -d \
  --name lumzel-relay \
  --restart unless-stopped \
  -p 8443:8443 \
  -e RELAY_ROUTE_BYTES_PER_SEC=0 \
  -e RELAY_ROUTE_BYTES_TOTAL=18446744073709551615 \
  ghcr.io/lumzel/relay:latest
```

如使用 `docker-compose.yml`：

```yaml
services:
  relay:
    image: ghcr.io/lumzel/relay:latest
    container_name: lumzel-relay
    restart: unless-stopped
    ports:
      - "8443:8443"
    environment:
      RELAY_ROUTE_BYTES_PER_SEC: "0"
      RELAY_ROUTE_BYTES_TOTAL: "18446744073709551615"
```
