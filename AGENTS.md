# RouteWeaver Agent Rules

## 应用启动、停止与重启（必须使用应用预览）

本项目已在 `.lumzel/config.json` 中配置了 Lumzel 应用预览服务（`appId: "routeweaver"`），其构建与启动命令为 `./Scripts/build-app.sh && open -g -n ./dist/RouteWeaver.app`。

在需要构建并启动、停止或重启 RouteWeaver 应用时，**必须直接调用应用预览工具**，禁止在终端中手动执行 `./Scripts/build-app.sh && open ...` 或手动 `open`/`killall` 启动和关闭应用进程：

- **查看状态**：调用 `app_preview_list`（查看服务 `routeweaver` 当前运行状态）。
- **启动应用**：调用 `app_preview_start`（`appId: "routeweaver"`）。
- **停止应用**：调用 `app_preview_stop`（`appId: "routeweaver"`）。
- **重新构建并重启应用**：修改代码后需要重新编译并启动生效时，直接调用 `app_preview_restart`（`appId: "routeweaver"`）。
- **查看构建与运行日志**：调用 `app_preview_logs`（`appId: "routeweaver"`）。

> 说明：单独运行单元测试时仍可执行 `swift test`；一旦涉及打包、启动、停止或重启 `RouteWeaver.app`，一律通过上述应用预览工具操作。
