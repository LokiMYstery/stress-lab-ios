import SwiftUI

@MainActor final class StressLabAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LabStore.shared.startHealthMonitoring()
        return true
    }
}

@main struct StressLabApp: App {
    @UIApplicationDelegateAdaptor(StressLabAppDelegate.self) private var delegate
    @StateObject private var store = LabStore.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            DashboardView().environmentObject(store).preferredColorScheme(.light)
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                        if phase == .active { store.reevaluateFreshness() }
                    }
                }
                .onChange(of: phase) { _, value in
                    if value == .active { Task { await store.foreground() } }
                }
        }
    }
}
