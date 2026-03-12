import SwiftUI
import SwiftData

@main
struct MobileSSHApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([SSHHost.self])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            HostListView()
                .modelContainer(modelContainer)
        }
    }
}
