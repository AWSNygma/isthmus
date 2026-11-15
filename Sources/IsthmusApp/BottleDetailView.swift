import SwiftUI
import IsthmusKit

struct BottleDetailView: View {
    @Environment(AppModel.self) private var model
    let bottleID: String
    @State private var draft: Bottle?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var runPicker = false

    var body: some View {
        if let original = model.bottle(bottleID) {
            let binding = Binding<Bottle>(
                get: { draft ?? original },
                set: { new in
                    draft = new
                    // Only the fields this page edits; components/pinned/programs
                    // may be changing elsewhere (CLI, installs in progress).
                    model.update(new.id) { c in c.settings = new.config.settings; c.engineVersion = new.config.engineVersion }
                }
            )
            Form {
                header(original)
                LaunchersSection(bottle: original)
                GraphicsSection(settings: binding.config.settings)
                OverlaySection(settings: binding.config.settings)
                PerformanceSection(settings: binding.config.settings)
                InputSection(settings: binding.config.settings)
                Section("Windows") {
                    Picker("Version", selection: binding.config.settings.windowsVersion) {
                        ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Engine", selection: binding.config.engineVersion) {
                        Text("Newest installed").tag(String?.none)
                        ForEach(model.engines) { Text($0.version).tag(Optional($0.version)) }
                    }
                }
                ComponentsSection(bottle: original)
                AdvancedSection(bottle: binding)
                Section {
                    HStack {
                        Button("Rename…") { newName = original.name; renaming = true }
                        Spacer()
                        Button("Delete Bottle…", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(original.name)
            .onChange(of: bottleID) { draft = nil }
            .fileImporter(isPresented: $runPicker, allowedContentTypes: WindowsTypes.runnable) { r in
                if case .success(let url) = r { model.run(url, in: original) }
            }
            .alert("Rename Bottle", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { model.rename(original, to: newName); draft = nil }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete \"\(original.name)\"?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { model.delete(original) }
            } message: {
                Text(model.isRunning(bottleID: original.id)
                     ? "Programs in this bottle are running and will be stopped. The bottle and everything in it, including saved games stored inside it, moves to the Trash."
                     : "The bottle and everything installed in it, including saved games stored inside it, moves to the Trash.")
            }
        }
    }

    @ViewBuilder func header(_ b: Bottle) -> some View {
        Section {
            HStack(spacing: 10) {
                Button { runPicker = true } label: { Label("Run Program…", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Button { NSWorkspace.shared.open(b.driveC) } label: { Label("Open C: Drive", systemImage: "folder") }
                Spacer()
                if model.isRunning(bottleID: b.id) {
                    Label("Running", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
                }
                Button { model.stopAll(b) } label: { Label("Stop All", systemImage: "stop.fill") }
                    .help("Quit every Windows program in this bottle")
            }
        }
    }
}

struct LaunchersSection: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        Section("Game Stores") {
            ForEach(Catalog.launchers()) { l in
                let installed = BottleSetup(paths: model.paths).isInstalled(launcher: l, in: bottle)
                HStack {
                    VStack(alignment: .leading) {
                        Text(l.name)
                        if let n = l.notes { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if installed {
                        if let store = model.stores.first(where: { $0.bottleID == bottle.id && $0.launcherID == l.id }) {
                            Button("Restart") { model.quit(store, reopen: true) }
                                .help("Quit and reopen only \(l.name), leaving other programs running")
                        }
                        Button("Open") { model.run(bottle.unixPath(forWindowsPath: l.executable), in: bottle) }
                    } else {
                        Button("Install") { model.installLauncher(l, in: bottle) }.disabled(model.busy)
                    }
                }
            }
        }
    }
}

struct GraphicsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var settings: BottleSettings

    var body: some View {
        Section {
            Picker("DirectX translation", selection: $settings.graphics) {
                ForEach(GraphicsBackend.allCases) { b in
                    Text(b.displayName).tag(b)
                }
            }
            if settings.graphics == .d3dmetal && model.d3dmetal == nil {
                Label("D3DMetal isn't imported yet. Games will fall back to DXMT or vkd3d.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle(isOn: $settings.retinaMode) {
                Text("High resolution (Retina) mode")
                Text("Sharper, but renders 4× the pixels. Takes effect when programs restart.")
            }
            Toggle(isOn: $settings.rayTracing) {
                Text("Ray tracing (D3DMetal)")
                Text("Requires an M3 or newer chip.")
            }
            Toggle(isOn: $settings.metalFXUpscaling) {
                Text("DLSS → MetalFX upscaling (DXMT)")
                Text("Games that offer DLSS get Apple's MetalFX instead.")
            }
        } header: {
            Text("Graphics")
        } footer: {
            Text("Automatic picks per game: D3DMetal for DirectX 12 when imported, DXMT for DirectX 10/11, Wine's renderer for DirectX 9.")
        }
    }
}

struct OverlaySection: View {
    @Binding var settings: BottleSettings
    var body: some View {
        Section {
            Picker("FPS counter", selection: $settings.overlay) {
                ForEach(PerformanceOverlay.allCases) { Text($0.displayName).tag($0) }
            }
            if settings.overlay != .off {
                Picker("Position", selection: $settings.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle(isOn: $settings.overlayShowRange) {
                    Text("Show minimum and maximum")
                    Text("Adds the range over the last 1,200 frames next to each average.")
                }
            }
        } header: {
            Text("FPS Counter")
        } footer: {
            Text("Uses Apple's Metal Performance HUD, which works with every graphics backend. Steam's own FPS counter can't work under Isthmus. Changes apply the next time a game starts, including games you start from Steam (no Steam restart needed). Shortcut: ⇧⌘F turns it on or off for all bottles. Games run slower when out of focus, so the number drops while another window is in front.")
        }
    }
}

struct PerformanceSection: View {
    @Binding var settings: BottleSettings
    var body: some View {
        Section("Performance") {
            Toggle(isOn: $settings.msync) {
                Text("MSync")
                Text("Faster thread synchronization using Mach semaphores. Turn off only to troubleshoot.")
            }
            Toggle(isOn: $settings.advertiseAVX) {
                Text("Advertise AVX to games")
                Text("Many recent games refuse to start without AVX. Needs macOS 15 or newer.")
            }
            Toggle("Large address aware (32-bit games)", isOn: $settings.largeAddressAware)
        }
    }
}

struct InputSection: View {
    @Binding var settings: BottleSettings
    var body: some View {
        Section("Keyboard") {
            Toggle("Use ⌥ Option as Alt", isOn: Binding(
                get: { settings.leftOptionIsAlt },
                set: { settings.leftOptionIsAlt = $0; settings.rightOptionIsAlt = $0 }))
            Toggle("Use ⌘ Command as Ctrl", isOn: $settings.commandIsCtrl)
        }
    }
}

struct ComponentsSection: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    var body: some View {
        Section("Runtimes") {
            ForEach(Catalog.components()) { c in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.name)
                        Text(c.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if bottle.config.components.contains(c.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install") { model.installComponent(c, in: bottle) }.disabled(model.busy)
                    }
                }
            }
        }
    }
}

struct AdvancedSection: View {
    @Environment(AppModel.self) private var model
    @Binding var bottle: Bottle

    var body: some View {
        Section("Advanced") {
            Picker("Logging", selection: $bottle.config.settings.logging) {
                Text("Quiet").tag(BottleSettings.LogLevel.quiet)
                Text("Errors").tag(BottleSettings.LogLevel.normal)
                Text("Verbose (slow)").tag(BottleSettings.LogLevel.verbose)
            }
            KeyValueEditor(title: "Environment variables", pairs: $bottle.config.settings.environment, keyPlaceholder: "NAME", valuePlaceholder: "value")
            KeyValueEditor(title: "DLL overrides", pairs: $bottle.config.settings.dllOverrides, keyPlaceholder: "dll name", valuePlaceholder: "n,b")
            HStack {
                Text("Wine tools")
                Spacer()
                Button("Configuration") { model.runTool("winecfg", in: bottle) }
                Button("Registry") { model.runTool("regedit", in: bottle) }
                Button("Task Manager") { model.runTool("taskmgr", in: bottle) }
                Button("Command Prompt") { model.runTool("wineconsole", in: bottle) }
            }
            HStack {
                Text("Logs")
                Spacer()
                Button("Open Logs Folder") { NSWorkspace.shared.open(bottle.logs) }
            }
        }
    }
}

struct KeyValueEditor: View {
    let title: String
    @Binding var pairs: [String: String]
    let keyPlaceholder: String
    let valuePlaceholder: String
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        DisclosureGroup("\(title) (\(pairs.count))") {
            ForEach(pairs.keys.sorted(), id: \.self) { k in
                HStack {
                    Text(k).font(.body.monospaced())
                    Spacer()
                    Text(pairs[k] ?? "").font(.body.monospaced()).foregroundStyle(.secondary)
                    Button { pairs.removeValue(forKey: k) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(keyPlaceholder, text: $newKey).font(.body.monospaced())
                TextField(valuePlaceholder, text: $newValue).font(.body.monospaced())
                Button("Add") {
                    let k = newKey.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty else { return }
                    pairs[k] = newValue
                    newKey = ""; newValue = ""
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Tri-state toggle for per-game overrides: inherit / on / off.
struct OverridePicker: View {
    let title: String
    @Binding var value: Bool?
    var body: some View {
        Picker(title, selection: $value) {
            Text("Bottle default").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
    }
}

struct GameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var settings = ProgramSettings()
    @State private var argText = ""

    private var key: String? {
        guard let b = model.bottle(game.bottleID) else { return nil }
        return game.target(in: b).settingsKey(in: b)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let r = model.recipe(for: game) {
                    Section("Built-in fix: \(r.name)") {
                        StatusBadge(recipe: r)
                        if let n = r.notes { Text(n).font(.callout) }
                        Toggle("Ignore this fix", isOn: Binding(get: { settings.ignoreRecipe ?? false }, set: { settings.ignoreRecipe = $0 ? true : nil }))
                    }
                }
                Section("Graphics") {
                    Picker("DirectX translation", selection: $settings.graphics) {
                        Text("Bottle default").tag(GraphicsBackend?.none)
                        ForEach(GraphicsBackend.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Picker("FPS counter", selection: $settings.overlay) {
                        Text("Bottle default").tag(PerformanceOverlay?.none)
                        ForEach(PerformanceOverlay.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    OverridePicker(title: "Ray tracing", value: $settings.rayTracing)
                    OverridePicker(title: "DLSS → MetalFX", value: $settings.metalFXUpscaling)
                }
                Section("Performance") {
                    OverridePicker(title: "MSync", value: $settings.msync)
                    OverridePicker(title: "Advertise AVX", value: $settings.advertiseAVX)
                }
                Section("Launch") {
                    TextField("Extra arguments", text: $argText, prompt: Text("-windowed -dx11"))
                    KeyValueEditor(title: "Environment variables", pairs: Binding(get: { settings.environment ?? [:] }, set: { settings.environment = $0.isEmpty ? nil : $0 }),
                                   keyPlaceholder: "NAME", valuePlaceholder: "value")
                    KeyValueEditor(title: "DLL overrides", pairs: Binding(get: { settings.dllOverrides ?? [:] }, set: { settings.dllOverrides = $0.isEmpty ? nil : $0 }),
                                   keyPlaceholder: "dll name", valuePlaceholder: "n,b")
                }
            }
            .formStyle(.grouped)
            HStack {
                Text(game.name).font(.headline)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        .onAppear {
            if let b = model.bottle(game.bottleID), let key { settings = b.config.programs[key] ?? ProgramSettings() }
            argText = (settings.arguments ?? []).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        }
    }

    private func save() {
        guard let key else { return }
        let args = ArgumentSplitter.split(argText)
        settings.arguments = args.isEmpty ? nil : args
        let s = settings
        model.update(game.bottleID) { c in
            if s == ProgramSettings() { c.programs.removeValue(forKey: key) } else { c.programs[key] = s }
        }
    }
}
