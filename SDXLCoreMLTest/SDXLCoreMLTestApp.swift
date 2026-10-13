import SwiftUI
import UIKit
import LocalImageGeneration

@main
struct SDXLCoreMLTestApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = SDXLGeneratorViewModel()
    @StateObject private var setup = ModelSetupViewModel()
    @AppStorage("welcomeCompletedV1") private var welcomeCompleted = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !welcomeCompleted {
                    WelcomeView { welcomeCompleted = true }
                } else if !LocalFluxGenerator.supportsGeneration {
                    UnsupportedDeviceView()
                } else if setup.isReady {
                    ContentView(viewModel: viewModel)
                } else {
                    ModelSetupView(setup: setup)
                }
            }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    viewModel.releaseCachedResources(backgrounded: false, allowPreload: false,
                                                     cancelActiveOperations: false)
                }
                .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                    viewModel.resourceConditionsChanged()
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                    viewModel.resourceConditionsChanged()
                }
                .task {
                    if welcomeCompleted { setup.inspectInstallation() }
                }
                .onChange(of: welcomeCompleted) { _, completed in
                    if completed { setup.inspectInstallation() }
                }
                .onChange(of: setup.isReady) { _, ready in
                    if ready { viewModel.preloadResourcesIfNeeded() }
                }
                .onChange(of: viewModel.isGenerating || viewModel.isPreparing || setup.isBusy) { _, busy in
                    UIApplication.shared.isIdleTimerDisabled = busy && scenePhase == .active
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        UIApplication.shared.isIdleTimerDisabled = viewModel.isGenerating || viewModel.isPreparing || setup.isBusy
                        if setup.isReady { viewModel.preloadResourcesIfNeeded() }
                        else if welcomeCompleted { setup.inspectInstallation() }
                    case .background:
                        UIApplication.shared.isIdleTimerDisabled = false
                        setup.pause()
                        viewModel.releaseCachedResources()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
