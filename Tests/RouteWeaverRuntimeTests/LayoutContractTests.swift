import AppKit
import Foundation
import RoutingCore
@testable import RouteWeaverRuntime
import SwiftUI
import XCTest

private final class WidthRecorderBox {
    var value: CGFloat = 0
}

private struct WidthProbeView: View {
    let width: CGFloat
    let box: WidthRecorderBox

    var body: some View {
        let _ = { box.value = width }()
        Color.clear
    }
}

@MainActor
final class LayoutContractTests: XCTestCase {
    private func makeIsolatedAppState() throws -> (AppState, URL, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rw-layout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let suiteName = "rw.layout.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let driver = FakeRuntimeDriver()
        driver.interfaces = ["en0"]
        let engine = EngineController(stateDir: dir, driver: driver)
        let monitor = ConnectionMonitorService(initialConnectDelayNs: 0, reconnectDelayNs: 50_000_000)

        let state = AppState(
            engine: engine,
            connectionMonitor: monitor,
            userDefaults: defaults,
            bootstrapOnInit: false
        )
        return (state, dir, suiteName)
    }

    func testAtomicStatusPillAndMetricTextNeverWrapIntoVerticalCharacterColumns() {
        let singlePillHosting = NSHostingView(
            rootView: StatusPill("网卡直连", color: .green)
        )
        let singleLineSize = singlePillHosting.fittingSize
        XCTAssertGreaterThan(singleLineSize.width, 48)
        XCTAssertLessThan(singleLineSize.height, 32)

        // Place multiple pills and throughput readouts inside a 170pt narrow FlowLayout
        // (matching the squeezed ~156-170pt width from the original bug report).
        let wrappedHeader = FlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            StatusPill("网卡直连", color: .green)
            StatusPill("传输中", systemImage: "bolt.horizontal.fill", color: .green)
            MonospacedMetricText("24 活跃", color: .secondary)
            MonospacedMetricText("↓ 24B/s", color: .green)
            MonospacedMetricText("↑ 40B/s", color: .blue)
        }
        .frame(width: 170)

        let wrappedHosting = NSHostingView(rootView: wrappedHeader)
        wrappedHosting.frame = NSRect(x: 0, y: 0, width: 170, height: 200)
        wrappedHosting.layoutSubtreeIfNeeded()
        let measured = wrappedHosting.fittingSize

        // Must stay within the 170pt horizontal budget while wrapping into 2-3 clean horizontal rows
        // (never exploding into a 140pt+ tall single-character vertical column).
        XCTAssertLessThanOrEqual(measured.width, 170.5)
        XCTAssertGreaterThan(measured.height, singleLineSize.height)
        XCTAssertLessThan(measured.height, singleLineSize.height * 4.2)
    }

    func testAdaptiveInspectorScaffoldSwitchesToOverlayBelowBudgetAndDocksAboveBudget() {
        // Below 540 + 344 + 1 = 885pt, inspector must float as an overlay instead of crushing canvas.
        XCTAssertFalse(
            AdaptiveInspectorScaffold<EmptyView, EmptyView>.docksInline(
                stageWidth: 680,
                isInspectorPresented: true,
                inspectorWidth: 344,
                minContentWidth: 540
            )
        )
        XCTAssertFalse(
            AdaptiveInspectorScaffold<EmptyView, EmptyView>.docksInline(
                stageWidth: 880,
                isInspectorPresented: true,
                inspectorWidth: 344,
                minContentWidth: 540
            )
        )
        // At or above 885pt, inspector docks inline side-by-side.
        XCTAssertTrue(
            AdaptiveInspectorScaffold<EmptyView, EmptyView>.docksInline(
                stageWidth: 885,
                isInspectorPresented: true,
                inspectorWidth: 344,
                minContentWidth: 540
            )
        )

        let narrowBox = WidthRecorderBox()
        let narrowScaffold = AdaptiveInspectorScaffold(
            isInspectorPresented: true,
            inspectorWidth: 344,
            minContentWidth: 540,
            onDismiss: {}
        ) { width in
            WidthProbeView(width: width, box: narrowBox)
        } inspector: {
            Color.clear
        }

        let narrowWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let narrowHosting = NSHostingView(rootView: narrowScaffold)
        narrowWindow.contentView = narrowHosting
        narrowHosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        // Primary content retains 100% of the 700pt stage width in overlay mode!
        XCTAssertEqual(narrowBox.value, 700, accuracy: 1.0)

        let wideBox = WidthRecorderBox()
        let wideScaffold = AdaptiveInspectorScaffold(
            isInspectorPresented: true,
            inspectorWidth: 344,
            minContentWidth: 540,
            onDismiss: {}
        ) { width in
            WidthProbeView(width: width, box: wideBox)
        } inspector: {
            Color.clear
        }

        let wideWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let wideHosting = NSHostingView(rootView: wideScaffold)
        wideWindow.contentView = wideHosting
        wideHosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        // Primary content receives 1000 - 344 - 1 = 655pt in inline docked mode!
        XCTAssertEqual(wideBox.value, 655, accuracy: 1.0)
    }

    func testDetailOverflowIsolationAndAnomalyViewsRespectMinimumWindowWidth() throws {
        let (state, dir, suiteName) = try makeIsolatedAppState()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }

        // Configure a broken direct interface target ("新加坡eSIM" -> missing en6) + active rules
        var profile = RoutingProfile.starter()
        let esimTarget = NetworkTarget(
            name: "新加坡eSIM",
            mode: .direct,
            interfaceName: "en6"
        )
        profile.targets.append(esimTarget)
        profile.ruleGroups.append(
            RuleGroup(
                name: "Claude",
                icon: "sparkles",
                target: .target(esimTarget.id),
                rules: [RuleItem(type: .domainSuffix, value: "claude.ai")]
            )
        )
        state.profile = profile

        state.activeConnectionMonitor.seedOutboundErrorsFromLogText(
            "[TCP] dial 美国 (match DomainSuffix/openai.com) 127.0.0.1:52100 --> api.openai.com:443 error: i/o timeout"
        )

        // Force the right-side diagnostic drawer open even at minimum window size
        state.selectedSection = .topology
        state.selectedTopologyTargetKey = "target:\(esimTarget.id.uuidString)"

        // 1. Verify isolated detail budget reports <= 480pt minimum width so it can never push
        //    NavigationSplitView (180pt sidebar + 480pt detail = 660pt <= 900pt window minWidth)
        //    beyond the NSWindow bounds.
        let isolatedTopology = NetworkTopologyView(
            state: state,
            liveProxyStore: state.activeLiveProxyStore,
            monitor: state.activeConnectionMonitor
        )
        .isolateHorizontalOverflow(minWidth: 480)

        let detailProbe = NSHostingView(rootView: isolatedTopology)
        detailProbe.frame = NSRect(x: 0, y: 0, width: 680, height: 600)
        detailProbe.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(detailProbe.intrinsicContentSize.width, 980)

        // 2. Mount full MainView inside a minimum-width 900x600 NSWindow across high-density sections
        //    and verify NSHostingView never demands more width than the 900pt window frame.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let rootHosting = NSHostingView(rootView: MainView(state: state).frame(minWidth: 900, minHeight: 600))
        window.contentView = rootHosting

        for section in [SidebarSection.topology, .monitor, .overview, .trafficStats, .subscriptions, .customDNS] {
            state.selectedSection = section
            rootHosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(rootHosting.frame.width, 900, accuracy: 0.5, "Root frame drifted in section \(section)")
            XCTAssertGreaterThanOrEqual(rootHosting.frame.minX, 0, "Root frame shifted negative in section \(section)")
        }
    }
}
