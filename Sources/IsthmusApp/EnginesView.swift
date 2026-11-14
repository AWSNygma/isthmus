import SwiftUI
import IsthmusKit

struct EnginesView: View {
    @Environment(AppModel.self) private var model
    @State private var importEngine = false
    @State private var importToolkit = false

    var body: some View {
        Form {
            Section("This Mac") {
                ForEach(model.checks) { c in CheckRow(check: c) }
            }

            Section {
                if let r = model.remoteEngine {
                    HStack {
                        Label("Engine \(r.version) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(.tint)
                        Spacer()
                        Button("Download") { model.downloadEngine() }.disabled(model.busy)
                    }
                }
                ForEach(model.engines) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Engine \(e.version)").font(.headline)
                            Text("Wine \(e.manifest.wine) · " + e.manifest.components.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { model.removeEngine(e) }
                            .disabled(model.engines.count == 1 && !model.bottles.isEmpty)
                    }
                }
                HStack {
                    Button("Check for Updates") { Task { await model.checkForEngineUpdate() } }
                    Button("Install from File…") { importEngine = true }
                }
            } header: {
                Text("Engines")
            } footer: {
                Text("An engine bundles Wine (from CodeWeavers' open-source CrossOver release), DXMT, DXVK, MoltenVK, vkd3d, Wine Mono and GStreamer.")
            }

            Section {
                if let d = model.d3dmetal {
                    LabeledContent("D3DMetal", value: d.version)
                    Button("Remove", role: .destructive) { try? D3DMetalStore(paths: model.paths).remove(d); model.reload() }
                } else {
                    Text("D3DMetal is Apple's DirectX 12 translator. Apple's license doesn't allow redistributing it, so Isthmus can't include it, but you can import it yourself:")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Sign in at developer.apple.com (a free account works).")
                        Text("2. Download the Game Porting Toolkit disk image.")
                        Text("3. Import the .dmg here.")
                    }
                    .font(.callout)
                    HStack {
                        Link("Open Apple's Download Page", destination: URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
                        Spacer()
                        Button("Import Toolkit…") { importToolkit = true }.disabled(model.busy)
                    }
                }
            } header: {
                Text("D3DMetal (optional)")
            }

            Section("Licenses") {
                Text("Isthmus is GPL-3.0. Wine, vkd3d and DXMT are LGPL-2.1; DXVK is zlib; MoltenVK is Apache-2.0. Full notices ship inside each engine.")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = model.engines.first {
                    Button("Show Engine Licenses") { NSWorkspace.shared.open(e.url.appendingPathComponent("share/licenses")) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Engines & Graphics")
        .fileImporter(isPresented: $importEngine, allowedContentTypes: WindowsTypes.engine) { r in
            if case .success(let url) = r { model.importEngine(url) }
        }
        .fileImporter(isPresented: $importToolkit, allowedContentTypes: WindowsTypes.toolkit) { r in
            if case .success(let url) = r { model.importD3DMetal(url) }
        }
    }
}

struct CheckRow: View {
    @Environment(AppModel.self) private var model
    let check: Doctor.Check
    @State private var toolkitPicker = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                if !check.detail.isEmpty { Text(check.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            switch check.fix {
            case .installRosetta: Button("Install") { model.installRosetta() }
            case .downloadEngine: Button("Download") { model.downloadEngine() }
            case .importD3DMetal: Button("Import…") { toolkitPicker = true }
            case nil: EmptyView()
            }
        }
        .fileImporter(isPresented: $toolkitPicker, allowedContentTypes: WindowsTypes.toolkit) { r in
            if case .success(let url) = r { model.importD3DMetal(url) }
        }
    }

    var icon: String {
        switch check.level { case .ok: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" }
    }
    var color: Color {
        switch check.level { case .ok: .green; case .warning: .orange; case .error: .red }
    }
}
