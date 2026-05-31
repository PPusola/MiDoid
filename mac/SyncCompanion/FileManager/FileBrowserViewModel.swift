import Foundation
import AppKit
import AVFoundation

// MARK: - Enums

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

enum FileSortKey: String, CaseIterable {
    case name = "Name"
    case kind = "Kind"
    case size = "Size"
    case modified = "Modified"
}

// MARK: - Transfer summary (shown after folder jobs complete)

struct TransferSummary: Equatable {
    let completedFiles: Int
    let skippedFiles: Int
    let failedFiles: Int
    let transferredBytes: Int64
    // Lets completed downloads offer "Reveal in Finder" after the queue moves on.
    let destinationURL: URL?
}

struct TransferSample: Equatable {
    let date: Date
    let bytes: Int64
}

// MARK: - Transfer job

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
    var startTime: Date? = nil
    // Folder flag
    var isFolder: Bool = false
    // Current file name (shown while running)
    var currentFile: String? = nil
    // Byte-level progress (single files)
    var totalBytes: Int64? = nil
    var transferredBytes: Int64 = 0
    var recentSamples: [TransferSample] = []
    var smoothedBytesPerSecond: Double? = nil
    // File-count progress (folder jobs)
    var totalFiles: Int? = nil
    var completedFiles: Int = 0
    var skippedFiles: Int = 0
    var failedFiles: Int = 0
    // Populated after folder job finishes
    var summary: TransferSummary? = nil
}

// MARK: - Transfer history

struct TransferHistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let kind: TransferKind
    let name: String
    let state: TransferState
    let completedAt: Date
    let bytes: Int64
    let destinationURL: URL?
    let error: String?
}

struct BatchSummaryItem: Equatable {
    let category: String
    let count: Int
    let bytes: Int64
}

// MARK: - Upload conflict

struct PendingUploadConflict: Identifiable {
    let id = UUID()
    let urls: [URL]
    let conflictingNames: [String]
}

enum RenameConflictAction {
    case replace
    case keepBoth
    case cancel
}

struct PendingRenameConflict: Identifiable {
    let id = UUID()
    let item: WebDavItem
    let requestedName: String
    let existingItem: WebDavItem
}

// MARK: - Media preview

enum MediaPreviewKind {
    case image(NSImage)
    case video(AVURLAsset)  // streams directly — no temp file download
    case pdf(URL)
}

struct MediaPreview: Identifiable {
    let id = UUID()
    let item: WebDavItem
    let kind: MediaPreviewKind
    let temporaryURL: URL?
}

