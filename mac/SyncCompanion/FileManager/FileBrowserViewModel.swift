import Foundation
import AppKit

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published var items: [WebDavItem] = []
    @Published var currentPath: String = "/"
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var selection: Set<String> = []
    @Published var isTransferring = false
    @Published var transferStatus: String = ""
    @Published var transferProgress: Double = 0

    let client: WebDavClient
    private var pathStack: [String] = ["/"]

    var canGoBack: Bool { pathStack.count > 1 }

    var breadcrumbs: [(name: String, path: String)] {
        var result: [(name: String, path: String)] = [("Android", "/")]
        var accumulated = ""
        for comp in currentPath.split(separator: "/") {
            accumulated += "/\(comp)"
            result.append((name: String(comp), path: accumulated))
        }
        return result
    }

    var selectedItems: [WebDavItem] { items.filter { selection.contains($0.id) } }

    init(client: WebDavClient) {
        self.client = client
        Task { await load(path: "/") }
    }

    // MARK: - Navigation

    func load(path: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await client.propfind(path: path)
            items = fetched.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            currentPath = path
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func activate(_ item: WebDavItem) {
        if item.isDirectory { navigate(to: item.path) }
        else { Task { await download(item) } }
    }

    func navigate(to path: String) {
        if let idx = pathStack.firstIndex(of: path) {
            pathStack = Array(pathStack.prefix(idx + 1))
        } else {
            pathStack.append(path)
        }
        Task { await load(path: path) }
    }

    func goBack() {
        guard pathStack.count > 1 else { return }
        pathStack.removeLast()
        Task { await load(path: pathStack.last ?? "/") }
    }

    func refresh() { Task { await load(path: currentPath) } }

    // MARK: - Download (NSSavePanel)

    func download(_ item: WebDavItem) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let dest = panel.url else { return }

        isTransferring = true
        transferStatus = "Downloading \(item.name)…"
        transferProgress = 0
        defer { isTransferring = false; transferStatus = "" }
        do {
            let data = try await client.download(path: item.path)
            try data.write(to: dest)
            transferProgress = 1
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Upload (NSOpenPanel)

    func uploadToCurrentFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] result in
            guard result == .OK, let self else { return }
            let urls = panel.urls
            Task { await self.uploadFiles(urls) }
        }
    }

    private func uploadFiles(_ urls: [URL]) async {
        isTransferring = true
        defer { isTransferring = false; transferStatus = "" }
        for (i, url) in urls.enumerated() {
            transferStatus = "Uploading \(url.lastPathComponent)…"
            transferProgress = Double(i) / Double(urls.count)
            let destPath = currentPath.hasSuffix("/")
                ? "\(currentPath)\(url.lastPathComponent)"
                : "\(currentPath)/\(url.lastPathComponent)"
            do {
                let data = try Data(contentsOf: url)
                try await client.upload(path: destPath, data: data)
            } catch {
                errorMessage = "Upload failed: \(error.localizedDescription)"
                break
            }
        }
        transferProgress = 1
        await load(path: currentPath)
    }

    // MARK: - Delete

    func deleteSelected() async {
        let toDelete = selectedItems
        selection = []
        for item in toDelete {
            do { try await client.delete(path: item.path) }
            catch { errorMessage = "Delete failed: \(error.localizedDescription)" }
        }
        await load(path: currentPath)
    }

    // MARK: - New Folder

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let path = currentPath.hasSuffix("/") ? "\(currentPath)\(trimmed)" : "\(currentPath)/\(trimmed)"
        do {
            try await client.mkcol(path: path)
            await load(path: currentPath)
        } catch {
            errorMessage = "Could not create folder: \(error.localizedDescription)"
        }
    }
}
