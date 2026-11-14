import SwiftUI
import IsthmusKit

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var bottleName = "Games"
    @State private var installSteam = true
    @State private var importEngine = false

    private var rosettaOK: Bool { Doctor.rosettaInstalled }
    private var engineOK: Bool { !model.engines.isEmpty }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Welcome to Isthmus").font(.largeTitle.weight(.semibold))
                Text("Play Windows games on your Mac. Three quick steps:").foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                Step(number: 1, title: "Rosetta 2", detail: "Translates the games' Intel code for Apple silicon.", done: rosettaOK) {
                    Button("Install Rosetta") { model.installRosetta() }.disabled(model.busy)
                }
                Step(number: 2, title: "Engine", detail: "Wine plus the DirectX → Metal translators (about 280 MB).", done: engineOK) {
                    HStack {
                        Button("Download") { model.downloadEngine() }.disabled(model.busy)
                        Button("From File…") { importEngine = true }.disabled(model.busy)
                    }
                }
                Step(number: 3, title: "Your first bottle", detail: "A self-contained Windows environment for your games.", done: !model.bottles.isEmpty) {
                    VStack(alignment: .trailing) {
                        TextField("Name", text: $bottleName).frame(width: 180)
                        Toggle("Install Steam", isOn: $installSteam)
                        Button("Create") { model.createBottle(name: bottleName, windows: .win10, installSteam: installSteam) }
                            .disabled(!engineOK || bottleName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                    }
                }
            }
            .frame(maxWidth: 560)

            if let a = model.activities.first(where: { !$0.finished }) {
                VStack(spacing: 6) {
                    Text(a.title).font(.headline)
                    if let p = a.progress { ProgressView(value: p).frame(width: 320) } else { ProgressView().progressViewStyle(.linear).frame(width: 320) }
                    Text(a.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $importEngine, allowedContentTypes: WindowsTypes.engine) { r in
            if case .success(let url) = r { model.importEngine(url) }
        }
    }
}

private struct Step<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 34, height: 34)
                if done { Image(systemName: "checkmark").foregroundStyle(.white).font(.headline) }
                else { Text("\(number)").font(.headline).foregroundStyle(.tint) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { action() }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var windows = WindowsVersion.win10
    @State private var installSteam = false

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("e.g. Steam, Old Games"))
            Picker("Windows version", selection: $windows) {
                ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Install Steam", isOn: $installSteam)
            Text("Use separate bottles when games need conflicting settings or runtimes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { model.createBottle(name: name, windows: windows, installSteam: installSteam); dismiss() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.engines.isEmpty)
            }
        }
    }
}

struct OpenProgramSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var bottleID = ""
    @State private var addToLibrary = true
    @State private var arguments = ""

    private var isRunnable: Bool { LaunchPlanner.runnableExtensions.contains(url.pathExtension.lowercased()) }

    private var isInstaller: Bool {
        let n = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "msi" || ["setup", "install", "redist"].contains { n.contains($0) }
    }

    var body: some View {
        Form {
            LabeledContent("Program", value: url.lastPathComponent)
            if !isRunnable {
                Label(url.pathExtension.lowercased() == "app"
                      ? "This is a Mac app. Open it from Finder."
                      : "Isthmus can run Windows .exe, .msi, .bat and .lnk files.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Picker("Bottle", selection: $bottleID) {
                ForEach(model.bottles) { Text($0.name).tag($0.id) }
            }
            TextField("Arguments", text: $arguments, prompt: Text("optional"))
            if !isInstaller {
                Toggle("Add to Library", isOn: $addToLibrary)
            }
            if let r = model.recipes.recipe(exeName: url.lastPathComponent), r.status == .blocked {
                Label(r.notes ?? "This game can't run on Isthmus.", systemImage: "nosign").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { bottleID = model.defaultBottleID ?? model.bottles.first?.id ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isInstaller ? "Install" : "Run") {
                    guard let b = model.bottle(bottleID) else { return }
                    if addToLibrary && !isInstaller { model.pin(url, in: b) }
                    model.run(url, in: b, arguments: ArgumentSplitter.split(arguments))
                    dismiss()
                }
                .disabled(model.bottle(bottleID) == nil || !isRunnable)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Picker("Default bottle", selection: Binding(get: { model.defaultBottleID ?? "" }, set: { model.defaultBottleID = $0 })) {
                ForEach(model.bottles) { Text($0.name).tag($0.id) }
            }
            LabeledContent("Launchpad shortcuts") {
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: ShortcutMaker.defaultFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ShortcutMaker.defaultFolder)
                }
            }
            LabeledContent("Data folder") {
                Button("Show in Finder") { NSWorkspace.shared.open(model.paths.root) }
            }
            LabeledContent("Command-line tool") {
                VStack(alignment: .trailing) {
                    Text("ln -s \"\(Bundle.main.bundleURL.path)/Contents/Helpers/isthmus\" /usr/local/bin/isthmus")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Text("Run that in Terminal to use `isthmus` from the shell.").font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Version", value: Isthmus.version)
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }
}
