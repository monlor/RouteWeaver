import SwiftUI

@main
struct RouteWeaveriOSApp: App {
    @StateObject private var model = MobileAppModel()
    @State private var selectedTab: AppTab = .home

    enum AppTab: Hashable {
        case home
        case proxiesAndRules
        case monitorAndStats
        case settings
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem {
                        Label("总览", systemImage: "shield.lefthalf.filled")
                    }
                    .tag(AppTab.home)

                ProxyAndRulesView()
                    .tabItem {
                        Label("节点与规则", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .tag(AppTab.proxiesAndRules)

                MonitorAndStatsView()
                    .tabItem {
                        Label("请求与统计", systemImage: "waveform.path.ecg")
                    }
                    .tag(AppTab.monitorAndStats)

                SettingsView()
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                    }
                    .tag(AppTab.settings)
            }
            .environmentObject(model)
            .task {
                await model.bootstrap()
                model.startLivePolling()
            }
            .onOpenURL { url in
                Task {
                    await model.importPairingBundle(url.absoluteString)
                }
            }
        }
    }
}
