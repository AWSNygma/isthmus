import SwiftUI
import UniformTypeIdentifiers
import IsthmusKit

enum SidebarItem: Hashable {
    case library
    case bottle(String)
    case engines
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .library
    @State private var showNewBottle = false
    @State private var showRunPicker = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.needsOnboarding {
                OnboardingView()
            } else {
                NavigationSplitView {
                    Sidebar(selection: $selection, showNewBottle: $showNewBottle)
                        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
                } detail: {
                    switch selection ?? .library {
                    case .library: LibraryView()
                    case .bottle(let id):
                        if let b = model.bottle(id) { BottleDetailView(bottleID: b.id) } else { LibraryView() }
                    case .engines: EnginesView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showRunPicker = true } label: { Label("Run Program", systemImage: "play.rectangle") }
                            .help("Run a Windows .exe or installer")
                    }
                    ToolbarItem(placement: .primaryAction) { ActivityButton() }
                }
            }
        }
        .sheet(isPresented: $showNewBottle) { NewBottleSheet() }
        .sheet(item: $model.pendingOpen) { p in OpenProgramSheet(url: p.url) }
        .alert(item: $model.alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .fileImporter(isPresented: $showRunPicker, allowedContentTypes: WindowsTypes.runnable) { result in
            if case .success(let url) = result { model.pendingOpen = PendingOpen(url: url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBottle)) { _ in showNewBottle = true }
        .onReceive(NotificationCenter.default.publisher(for: .runProgram)) { _ in showRunPicker = true }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.pendingOpen = PendingOpen(url: url)
            return true
        }
    }
}

enum WindowsTypes {
    static let exe = UTType(filenameExtension: "exe") ?? .item
    static let msi = UTType(filenameExtension: "msi") ?? .item
    static let runnable: [UTType] = [exe, msi, UTType(filenameExtension: "bat") ?? .item, UTType(filenameExtension: "lnk") ?? .item]
    static let engine: [UTType] = [UTType(filenameExtension: "xz") ?? .data, .gzip, .archive]
    static let toolkit: [UTType] = [UTType(filenameExtension: "dmg") ?? .diskImage, .folder]
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @Binding var showNewBottle: Bool

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Library", systemImage: "square.grid.2x2").tag(SidebarItem.library)
            }
            Section("Bottles") {
                ForEach(model.bottles) { b in
                    HStack {
                        Label(b.name, systemImage: "shippingbox")
                        Spacer()
                        if model.isRunning(bottleID: b.id) {
                            Circle().fill(.green).frame(width: 7, height: 7).help("Programs running")
                        }
                    }
                    .tag(SidebarItem.bottle(b.id))
                    .contextMenu {
                        Button("Open C: Drive") { NSWorkspace.shared.open(b.driveC) }
                        Button("Stop All Programs") { model.stopAll(b) }
                    }
                }
                Button { showNewBottle = true } label: { Label("New Bottle…", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Section {
                Label {
                    Text("Engines & Graphics")
                } icon: {
                    Image(systemName: "cpu")
                }
                .badge(model.remoteEngine != nil ? Text("Update") : nil)
                .tag(SidebarItem.engines)
            }
        }
        .listStyle(.sidebar)
    }
}

struct ActivityButton: View {
    @Environment(AppModel.self) private var model
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            if model.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: model.activities.contains { $0.failed } ? "exclamationmark.circle" : "checkmark.circle") }
        }
        .help("Activity")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if model.activities.isEmpty { Text("Nothing in progress.").foregroundStyle(.secondary) }
                ForEach(model.activities) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: a.failed ? "xmark.octagon.fill" : a.finished ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                .foregroundStyle(a.failed ? .red : a.finished ? .green : .accentColor)
                            Text(a.title).font(.headline)
                        }
                        if let p = a.progress { ProgressView(value: p) }
                        else if !a.finished { ProgressView().progressViewStyle(.linear) }
                        Text(a.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if model.activities.contains(where: \.finished) {
                    Button("Clear") { model.activities.removeAll { $0.finished } }.controlSize(.small)
                }
            }
            .padding()
            .frame(width: 320)
        }
    }
}
