import Foundation

/// Thin synchronous process runner for short helper commands
/// (tar, xattr, hdiutil, iconutil). Wine itself goes through `WineRunner`.
public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil,
                           allowFailure: Bool = false) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting so a chatty child can't block on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        if !allowFailure && result.status != 0 {
            throw IsthmusError.processFailed(command: ([executable] + arguments).joined(separator: " "),
                                             status: result.status, output: result.output)
        }
        return result
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        var name: String
        var browserDownloadURL: URL
        var size: Int
        enum CodingKeys: String, CodingKey { case name, size; case browserDownloadURL = "browser_download_url" }
    }
    var tagName: String
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var assets: [Asset]
    enum CodingKeys: String, CodingKey { case name, body, draft, prerelease, assets; case tagName = "tag_name" }
}

enum GitHub {
    static func releases(repository: String, session: URLSession) async throws -> [GitHubRelease] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=50")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Isthmus/\(Isthmus.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IsthmusError.download("GitHub API returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }
}

public enum Downloader {
    /// Downloads `url` to `destination`, reporting fractional progress.
    public static func fetch(_ url: URL, to destination: URL, session: URLSession = .shared,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws {
        var request = URLRequest(url: url)
        request.setValue("Isthmus/\(Isthmus.version)", forHTTPHeaderField: "User-Agent")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let box = ObservationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request) { tmp, response, error in
                    let fm = FileManager.default
                    box.observation?.invalidate()
                    if let error { cont.resume(throwing: IsthmusError.download(error.localizedDescription)); return }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let tmp else {
                        cont.resume(throwing: IsthmusError.download("\(url.host ?? "server") returned \((response as? HTTPURLResponse)?.statusCode ?? -1)"))
                        return
                    }
                    do {
                        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                        try fm.moveItem(at: tmp, to: destination)
                        cont.resume()
                    } catch { cont.resume(throwing: error) }
                }
                if let progress {
                    box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
        progress?(1)
    }

    private final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask?
    }
}