// MARK: - ViewModel

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
    @Published var recursiveSearchEnabled = false
    @Published var isSearchingRecursively = false
    @Published var pendingUploadConflict: PendingUploadConflict?
    @Published var pendingRenameConflict: PendingRenameConflict?
    @Published var mediaPreview: MediaPreview?
    @Published var isLoadingPreview = false
    @Published var previewIndex: Int? = nil
    @Published var pendingDeleteItems: [WebDavItem]? = nil
    @Published var detailPreview: MediaPreview? = nil
    @Published var isLoadingDetailPreview = false
    @Published var sortKey: FileSortKey = {
        let raw = UserDefaults.standard.string(forKey: "fileBrowser.sortKey") ?? ""
        return FileSortKey(rawValue: raw) ?? .name
    }()
    @Published var sortAscending: Bool = UserDefaults.standard.object(forKey: "fileBrowser.sortAscending") as? Bool ?? true
    @Published var transferHistory: [TransferHistoryEntry] = []
    @Published var isPaused = false
    @Published var lastLatencyMs: Int?
    @Published private(set) var recursiveSearchResults: [WebDavItem] = []
    @Published var batchSummary: [BatchSummaryItem]? = nil

    static var pendingRetries: [TransferJob] = []

    private static let folderConcurrencyLimit = 3

    let client: WebDavClient
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var activeTransferTask: Task<Void, Never>?
    private var transferActivity: NSObjectProtocol?
    private var previewCache: [String: MediaPreview] = [:]
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var recursiveSearchTask: Task<Void, Never>?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var endpointLabel: String { "\(client.ip):\(client.port)" }

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

    var visibleSourceItems: [WebDavItem] { isShowingRecursiveResults ? recursiveSearchResults : items }
    var selectedItems: [WebDavItem] { visibleSourceItems.filter { selection.contains($0.id) } }
    var filteredItems: [WebDavItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = visibleSourceItems
        let searched = query.isEmpty ? items : source.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return searched.sorted(by: sortItems)
    }

    var isShowingRecursiveResults: Bool {
        recursiveSearchEnabled && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    var selectedItemsTotalSize: Int64 {
        selectedItems.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
    }

    var selectedItemsSizeLabel: String { Self.formatBytes(selectedItemsTotalSize) }

    static func formatBytes(_ bytes: Int64) -> String {
        let d = Double(bytes)
        if d < 1_024          { return "\(bytes) B" }
        if d < 1_048_576      { return String(format: "%.1f KB", d / 1_024) }
        if d < 1_073_741_824  { return String(format: "%.1f MB", d / 1_048_576) }
        return String(format: "%.2f GB", d / 1_073_741_824)
    }

    init(client: WebDavClient) {
        self.client = client
        if !Self.pendingRetries.isEmpty {
            transferQueue = Self.pendingRetries
            Self.pendingRetries = []
        }
        Task { await load(path: "/") }
    }

    // MARK: - Navigation

    func load(path: String) async {
        if path != currentPath {
            closePreview()
            clearDetailPreview()
            recursiveSearchTask?.cancel()
            recursiveSearchResults = []
        }
        isLoading = true
        errorMessage = nil
        let started = Date()
        do {
            let fetched = try await client.propfind(path: path)
            items = fetched
            currentPath = path
            lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
            updateRecursiveSearch()
        } catch {
            errorMessage = WebDavError.friendly(error)
        }
        isLoading = false
    }

    func activate(_ item: WebDavItem) {
        if item.isDirectory { navigate(to: item.path) }
        else if item.isPreviewableMedia { Task { await preview(item) } }
        else { Task { await download(item) } }
    }

    func navigate(to path: String) {
        guard path != currentPath else { return }
        backStack.append(currentPath)
        forwardStack.removeAll()
        Task { await load(path: path) }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        Task { await load(path: previous) }
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        Task { await load(path: next) }
    }

    func refresh() { Task { await load(path: currentPath) } }
    func reconnect() { Task { await load(path: currentPath) } }

    func openSelected() {
        guard let item = selectedItems.first else { return }
        activate(item)
    }

    func downloadSelection() {
        Task { await downloadSelectedItems() }
    }

    func setSort(_ key: FileSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
        UserDefaults.standard.set(sortKey.rawValue, forKey: "fileBrowser.sortKey")
        UserDefaults.standard.set(sortAscending, forKey: "fileBrowser.sortAscending")
    }

    func setRecursiveSearchEnabled(_ enabled: Bool) {
        recursiveSearchEnabled = enabled
        updateRecursiveSearch()
    }

    func searchTextDidChange() {
        updateRecursiveSearch()
    }

    private func updateRecursiveSearch() {
        recursiveSearchTask?.cancel()
        recursiveSearchResults = []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recursiveSearchEnabled, !query.isEmpty else {
            isSearchingRecursively = false
            return
        }
        let root = currentPath
        isSearchingRecursively = true
        recursiveSearchTask = Task { [weak self] in
            guard let self else { return }
            let results = await self.collectSearchResults(path: root, query: query)
            guard !Task.isCancelled else { return }
            self.recursiveSearchResults = results
            self.isSearchingRecursively = false
        }
    }

    private func collectSearchResults(path: String, query: String) async -> [WebDavItem] {
        if Task.isCancelled { return [] }
        var results: [WebDavItem] = []
        let children: [WebDavItem]
        do {
            children = try await client.propfind(path: path)
        } catch {
            return []
        }
        for child in children {
            if Task.isCancelled { return results }
            if child.name.localizedCaseInsensitiveContains(query) {
                results.append(child)
            }
            if child.isDirectory {
                results.append(contentsOf: await collectSearchResults(path: child.path, query: query))
            }
        }
        return results
    }

    // MARK: - Full-screen media preview

    func preview(_ item: WebDavItem) async {
        guard item.isPreviewableMedia else { return }
        guard let index = previewableItems.firstIndex(where: { $0.id == item.id }) else { return }
        errorMessage = nil

        if let cached = previewCache[item.path] {
            previewIndex = index
            mediaPreview = cached
            updateCacheWindow(around: index)
            return
        }

        // Video: instant streaming, no download needed
        if item.isPreviewableVideo {
            let p = MediaPreview(item: item, kind: .video(makeVideoAsset(for: item)), temporaryURL: nil)
            previewCache[item.path] = p
            previewIndex = index
            mediaPreview = p
            updateCacheWindow(around: index)
            return
        }

        isLoadingPreview = true
        defer { isLoadingPreview = false }
        do {
            let p = try await downloadPreview(for: item)
            previewCache[item.path] = p
            previewIndex = index
            mediaPreview = p
            updateCacheWindow(around: index)
        } catch {
            errorMessage = "Preview failed: \(WebDavError.friendly(error))"
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

    // MARK: - Detail pane preview

    func loadDetailPreview(for item: WebDavItem) {
        guard item.isPreviewableMedia else { clearDetailPreview(); return }
        if let cached = previewCache[item.path] { detailPreview = cached; return }

        // Video: create streaming AVURLAsset instantly — no network download
        if item.isPreviewableVideo {
            let preview = MediaPreview(item: item, kind: .video(makeVideoAsset(for: item)), temporaryURL: nil)
            previewCache[item.path] = preview
            detailPreview = preview
            return
        }

        isLoadingDetailPreview = true
        let targetPath = item.path
        Task { [weak self] in
            guard let self else { return }
            do {
                let p = try await self.downloadPreview(for: item)
                self.previewCache[p.item.path] = p
                if self.selection.contains(targetPath) { self.detailPreview = p }
            } catch { }
            self.isLoadingDetailPreview = false
        }
    }

    func clearDetailPreview() {
        detailPreview = nil
        isLoadingDetailPreview = false
    }

    // MARK: - Private preview helpers

    // Builds an AVURLAsset that streams video directly from the Android server,
    // passing the Authorization header so each range request is authenticated.
    // Connection: close matches Android's close-after-response HTTP server.
    private func makeVideoAsset(for item: WebDavItem) -> AVURLAsset {
        let request = client.videoStreamRequest(for: item.path)
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Connection"] = "close"
        return AVURLAsset(url: request.url!, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    private func downloadPreview(for item: WebDavItem) async throws -> MediaPreview {
        if item.isPreviewableImage {
            let data = try await client.download(path: item.path)
            guard let image = NSImage(data: data) else { throw PreviewError.unsupportedImage }
            return MediaPreview(item: item, kind: .image(image), temporaryURL: nil)
        } else {
            // PDF only — video is handled synchronously via makeVideoAsset
            let url = temporaryPreviewURL(for: item)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try await client.download(path: item.path, to: url)
            return MediaPreview(item: item, kind: .pdf(url), temporaryURL: url)
        }
    }

    private func updateCacheWindow(around index: Int) {
        let all = previewableItems
        guard !all.isEmpty else { return }
        let lo = max(0, index - 5), hi = min(all.count - 1, index + 5)
        let keep = Set((lo...hi).map { all[$0].path })

        for path in Array(previewCache.keys) where !keep.contains(path) { evictFromCache(path: path) }
        for (path, task) in prefetchTasks where !keep.contains(path) {
            task.cancel(); prefetchTasks.removeValue(forKey: path)
        }
        for i in lo...hi where i != index {
            let item = all[i]
            guard item.isPreviewableImage else { continue }
            guard previewCache[item.path] == nil, prefetchTasks[item.path] == nil else { continue }
            let path = item.path
            let t = Task { [weak self] in
                guard let self else { return }
                guard let p = try? await self.downloadPreview(for: item) else {
                    self.prefetchTasks.removeValue(forKey: path); return
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
        if let cached = previewCache.removeValue(forKey: path), let url = cached.temporaryURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Download

    func download(_ item: WebDavItem) async {
        if item.isDirectory {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.canCreateDirectories = true; panel.prompt = "Download Here"
            guard await panel.begin() == .OK, let dest = panel.url else { return }
            enqueueFolderDownload(item, destination: dest.appendingPathComponent(item.name))
        } else {
            // Auto-land single files in ~/Downloads/MiDoid/ — no save dialog needed.
            let landingDir = IncomingFileServer.landingFolder(for: item.name)
            try? FileManager.default.createDirectory(at: landingDir, withIntermediateDirectories: true)
            let dest = IncomingFileServer.uniqueURL(in: landingDir, filename: item.name)
            enqueueDownload(item, destination: dest)
        }
    }

    func downloadSelectedItems() async {
        let toDownload = selectedItems
        guard !toDownload.isEmpty else { return }
        if toDownload.count == 1 { await download(toDownload[0]); return }

        // Auto-land to ~/Downloads/MiDoid/<type>/ — same as single-file, no save dialog.
        let baseLandingDir = IncomingFileServer.landingFolder()
        try? FileManager.default.createDirectory(at: baseLandingDir, withIntermediateDirectories: true)
        for item in toDownload {
            if item.isDirectory {
                let dest = baseLandingDir.appendingPathComponent("Folders", isDirectory: true).appendingPathComponent(item.name)
                enqueueFolderDownload(item, destination: dest)
            } else {
                let landingDir = IncomingFileServer.landingFolder(for: item.name)
                try? FileManager.default.createDirectory(at: landingDir, withIntermediateDirectories: true)
                let dest = IncomingFileServer.uniqueURL(in: landingDir, filename: item.name)
                enqueueDownload(item, destination: dest)
            }
        }
    }

    private func enqueueDownload(_ item: WebDavItem, destination: URL) {
        transferQueue.append(TransferJob(
            kind: .download, name: item.name, sourceURL: nil,
            remotePath: item.path, destinationURL: destination,
            progress: 0, state: .queued, error: nil,
            totalBytes: item.size > 0 ? item.size : nil
        ))
        startTransferQueueIfNeeded()
    }

    private func enqueueFolderDownload(_ item: WebDavItem, destination: URL) {
        transferQueue.append(TransferJob(
            kind: .download, name: item.name, sourceURL: nil,
            remotePath: item.path, destinationURL: destination,
            progress: 0, state: .queued, error: nil, isFolder: true
        ))
        startTransferQueueIfNeeded()
    }

    private func runDownload(_ job: TransferJob) async {
        guard let dest = job.destinationURL else { return }
        if job.isFolder {
            await runFolderDownload(jobId: job.id, remotePath: job.remotePath, localDir: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } else {
            let jobId = job.id
            do {
                try await client.download(path: job.remotePath, to: dest) { [weak self] transferred, total in
                    Task { @MainActor [weak self] in
                        self?.setJobBytes(jobId, transferred: transferred, total: total)
                    }
                }
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                NotificationManager.fileDownloaded(name: job.name, size: size, at: dest)
            } catch {
                markTransfer(job.id, state: .failed, progress: 1,
                             error: WebDavError.friendly(error))
            }
        }
    }

    // MARK: - Folder download

    private func runFolderDownload(jobId: UUID, remotePath: String, localDir: URL) async {
        // Phase 1: Pre-scan so we can show "X of Y files"
        setCurrentFile(jobId, file: "Scanning…")
        let scan = await prescanRemote(remotePath)
        setJobTotals(jobId, totalFiles: scan.fileCount, totalBytes: scan.totalBytes)
        setCurrentFile(jobId, file: nil)

        // Phase 2: Recursive download
        await downloadFolderContents(jobId: jobId, remotePath: remotePath, localDir: localDir)

        // Phase 3: Publish summary
        if let idx = transferQueue.firstIndex(where: { $0.id == jobId }) {
            let job = transferQueue[idx]
            transferQueue[idx].summary = TransferSummary(
                completedFiles: job.completedFiles,
                skippedFiles: job.skippedFiles,
                failedFiles: job.failedFiles,
                transferredBytes: job.transferredBytes,
                destinationURL: job.destinationURL
            )
        }
    }

    private func downloadFolderContents(jobId: UUID, remotePath: String, localDir: URL) async {
        do {
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        } catch {
            markTransfer(jobId, state: .failed, progress: 1,
                         error: "Cannot create \(localDir.lastPathComponent): \(error.localizedDescription)")
            return
        }

        let children: [WebDavItem]
        do {
            children = try await client.propfind(path: remotePath)
        } catch WebDavError.httpStatus(403) {
            reportFileSkipped(jobId)
            setCurrentFile(jobId, file: "\((remotePath as NSString).lastPathComponent) (access denied)")
            return
        } catch { return }

        // Recurse into subdirectories sequentially first
        for child in children where child.isDirectory {
            if Task.isCancelled { return }
            let childLocal = localDir.appendingPathComponent(child.name)
            await downloadFolderContents(jobId: jobId, remotePath: child.path, localDir: childLocal)
        }

        // Download files concurrently with a bounded limit
        let files = children.filter { !$0.isDirectory }
        let cli = client
        await withTaskGroup(of: (Bool, Int64, Bool).self) { group in
            var inFlight = 0
            for child in files {
                if Task.isCancelled { break }
                if inFlight >= Self.folderConcurrencyLimit {
                    if let r = await group.next() { applyDownloadResult(jobId: jobId, r) }
                    inFlight -= 1
                }
                let dest = localDir.appendingPathComponent(child.name)
                let path = child.path; let size = child.size
                inFlight += 1
                group.addTask {
                    do {
                        try await cli.download(path: path, to: dest)
                        return (true, size, false)
                    } catch WebDavError.httpStatus(403) {
                        return (false, 0, true)
                    } catch {
                        return (false, 0, false)
                    }
                }
            }
            for await r in group { applyDownloadResult(jobId: jobId, r) }
        }
    }

    private func applyDownloadResult(jobId: UUID, _ r: (Bool, Int64, Bool)) {
        let (success, bytes, skipped) = r
        if skipped { reportFileSkipped(jobId) }
        else if success { reportFileComplete(jobId, bytes: bytes) }
        else { reportFileFailed(jobId) }
    }

    // MARK: - Upload

    func uploadToCurrentFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.begin { [weak self] result in
            guard result == .OK, let self else { return }
            self.prepareUploadFiles(panel.urls)
        }
    }

    func prepareUploadFiles(_ urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        let folders = urls.filter { $0.hasDirectoryPath }
        for folder in folders { enqueueFolderUpload(folder) }
        guard !files.isEmpty else { return }
        let existingNames = Set(items.map { $0.name.lowercased() })
        let conflicts = files.map(\.lastPathComponent).filter { existingNames.contains($0.lowercased()) }
        if !conflicts.isEmpty {
            pendingUploadConflict = PendingUploadConflict(urls: files, conflictingNames: conflicts)
        } else {
            enqueueUploads(files, renameConflicts: false)
        }
    }

    func uploadPendingConflict(overwrite: Bool) {
        guard let pending = pendingUploadConflict else { return }
        pendingUploadConflict = nil
        enqueueUploads(pending.urls, renameConflicts: !overwrite)
    }

    func cancelPendingConflict() { pendingUploadConflict = nil }

    func skipPendingConflict() {
        guard let pending = pendingUploadConflict else { return }
        pendingUploadConflict = nil
        let conflicts = Set(pending.conflictingNames.map { $0.lowercased() })
        let nonConflicting = pending.urls.filter { !conflicts.contains($0.lastPathComponent.lowercased()) }
        enqueueUploads(nonConflicting, renameConflicts: false)
    }

    private func enqueueUploads(_ urls: [URL], renameConflicts: Bool) {
        let existingNames = Set(items.map { $0.name.lowercased() })
        for url in urls {
            let fileName = renameConflicts && existingNames.contains(url.lastPathComponent.lowercased())
                ? renamedFileName(for: url.lastPathComponent)
                : url.lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            transferQueue.append(TransferJob(
                kind: .upload, name: fileName, sourceURL: url,
                remotePath: pathForChild(named: fileName), destinationURL: nil,
                progress: 0, state: .queued, error: nil,
                totalBytes: size > 0 ? size : nil
            ))
        }
        startTransferQueueIfNeeded()
    }

    private func enqueueFolderUpload(_ folderURL: URL) {
        let name = folderURL.lastPathComponent
        transferQueue.append(TransferJob(
            kind: .upload, name: name, sourceURL: folderURL,
            remotePath: pathForChild(named: name), destinationURL: nil,
            progress: 0, state: .queued, error: nil, isFolder: true
        ))
        startTransferQueueIfNeeded()
    }

    private func runUpload(_ job: TransferJob) async {
        guard let source = job.sourceURL else { return }
        if job.isFolder {
            await runFolderUpload(jobId: job.id, localDir: source, remotePath: job.remotePath)
        } else {
            let jobId = job.id
            do {
                try await client.upload(path: job.remotePath, fileURL: source) { [weak self] sent, total in
                    Task { @MainActor [weak self] in
                        self?.setJobBytes(jobId, transferred: sent, total: total)
                    }
                }
            } catch {
                markTransfer(job.id, state: .failed, progress: 1,
                             error: WebDavError.friendly(error))
            }
        }
    }

    // MARK: - Folder upload

    private func runFolderUpload(jobId: UUID, localDir: URL, remotePath: String) async {
        // Pre-scan local directory to know total count
        let scan = prescanLocal(localDir)
        setJobTotals(jobId, totalFiles: scan.fileCount, totalBytes: scan.totalBytes)

        await uploadFolderContents(jobId: jobId, localDir: localDir, remotePath: remotePath)

        if let idx = transferQueue.firstIndex(where: { $0.id == jobId }) {
            let job = transferQueue[idx]
            transferQueue[idx].summary = TransferSummary(
                completedFiles: job.completedFiles,
                skippedFiles: job.skippedFiles,
                failedFiles: job.failedFiles,
                transferredBytes: job.transferredBytes,
                destinationURL: job.destinationURL
            )
        }
    }

    private func uploadFolderContents(jobId: UUID, localDir: URL, remotePath: String) async {
        do { try await client.mkcol(path: remotePath) }
        catch WebDavError.httpStatus(405) { }
        catch { }

        guard let children = enumerateLocal(localDir) else { return }

        // Recurse into subdirectories sequentially first
        for child in children where child.hasDirectoryPath {
            if Task.isCancelled { return }
            let name = child.lastPathComponent
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let childRemote = remotePath.hasSuffix("/") ? "\(remotePath)\(encoded)" : "\(remotePath)/\(encoded)"
            await uploadFolderContents(jobId: jobId, localDir: child, remotePath: childRemote)
        }

        // Upload files concurrently with a bounded limit
        let files = children.filter { !$0.hasDirectoryPath }
        let cli = client
        await withTaskGroup(of: (Bool, Int64).self) { group in
            var inFlight = 0
            for child in files {
                if Task.isCancelled { break }
                if inFlight >= Self.folderConcurrencyLimit {
                    if let r = await group.next() { applyUploadResult(jobId: jobId, r) }
                    inFlight -= 1
                }
                let name = child.lastPathComponent
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                let childRemote = remotePath.hasSuffix("/") ? "\(remotePath)\(encoded)" : "\(remotePath)/\(encoded)"
                let size = (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                let localURL = child
                inFlight += 1
                group.addTask {
                    do {
                        try await cli.upload(path: childRemote, fileURL: localURL)
                        return (true, size)
                    } catch {
                        return (false, 0)
                    }
                }
            }
            for await r in group { applyUploadResult(jobId: jobId, r) }
        }
    }

    private func applyUploadResult(jobId: UUID, _ r: (Bool, Int64)) {
        if r.0 { reportFileComplete(jobId, bytes: r.1) }
        else { reportFileFailed(jobId) }
    }

    private func enumerateLocal(_ dir: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
    }

    // MARK: - Delete

    func deleteSelected() {
        let toDelete = selectedItems
        guard !toDelete.isEmpty else { return }
        pendingDeleteItems = toDelete
    }

    func confirmDelete() async {
        guard let toDelete = pendingDeleteItems else { return }
        pendingDeleteItems = nil
        selection = []
        clearDetailPreview()
        for item in toDelete {
            do { try await client.delete(path: item.path) }
            catch { errorMessage = "Delete failed: \(WebDavError.friendly(error))" }
        }
        await load(path: currentPath)
    }

    func cancelDelete() { pendingDeleteItems = nil }

    // MARK: - New Folder

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !items.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            errorMessage = "\"\(trimmed)\" already exists in this folder."
            return
        }
        let path = currentPath.hasSuffix("/") ? "\(currentPath)\(trimmed)" : "\(currentPath)/\(trimmed)"
        do {
            try await client.mkcol(path: path)
            await load(path: currentPath)
        } catch {
            errorMessage = "Could not create folder: \(WebDavError.friendly(error))"
        }
    }

    // MARK: - Queue controls

    func pauseTransfers() {
        isPaused = true
    }

    func resumeTransfers() {
        isPaused = false
        startTransferQueueIfNeeded()
    }

    func cancelTransfers() {
        isPaused = false
        activeTransferTask?.cancel()
        activeTransferTask = nil
        isTransferring = false
        transferStatus = "Cancelled"
        transferProgress = 0
        transferQueue = transferQueue.map { job in
            var j = job
            if j.state == .queued || j.state == .running {
                j.state = .cancelled; j.error = nil
                recordHistory(for: j)
            }
            return j
        }
    }

    func retryFailedTransfers() {
        transferQueue = transferQueue.map { job in
            var j = job
            if j.state == .failed || j.state == .cancelled {
                j.state = .queued; j.progress = 0; j.error = nil
                j.startTime = nil; j.currentFile = nil; j.transferredBytes = 0
                j.recentSamples = []; j.smoothedBytesPerSecond = nil
                j.completedFiles = 0; j.skippedFiles = 0; j.failedFiles = 0
                j.summary = nil
            }
            return j
        }
        startTransferQueueIfNeeded()
    }

    func clearCompletedTransfers() {
        transferQueue.removeAll { $0.state == .complete || $0.state == .cancelled }
    }

    func clearTransferHistory() {
        transferHistory.removeAll()
    }

    private func startTransferQueueIfNeeded() {
        guard activeTransferTask == nil else { return }
        activeTransferTask = Task { [weak self] in await self?.processQueue() }
    }

    private func processQueue() async {
        isTransferring = true
        batchSummary = nil
        beginTransferActivity()
        defer {
            isTransferring = false
            transferStatus = ""
            transferProgress = 0
            activeTransferTask = nil
            endTransferActivity()
            Task { await load(path: currentPath) }
        }

        var batchDownloads: [(name: String, bytes: Int64)] = []

        while let index = transferQueue.firstIndex(where: { $0.state == .queued }) {
            // Pause gate: spin-wait until unpaused (300 ms poll — cheap while idle)
            while isPaused && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if Task.isCancelled { break }
            transferQueue[index].state = .running
            transferQueue[index].progress = 0.05
            transferQueue[index].startTime = Date()
            transferQueue[index].recentSamples = [TransferSample(date: Date(), bytes: 0)]
            transferQueue[index].smoothedBytesPerSecond = nil
            let job = transferQueue[index]
            transferStatus = "\(job.kind.rawValue)ing \(job.name)…"
            transferProgress = 0.05

            switch job.kind {
            case .upload:   await runUpload(job)
            case .download: await runDownload(job)
            }

            if Task.isCancelled {
                markTransfer(job.id, state: .cancelled, progress: 0, error: nil)
                break
            }
            if let idx = transferQueue.firstIndex(where: { $0.id == job.id }),
               transferQueue[idx].state == .running {
                markTransfer(job.id, state: .complete, progress: 1, error: nil)
                if job.kind == .download && !job.isFolder,
                   let done = transferQueue.first(where: { $0.id == job.id }) {
                    batchDownloads.append((name: job.name, bytes: done.transferredBytes))
                }
            }
            transferProgress = 1
        }

        if batchDownloads.count > 1 {
            var groups: [String: (Int, Int64)] = [:]
            for item in batchDownloads {
                let cat = IncomingFileServer.folderName(for: item.name)
                let ex = groups[cat] ?? (0, 0)
                groups[cat] = (ex.0 + 1, ex.1 + item.bytes)
            }
            batchSummary = groups
                .map { BatchSummaryItem(category: $0.key, count: $0.value.0, bytes: $0.value.1) }
                .sorted { $0.count > $1.count }
        }
    }

    // MARK: - Progress helpers

    private func setJobBytes(_ id: UUID, transferred: Int64, total: Int64) {
        guard let idx = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        transferQueue[idx].transferredBytes = transferred
        updateSpeedSample(for: idx, transferred: transferred)
        if total > 0 {
            transferQueue[idx].totalBytes = total
            transferQueue[idx].progress = min(0.99, Double(transferred) / Double(total))
        }
    }

    private func updateSpeedSample(for index: Int, transferred: Int64) {
        let now = Date()
        transferQueue[index].recentSamples.append(TransferSample(date: now, bytes: transferred))
        transferQueue[index].recentSamples.removeAll { now.timeIntervalSince($0.date) > 5 }
        guard let first = transferQueue[index].recentSamples.first,
              let last = transferQueue[index].recentSamples.last,
              last.bytes > first.bytes else { return }
        let elapsed = max(0.1, last.date.timeIntervalSince(first.date))
        transferQueue[index].smoothedBytesPerSecond = Double(last.bytes - first.bytes) / elapsed
    }

    private func setJobTotals(_ id: UUID, totalFiles: Int, totalBytes: Int64) {
        guard let idx = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        transferQueue[idx].totalFiles = totalFiles > 0 ? totalFiles : nil
        transferQueue[idx].totalBytes = totalBytes > 0 ? totalBytes : nil
    }

    private func setCurrentFile(_ id: UUID, file: String?) {
        guard let idx = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        transferQueue[idx].currentFile = file
    }

    private func reportFileComplete(_ id: UUID, bytes: Int64) {
        guard let idx = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        transferQueue[idx].completedFiles += 1
        transferQueue[idx].transferredBytes += bytes
        updateSpeedSample(for: idx, transferred: transferQueue[idx].transferredBytes)
        let job = transferQueue[idx]
        if let total = job.totalFiles, total > 0 {
            // Prefer byte progress when the scan knows sizes; fall back to file count.
            let bytesFraction = job.totalBytes.map { Double(job.transferredBytes) / Double($0) }
            let fileFraction = Double(job.completedFiles) / Double(total)
            transferQueue[idx].progress = min(0.99, bytesFraction ?? fileFraction)
        }
    }

    private func reportFileSkipped(_ id: UUID) {
        guard let idx = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        transferQueue[idx].skippedFiles += 1
    }

    private func reportFileFailed(_ id: UUID) {
        guard let idx = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        transferQueue[idx].failedFiles += 1
    }

    private func markTransfer(_ id: UUID, state: TransferState, progress: Double, error: String?) {
        guard let idx = transferQueue.firstIndex(where: { $0.id == id }) else { return }
        transferQueue[idx].state = state
        transferQueue[idx].progress = progress
        transferQueue[idx].error = error
        if state == .complete || state == .failed || state == .cancelled {
            recordHistory(for: transferQueue[idx])
        }
        if state == .failed, let error {
            errorMessage = "\(transferQueue[idx].name): \(error)"
        }
    }

    private func beginTransferActivity() {
        guard transferActivity == nil else { return }
        transferActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "MiDoid is transferring files"
        )
    }

    private func endTransferActivity() {
        guard let activity = transferActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        transferActivity = nil
    }

    private func recordHistory(for job: TransferJob) {
        guard job.state == .complete || job.state == .failed || job.state == .cancelled else { return }
        let bytes = job.summary?.transferredBytes ?? job.transferredBytes
        let entry = TransferHistoryEntry(
            kind: job.kind,
            name: job.name,
            state: job.state,
            completedAt: Date(),
            bytes: bytes,
            destinationURL: job.destinationURL,
            error: job.error
        )
        guard transferHistory.first(where: { existing in
            existing.name == entry.name &&
            existing.kind == entry.kind &&
            abs(existing.completedAt.timeIntervalSince(entry.completedAt)) < 0.5
        }) == nil else { return }
        transferHistory.insert(entry, at: 0)
        if transferHistory.count > 100 {
            transferHistory.removeLast(transferHistory.count - 100)
        }
    }

    // MARK: - Pre-scan helpers

    private func prescanRemote(_ path: String) async -> (fileCount: Int, totalBytes: Int64) {
        var count = 0; var bytes: Int64 = 0
        do {
            let children = try await client.propfind(path: path)
            for child in children {
                if child.isDirectory {
                    let sub = await prescanRemote(child.path)
                    count += sub.fileCount; bytes += sub.totalBytes
                } else {
                    count += 1; bytes += child.size
                }
            }
        } catch { }
        // Best effort: inaccessible folders still transfer what can be reached.
        return (count, bytes)
    }

    private func prescanLocal(_ dir: URL) -> (fileCount: Int, totalBytes: Int64) {
        var count = 0; var bytes: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                count += 1
                bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            }
        }
        return (count, bytes)
    }

    // MARK: - Path / rename helpers

    private func pathForChild(named name: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return currentPath.hasSuffix("/") ? "\(currentPath)\(encoded)" : "\(currentPath)/\(encoded)"
    }

    private func sortItems(_ lhs: WebDavItem, _ rhs: WebDavItem) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let result: ComparisonResult
        switch sortKey {
        case .name:
            result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .kind:
            result = lhs.displayKind.localizedCaseInsensitiveCompare(rhs.displayKind)
        case .size:
            result = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .modified:
            let left = lhs.modified ?? .distantPast
            let right = rhs.modified ?? .distantPast
            result = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        }
        if result == .orderedSame {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    private func renamedFileName(for name: String) -> String {
        let ns = name as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var counter = 1, candidate = name
        let existing = Set(items.map { $0.name.lowercased() })
        while existing.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    func rename(_ item: WebDavItem, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        guard !trimmed.contains("/") else {
            errorMessage = "Names cannot contain slashes."
            return
        }
        if let existing = items.first(where: {
            $0.id != item.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            pendingRenameConflict = PendingRenameConflict(item: item, requestedName: trimmed, existingItem: existing)
            return
        }
        await performRename(item, to: trimmed, replacing: nil)
    }

    func resolveRenameConflict(_ action: RenameConflictAction) async {
        guard let conflict = pendingRenameConflict else { return }
        pendingRenameConflict = nil
        switch action {
        case .cancel:
            return
        case .replace:
            await performRename(conflict.item, to: conflict.requestedName, replacing: conflict.existingItem)
        case .keepBoth:
            await performRename(conflict.item, to: availableSiblingName(for: conflict.requestedName), replacing: nil)
        }
    }

    func duplicate(_ item: WebDavItem) async {
        let destination = pathForSibling(of: item, named: availableSiblingName(for: copyName(for: item.name)))
        do {
            try await client.copy(from: item.path, to: destination)
            await load(path: currentPath)
            selection = [destination]
        } catch {
            errorMessage = "Copy failed: \(WebDavError.friendly(error))"
        }
    }

    private func performRename(_ item: WebDavItem, to name: String, replacing existing: WebDavItem?) async {
        let destination = pathForSibling(of: item, named: name)
        do {
            if let existing {
                try await client.delete(path: existing.path)
            }
            try await client.move(from: item.path, to: destination)
            selection = [destination]
            clearDetailPreview()
            await load(path: currentPath)
        } catch {
            errorMessage = "Rename failed: \(WebDavError.friendly(error))"
        }
    }

    private func availableSiblingName(for name: String) -> String {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        let existing = Set(items.map { $0.name.lowercased() })
        var counter = 1
        var candidate = name
        while existing.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func copyName(for name: String) -> String {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        return ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
    }

    private func pathForSibling(of item: WebDavItem, named name: String) -> String {
        let parent = (item.path as NSString).deletingLastPathComponent
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        if parent == "/" || parent.isEmpty { return "/\(encoded)" }
        return "\(parent)/\(encoded)"
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
        switch self { case .unsupportedImage: return "This image format could not be previewed." }
    }
}
