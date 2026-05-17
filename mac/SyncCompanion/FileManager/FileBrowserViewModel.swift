import Foundation
import AppKit

enum TransferKind: String {
    case upload = "Upload"
    case download = "Download"
}

enum TransferState: String {
    case queued = "Queued"
    case running = "Running"
    case complete = "Complete"
    case failed = "Failed"
    case cancelled = "Cancelled"
}

struct TransferJob: Identifiable, Equatable {
    let id = UUID()
    let kind: TransferKind
    let name: String
    let sourceURL: URL?
    let remotePath: String
    let destinationURL: URL?
    var progress: Double
    var state: TransferState
    var error: String?
}

struct PendingUploadConflict: Identifiable {
    let id = UUID()
    let urls: [URL]
    let conflictingNames: [String]
}

enum MediaPreviewKind {
    case image(NSImage)
    case video(URL)
}

struct MediaPreview: Identifiable {
    let id = UUID()
    let item: WebDavItem
    let kind: MediaPreviewKind
    let temporaryURL: URL?
}

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
    @Published var transferQueue: [TransferJob] = []
    @Published var searchText = ""
    @Published var pendingUploadConflict: PendingUploadConflict?
    @Published var mediaPreview: MediaPreview?
    @Published var isLoadingPreview = false
    @Published var previewIndex: Int? = nil

    let client: WebDavClient
    private var pathStack: [String] = ["/"]
    private var activeTransferTask: Task<Void, Never>?

    // ±5 sliding preview cache: path → downloaded preview
    private var previewCache: [String: MediaPreview] = [:]
    // In-flight background prefetch tasks: path → task
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    var canGoBack: Bool { pathStack.count > 1 }
    var endpointLabel: String { "\(client.ip):\(client.port)" }

    // All previewable items in the current directory (images + videos)
    var previewableItems: [WebDavItem] { items.filter { $0.isPreviewableMedia } }
    var hasPreviousPreview: Bool { (previewIndex ?? 0) > 0 }
    var hasNextPreview: Bool {
        guard let idx = previewIndex else { return false }
        return idx < previewableItems.count - 1
    }

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
    var filteredItems: [WebDavItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var emptyStateTitle: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty folder" : "No matching files"
    }

    var emptyStateMessage: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Drag files here or use Upload to add something."
            : "Try a different search term."
    }

    var fileSummary: String {
        let folders = items.filter(\.isDirectory).count
        let files = items.count - folders
        return "\(folders) folder\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
    }

    init(client: WebDavClient) {
        self.client = client
        Task { await load(path: "/") }
    }

    // MARK: - Navigation

    func load(path: String) async {
        if path != currentPath { closePreview() }
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
        else if item.isPreviewableMedia { Task { await preview(item) } }
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

    func reconnect() { Task { await load(path: currentPath) } }

    // MARK: - Media preview

    func preview(_ item: WebDavItem) async {
        guard item.isPreviewableMedia else { return }
        guard let index = previewableItems.firstIndex(where: { $0.id == item.id }) else { return }
        isLoadingPreview = true
        errorMessage = nil
        defer { isLoadingPreview = false }

        if let cached = previewCache[item.path] {
            previewIndex = index
            mediaPreview = cached
            updateCacheWindow(around: index)
            return
        }
        do {
            let p = try await downloadPreview(for: item)
            previewCache[item.path] = p
            previewIndex = index
            mediaPreview = p
            updateCacheWindow(around: index)
        } catch {
            errorMessage = "Preview failed: \(error.localizedDescription)"
        }
    }

    func previewNext() {
        guard let idx = previewIndex, idx + 1 < previewableItems.count else { return }
        Task { await preview(previewableItems[idx + 1]) }
    }

    func previewPrevious() {
        guard let idx = previewIndex, idx > 0 else { return }
        Task { await preview(previewableItems[idx - 1]) }
    }

    func closePreview() {
        for (_, task) in prefetchTasks { task.cancel() }
        prefetchTasks = [:]
        for path in Array(previewCache.keys) { evictFromCache(path: path) }
        mediaPreview = nil
        previewIndex = nil
    }

    // MARK: - Private preview helpers

    private func downloadPreview(for item: WebDavItem) async throws -> MediaPreview {
        if item.isPreviewableImage {
            let data = try await client.download(path: item.path)
            guard let image = NSImage(data: data) else { throw PreviewError.unsupportedImage }
            return MediaPreview(item: item, kind: .image(image), temporaryURL: nil)
        } else {
            let url = temporaryPreviewURL(for: item)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try await client.download(path: item.path, to: url)
            return MediaPreview(item: item, kind: .video(url), temporaryURL: url)
        }
    }

    // Evict items outside the ±5 window; kick off prefetches for items inside it.
    private func updateCacheWindow(around index: Int) {
        let all = previewableItems
        guard !all.isEmpty else { return }
        let lo = max(0, index - 5)
        let hi = min(all.count - 1, index + 5)
        let keepPaths = Set((lo...hi).map { all[$0].path })

        // Evict out-of-window items
        for path in Array(previewCache.keys) where !keepPaths.contains(path) {
            evictFromCache(path: path)
        }
        for (path, task) in prefetchTasks where !keepPaths.contains(path) {
            task.cancel()
            prefetchTasks.removeValue(forKey: path)
        }

        // Prefetch items inside the window that aren't already cached or in-flight
        for i in lo...hi where i != index {
            let item = all[i]
            guard previewCache[item.path] == nil, prefetchTasks[item.path] == nil else { continue }
            let path = item.path
            let t = Task { [weak self] in
                guard let self else { return }
                guard let p = try? await self.downloadPreview(for: item) else {
                    self.prefetchTasks.removeValue(forKey: path)
                    return
                }
                if Task.isCancelled {
                    if let url = p.temporaryURL { try? FileManager.default.removeItem(at: url) }
                } else {
                    self.previewCache[path] = p
                }
                self.prefetchTasks.removeValue(forKey: path)
            }
            prefetchTasks[item.path] = t
        }
    }

    private func evictFromCache(path: String) {
        if let cached = previewCache.removeValue(forKey: path),
           let url = cached.temporaryURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Download (NSSavePanel)

    func download(_ item: WebDavItem) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let dest = panel.url else { return }
        enqueueDownload(item, destination: dest)
    }

    private func enqueueDownload(_ item: WebDavItem, destination: URL) {
        transferQueue.append(TransferJob(
            kind: .download,
            name: item.name,
            sourceURL: nil,
            remotePath: item.path,
            destinationURL: destination,
            progress: 0,
            state: .queued,
            error: nil
        ))
        startTransferQueueIfNeeded()
    }

    private func runDownload(_ job: TransferJob) async {
        do {
            guard let dest = job.destinationURL else { return }
            try await client.download(path: job.remotePath, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            markTransfer(job.id, state: .failed, progress: 1, error: error.localizedDescription)
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
            self.prepareUploadFiles(panel.urls)
        }
    }

    func prepareUploadFiles(_ urls: [URL]) {
        let existingNames = Set(items.map { $0.name.lowercased() })
        let conflicts = urls.map(\.lastPathComponent).filter { existingNames.contains($0.lowercased()) }
        if !conflicts.isEmpty {
            pendingUploadConflict = PendingUploadConflict(urls: urls, conflictingNames: conflicts)
        } else {
            enqueueUploads(urls, renameConflicts: false)
        }
    }

    func uploadPendingConflict(overwrite: Bool) {
        guard let pending = pendingUploadConflict else { return }
        pendingUploadConflict = nil
        enqueueUploads(pending.urls, renameConflicts: !overwrite)
    }

    func cancelPendingConflict() { pendingUploadConflict = nil }

    private func enqueueUploads(_ urls: [URL], renameConflicts: Bool) {
        let existingNames = Set(items.map { $0.name.lowercased() })
        for url in urls {
            let fileName = renameConflicts && existingNames.contains(url.lastPathComponent.lowercased())
                ? renamedFileName(for: url.lastPathComponent)
                : url.lastPathComponent
            transferQueue.append(TransferJob(
                kind: .upload,
                name: fileName,
                sourceURL: url,
                remotePath: pathForChild(named: fileName),
                destinationURL: nil,
                progress: 0,
                state: .queued,
                error: nil
            ))
        }
        startTransferQueueIfNeeded()
    }

    private func runUpload(_ job: TransferJob) async {
        do {
            guard let source = job.sourceURL else { return }
            try await client.upload(path: job.remotePath, fileURL: source)
        } catch {
            markTransfer(job.id, state: .failed, progress: 1, error: error.localizedDescription)
        }
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

    // MARK: - Queue controls

    func cancelTransfers() {
        activeTransferTask?.cancel()
        activeTransferTask = nil
        isTransferring = false
        transferStatus = "Cancelled"
        transferProgress = 0
        transferQueue = transferQueue.map { job in
            var updated = job
            if updated.state == .queued || updated.state == .running {
                updated.state = .cancelled
                updated.error = nil
            }
            return updated
        }
    }

    func retryFailedTransfers() {
        transferQueue = transferQueue.map { job in
            var updated = job
            if updated.state == .failed || updated.state == .cancelled {
                updated.state = .queued
                updated.progress = 0
                updated.error = nil
            }
            return updated
        }
        startTransferQueueIfNeeded()
    }

    private func startTransferQueueIfNeeded() {
        guard activeTransferTask == nil else { return }
        activeTransferTask = Task { [weak self] in await self?.processQueue() }
    }

    private func processQueue() async {
        isTransferring = true
        defer {
            isTransferring = false
            transferStatus = ""
            transferProgress = 0
            activeTransferTask = nil
            Task { await load(path: currentPath) }
        }

        while let index = transferQueue.firstIndex(where: { $0.state == .queued }) {
            if Task.isCancelled { break }
            transferQueue[index].state = .running
            transferQueue[index].progress = 0.15
            let job = transferQueue[index]
            transferStatus = "\(job.kind.rawValue)ing \(job.name)…"
            transferProgress = 0.15

            switch job.kind {
            case .upload:   await runUpload(job)
            case .download: await runDownload(job)
            }

            if Task.isCancelled {
                markTransfer(job.id, state: .cancelled, progress: 0, error: nil)
                break
            }
            if let updatedIndex = transferQueue.firstIndex(where: { $0.id == job.id }),
               transferQueue[updatedIndex].state == .running {
                markTransfer(job.id, state: .complete, progress: 1, error: nil)
            }
            transferProgress = 1
        }
    }

    private func markTransfer(_ id: UUID, state: TransferState, progress: Double, error: String?) {
        guard let index = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        transferQueue[index].state = state
        transferQueue[index].progress = progress
        transferQueue[index].error = error
        if state == .failed, let error {
            errorMessage = "\(transferQueue[index].name): \(error)"
        }
    }

    private func pathForChild(named name: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return currentPath.hasSuffix("/") ? "\(currentPath)\(encoded)" : "\(currentPath)/\(encoded)"
    }

    private func renamedFileName(for name: String) -> String {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var counter = 1
        var candidate = name
        let existing = Set(items.map { $0.name.lowercased() })
        while existing.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func temporaryPreviewURL(for item: WebDavItem) -> URL {
        let ext = (item.name as NSString).pathExtension
        let fileName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("MiDoidPreviews", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

private enum PreviewError: LocalizedError {
    case unsupportedImage
    var errorDescription: String? {
        switch self {
        case .unsupportedImage: return "This image format could not be previewed."
        }
    }
}
