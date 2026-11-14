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
        Group {
            if model.games.isEmpty && !model.scanning {
                EmptyLibrary()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)], spacing: 24) {
                        ForEach(filtered) { game in
                            GameCard(game: game, recipe: model.recipe(for: game), showBottle: model.bottles.count > 1)
                                .contextMenu { GameMenu(game: game, settingsFor: $settingsFor) }
                        }
                    }
                    .padding(24)
                }
            }
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
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: game.artwork != nil ? .fill : .fit)
                        .padding(game.artwork != nil ? 0 : 36)
                } else {
                    Image(systemName: "gamecontroller").font(.system(size: 40)).foregroundStyle(.tertiary)
                }
                if hovering {
                    Color.black.opacity(0.35)
                    Button { model.play(game) } label: {
                        Image(systemName: "play.fill").font(.title).frame(width: 56, height: 56)
                    }
                    .buttonStyle(.plain)
                    .background(.ultraThinMaterial, in: Circle())
                    .disabled(recipe?.status == .blocked)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { StatusBadge(recipe: recipe).padding(6) }
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.12), radius: hovering ? 10 : 4, y: 3)
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
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

struct EmptyLibrary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller").font(.system(size: 54)).foregroundStyle(.tertiary)
            Text("Your library is empty").font(.title2.weight(.semibold))
            Text("Install a game store, or drag a Windows game's .exe onto this window.")
                .foregroundStyle(.secondary)
            if let b = model.bottle(model.defaultBottleID ?? "") {
                HStack {
                    ForEach(Catalog.launchers().prefix(3)) { l in
                        Button("Install \(l.name)") { model.installLauncher(l, in: b) }
                            .disabled(model.busy)
                    }
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
