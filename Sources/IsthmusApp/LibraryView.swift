import SwiftUI
import IsthmusKit

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var settingsFor: Game?

    private var filtered: [Game] {
        search.isEmpty ? model.games : model.games.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.stores.isEmpty && search.isEmpty {
                    StoresRow()
                }
                if model.games.isEmpty && !model.scanning {
                    EmptyLibrary()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20, alignment: .top)],
                              alignment: .leading, spacing: 24) {
                        ForEach(filtered) { game in
                            GameCard(game: game, recipe: model.recipe(for: game), showBottle: model.bottles.count > 1)
                                .contextMenu { GameMenu(game: game, settingsFor: $settingsFor) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Library")
        .searchable(text: $search, placement: .toolbar, prompt: "Search games")
        .toolbar {
            ToolbarItem {
                Button { model.refreshGames() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.scanning)
            }
        }
        .sheet(item: $settingsFor) { g in GameSettingsSheet(game: g) }
    }
}

struct GameMenu: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @Binding var settingsFor: Game?

    var body: some View {
        Button("Play") { model.play(game) }
        Menu("Play With") {
            ForEach(GraphicsBackend.allCases.filter { $0 != .auto }) { b in
                Button(b.displayName) { model.play(game, graphics: b) }
                    .disabled(b == .d3dmetal && model.d3dmetal == nil)
            }
        }
        Divider()
        Button("Game Settings…") { settingsFor = game }
        Button("Add to Launchpad") { model.createShortcut(game) }
        if let dir = game.installDirectory {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        }
        if let b = model.bottle(game.bottleID), let log = model.latestLog(for: b) {
            Button("Show Latest Log") { NSWorkspace.shared.open(log) }
        }
        if game.source == .pinned {
            Divider()
            Button("Remove from Library", role: .destructive) { model.unpin(game) }
        }
    }
}

struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let recipe: Recipe?
    let showBottle: Bool
    @State private var hovering = false
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Fixed 2:3 frame; artwork is drawn inside it and clipped, so any
            // image shape (portrait cover, wide banner, square icon) fits.
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .background(.quaternary)
                .overlay { Cover(image: image, isArtwork: game.artwork != nil) }
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.35)
                            Button { model.play(game) } label: {
                                Image(systemName: "play.fill").font(.title).frame(width: 56, height: 56)
                            }
                            .buttonStyle(.plain)
                            .background(.ultraThinMaterial, in: Circle())
                            .disabled(recipe?.status == .blocked)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) { StatusBadge(recipe: recipe).padding(6) }
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.12), radius: hovering ? 10 : 4, y: 3)
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture(count: 2) { model.play(game) }

            Text(game.name).font(.callout.weight(.medium)).lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: game.source.symbol).imageScale(.small)
                Text(game.source.label)
                if showBottle, let b = model.bottle(game.bottleID) { Text("· \(b.name)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: game.id) { image = await ArtworkCache.shared.image(for: game) }
        .help(recipe?.notes ?? game.name)
    }
}

/// Portrait art fills the card; wide art (Steam headers) sits centered over a
/// blurred copy of itself; icons sit centered on the plain background.
struct Cover: View {
    let image: NSImage?
    let isArtwork: Bool

    var body: some View {
        GeometryReader { geo in
            if let image {
                let wide = image.size.width > image.size.height * 0.9
                if isArtwork && !wide {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                } else if isArtwork {
                    ZStack {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                            .blur(radius: 18).opacity(0.7)
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: geo.size.width)
                            .shadow(radius: 6)
                    }
                } else {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(width: geo.size.width * 0.55)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                Image(systemName: "gamecontroller").font(.system(size: 40)).foregroundStyle(.tertiary)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

struct StatusBadge: View {
    let recipe: Recipe?
    var body: some View {
        if let recipe {
            let (text, color): (String, Color) = switch recipe.status {
            case .works: ("Tuned", .green)
            case .issues: ("Known issues", .orange)
            case .blocked: ("Won't run", .red)
            }
            Text(text).font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.9), in: Capsule())
                .foregroundStyle(.white)
        }
    }
}

extension Game.Source {
    var label: String {
        switch self { case .steam: "Steam"; case .epic: "Epic"; case .gog: "GOG"; case .installed: "Installed"; case .pinned: "Added" }
    }
    var symbol: String {
        switch self { case .steam: "cloud"; case .epic: "bag"; case .gog: "opticaldisc"; case .installed: "shippingbox"; case .pinned: "pin" }
    }
}

/// Decodes card images off the main thread; Steam art is large JPEG, icons come from PE resources.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private var cache: [String: NSImage] = [:]

    func image(for game: Game) async -> NSImage? {
        if let hit = cache[game.id] { return hit }
        let img: NSImage? = {
            if let art = game.artwork, let i = NSImage(contentsOf: art) { return i }
            return ShortcutMaker.icon(for: game)
        }()
        if let img { cache[game.id] = img }
        return img
    }
}

struct StoresRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stores").font(.headline).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.stores) { store in StoreTile(store: store, showBottle: model.bottles.count > 1) }
                }
            }
        }
    }
}

struct StoreTile: View {
    @Environment(AppModel.self) private var model
    let store: InstalledStore
    let showBottle: Bool
    @State private var icon: NSImage?
    @State private var hovering = false

    var body: some View {
        Button { model.open(store) } label: {
            HStack(spacing: 10) {
                Group {
                    if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "bag").resizable().padding(6) }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.name).font(.callout.weight(.medium))
                    Text(showBottle ? "Open · \(model.bottle(store.bottleID)?.name ?? "")" : "Open").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary.opacity(hovering ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(store.name)")
        .task(id: store.id) {
            let exe = store.executable
            icon = await Task.detached {
                (try? PEFile(url: exe)).flatMap { $0.iconData() }.flatMap { NSImage(data: $0) }
            }.value
        }
    }
}

struct EmptyLibrary: View {
    @Environment(AppModel.self) private var model

    private var missingStores: [LauncherInfo] {
        let installed = Set(model.stores.map(\.launcherID))
        return Catalog.launchers().filter { !installed.contains($0.id) }.prefix(3).map { $0 }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller").font(.system(size: 54)).foregroundStyle(.tertiary)
            if model.stores.isEmpty {
                Text("Your library is empty").font(.title2.weight(.semibold))
                Text("Install a game store, or drag a Windows game's .exe onto this window.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No games yet").font(.title2.weight(.semibold))
                Text("Install games in \(ListFormatter.localizedString(byJoining: model.stores.map(\.name))) and they'll appear here automatically. You can also drag a Windows game's .exe onto this window.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                HStack {
                    ForEach(model.stores) { s in Button("Open \(s.name)") { model.open(s) }.buttonStyle(.borderedProminent) }
                }
                .controlSize(.large)
            }
            if let b = model.bottle(model.defaultBottleID ?? ""), !missingStores.isEmpty {
                HStack {
                    ForEach(missingStores) { l in
                        Button("Install \(l.name)") { model.installLauncher(l, in: b) }
                            .disabled(model.busy)
                    }
                }
                .controlSize(model.stores.isEmpty ? .large : .regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
