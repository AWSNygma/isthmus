import SwiftUI
import IsthmusKit

@main
struct IsthmusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Isthmus", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { delegate.model = model; delegate.flushPending() }
                .onOpenURL { url in model.pendingOpen = PendingOpen(url: url) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") { NotificationCenter.default.post(name: .newBottle, object: nil) }
                    .keyboardShortcut("n")
                Button("Run Windows Program…") { NotificationCenter.default.post(name: .runProgram, object: nil) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Library") { model.reload() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Link("Isthmus on GitHub", destination: URL(string: "https://github.com/\(Isthmus.repository)")!)
                Link("Report a Game Problem", destination: URL(string: "https://github.com/\(Isthmus.repository)/issues/new?template=game.yml")!)
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Finder "Open With" / drag onto the Dock icon for .exe, .msi, .bat, .lnk.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?
    @MainActor private var pending: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls)
        flushPending()
    }

    @MainActor func flushPending() {
        guard let model, let url = pending.first else { return }
        pending.removeFirst()
        model.pendingOpen = PendingOpen(url: url)
    }
}

extension Notification.Name {
    static let newBottle = Notification.Name("isthmus.newBottle")
    static let runProgram = Notification.Name("isthmus.runProgram")
}
