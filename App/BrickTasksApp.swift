import SwiftUI

@main
struct BrickTasksApp: App {
    @State private var environment = AppEnvironment.make(arguments: ProcessInfo.processInfo.arguments)

    var body: some Scene {
        WindowGroup {
            TaskListScreen(model: environment.makeTaskList())
        }
    }
}
