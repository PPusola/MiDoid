import SwiftUI
import AppKit
import AVKit
import PDFKit
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @StateObject var viewModel: FileBrowserViewModel
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var isDropTarget = false

    var body: some View {
        ZStack {
            HSplitView {
                leftPane
                    .frame(minWidth: 380)
                DetailPane(viewModel: viewModel)
                    .frame(minWidth: 260)
            }

            if viewModel.mediaPreview != nil {
                MediaPreviewOverlay(viewModel: viewModel)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .animation(.easeInOut(duration: 0.18), value: viewModel.mediaPreview != nil)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await viewModel.createFolder(named: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("File already exists", isPresented: Binding(
            get: { viewModel.pendingUploadConflict != nil },
            set: { if !$0 { viewModel.cancelPendingConflict() } }
        )) {
            Button("Replace") { viewModel.uploadPendingConflict(overwrite: true) }
            Button("Keep Both") { viewModel.uploadPendingConflict(overwrite: false) }
            Button("Cancel", role: .cancel) { viewModel.cancelPendingConflict() }
        } message: {
            Text(conflictMessage)
        }
        .alert("Delete \(pendingDeleteTitle)?", isPresented: Binding(
            get: { viewModel.pendingDeleteItems != nil },
            set: { if !$0 { viewModel.cancelDelete() } }
        )) {
            Button("Delete", role: .destructive) { Task { await viewModel.confirmDelete() } }
            Button("Cancel", role: .cancel) { viewModel.cancelDelete() }
        } message: {
            Text(pendingDeleteMessage)
        }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let message = viewModel.errorMessage {
                errorBanner(message)
                Divider()
            }
            fileContent
            transferPanel
            Divider()
            statusBar
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundColor(viewModel.canGoBack ? .primary : .secondary)
            .disabled(!viewModel.canGoBack)
            .help("Back")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(viewModel.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Button {
                            viewModel.navigate(to: crumb.path)
                        } label: {
                            Text(crumb.name).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .font(idx == viewModel.breadcrumbs.count - 1
                              ? .callout.weight(.semibold) : .callout)
                        .foregroundColor(idx == viewModel.breadcrumbs.count - 1
                                         ? .primary : .secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search", text: $viewModel.searchText).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 160)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            Button(action: viewModel.reconnect) { Image(systemName: "wifi") }
                .buttonStyle(.borderless).help("Reconnect")
                .keyboardShortcut("k", modifiers: [.command])

            Button(action: viewModel.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
                .keyboardShortcut("r", modifiers: [.command])

            Button { showNewFolderAlert = true } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.borderless).help("New Folder")
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(action: viewModel.uploadToCurrentFolder) { Image(systemName: "arrow.up.circle") }
                .buttonStyle(.borderless).help("Upload Files or Folders")
                .keyboardShortcut("u", modifiers: [.command])

            Button { viewModel.deleteSelected() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundColor(viewModel.selection.isEmpty ? .secondary : .red)
                .disabled(viewModel.selection.isEmpty)
                .help("Delete Selected")
                .keyboardShortcut(.delete, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(message).font(.callout).lineLimit(2)
            Spacer()
            Button { viewModel.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - File list

    @ViewBuilder
    private var fileContent: some View {
        if viewModel.isLoading {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredItems.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: isDropTarget ? "tray.and.arrow.down.fill" : "folder")
                    .font(.system(size: 40))
                    .foregroundColor(isDropTarget ? .accentColor : .secondary)
                Text(viewModel.emptyStateTitle).font(.headline)
                Text(viewModel.emptyStateMessage).font(.callout).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                Table(viewModel.filteredItems, selection: $viewModel.selection) {
                    TableColumn("Name") { item in
                        Label(item.name, systemImage: item.sfSymbol).lineLimit(1)
                    }
                    .width(min: 180, ideal: 300)

                    TableColumn("Kind") { item in
                        Text(item.displayKind).foregroundColor(.secondary)
                    }
                    .width(110)

                    TableColumn("Size") { item in
                        Text(item.displaySize).foregroundColor(.secondary)
                    }
                    .width(90)

                    TableColumn("Modified") { item in
                        Text(item.modified.map { relativeDate($0) } ?? "—").foregroundColor(.secondary)
                    }
                    .width(130)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let item = viewModel.items.first(where: { $0.id == id }) {
                        if item.isPreviewableMedia {
                            Button("Preview") { Task { await viewModel.preview(item) } }
                        }
                        if item.isDirectory {
                            Button("Open") { viewModel.navigate(to: item.path) }
                        } else {
                            Button("Download") { Task { await viewModel.download(item) } }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            viewModel.selection = ids
                            viewModel.deleteSelected()
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first,
                       let item = viewModel.items.first(where: { $0.id == id }) {
                        viewModel.activate(item)
                    }
                }

                if viewModel.isLoadingPreview {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading preview…").font(.callout).foregroundColor(.secondary)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .padding(10)
                }
            }
        }
    }

    // MARK: - Transfers

    @ViewBuilder
    private var transferPanel: some View {
        if !viewModel.transferQueue.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("Retry Failed") { viewModel.retryFailedTransfers() }
                        .disabled(!viewModel.transferQueue.contains { $0.state == .failed || $0.state == .cancelled })
                    Button("Cancel") { viewModel.cancelTransfers() }
                        .disabled(!viewModel.isTransferring)
                }

                ForEach(viewModel.transferQueue.suffix(4)) { job in
                    HStack(spacing: 8) {
                        Image(systemName: job.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundColor(transferColor(job.state))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(job.name).lineLimit(1)
                                if job.isFolder {
                                    Image(systemName: "folder.fill")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            if let file = job.currentFile, job.state == .running {
                                Text(file).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            } else {
                                Text(job.error ?? "\(job.kind.rawValue) · \(job.state.rawValue)")
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        ProgressView(value: job.progress).frame(width: 100)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text(viewModel.items.isEmpty ? "No items" : viewModel.fileSummary)
                .font(.caption).foregroundColor(.secondary)
            Divider().frame(height: 12)
            Text("Connected to \(viewModel.endpointLabel)")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            if viewModel.isTransferring {
                ProgressView(value: viewModel.transferProgress)
                    .progressViewStyle(.linear).frame(width: 120)
                Text(viewModel.transferStatus).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: - Helpers

    private var conflictMessage: String {
        guard let conflict = viewModel.pendingUploadConflict else { return "" }
        let names = conflict.conflictingNames.prefix(3).joined(separator: ", ")
        let suffix = conflict.conflictingNames.count > 3 ? " and \(conflict.conflictingNames.count - 3) more" : ""
        return "\(names)\(suffix) already exists in this folder."
    }

    private var pendingDeleteTitle: String {
        guard let items = viewModel.pendingDeleteItems else { return "" }
        if items.count == 1 { return "\"\(items[0].name)\"" }
        return "\(items.count) Items"
    }

    private var pendingDeleteMessage: String {
        guard let items = viewModel.pendingDeleteItems else { return "" }
        if items.count == 1 {
            return items[0].isDirectory
                ? "This folder and all its contents will be permanently deleted from your Android device."
                : "This file will be permanently deleted from your Android device."
        }
        return "\(items.count) items will be permanently deleted from your Android device."
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }

    private func transferColor(_ state: TransferState) -> Color {
        switch state {
        case .queued:    return .secondary
        case .running:   return .accentColor
        case .complete:  return .green
        case .failed:    return .red
        case .cancelled: return .orange
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL {
                    urls.append(url)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8),
                          let url = URL(string: string) {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) { viewModel.prepareUploadFiles(urls) }
        return true
    }
}

// MARK: - Detail pane

private struct DetailPane: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @State private var detailPlayer: AVPlayer? = nil

    private enum DetailState {
        case empty
        case singleFolder(WebDavItem)
        case singleImage(WebDavItem)
        case singleVideo(WebDavItem)
        case singlePDF(WebDavItem)
        case singleFile(WebDavItem)
        case multi(Int, Int64)
    }

    private var detailState: DetailState {
        let sel = viewModel.selectedItems
        switch sel.count {
        case 0: return .empty
        case 1:
            let item = sel[0]
            if item.isDirectory        { return .singleFolder(item) }
            if item.isPreviewableImage { return .singleImage(item) }
            if item.isPreviewableVideo { return .singleVideo(item) }
            if item.isPreviewablePDF   { return .singlePDF(item) }
            return .singleFile(item)
        default:
            let totalSize = sel.reduce(0) { $0 + $1.size }
            return .multi(sel.count, totalSize)
        }
    }

    var body: some View {
        Group {
            switch detailState {
            // Image and PDF fill the pane height — no ScrollView
            case .singleImage(let item):
                imageDetail(item)
            case .singlePDF(let item):
                pdfDetail(item)
            // Everything else scrolls vertically
            case .empty:
                ScrollView { emptyDetail.frame(maxWidth: .infinity) }
            case .singleFolder(let item):
                ScrollView { folderDetail(item).frame(maxWidth: .infinity) }
            case .singleVideo(let item):
                videoDetail(item)
            case .singleFile(let item):
                ScrollView { fileDetail(item).frame(maxWidth: .infinity) }
            case .multi(let count, let sz):
                ScrollView { multiDetail(count: count, size: sz).frame(maxWidth: .infinity) }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { handleSelectionChange() }
        .onChange(of: viewModel.selection) { _ in handleSelectionChange() }
        .onChange(of: viewModel.detailPreview?.id) { _ in updateDetailPlayer() }
    }

    private func handleSelectionChange() {
        let sel = viewModel.selectedItems
        if sel.count == 1, let item = sel.first, item.isPreviewableMedia {
            viewModel.loadDetailPreview(for: item)
        } else {
            viewModel.clearDetailPreview()
        }
    }

    private func updateDetailPlayer() {
        detailPlayer?.pause()
        detailPlayer = nil
        guard case .video(let url) = viewModel.detailPreview?.kind else { return }
        detailPlayer = AVPlayer(url: url)
    }

    // MARK: Empty — current folder summary

    @ViewBuilder
    private var emptyDetail: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 40)
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.45))
            Text(viewModel.currentPath == "/"
                 ? "Android Files"
                 : (viewModel.currentPath as NSString).lastPathComponent)
                .font(.headline)
            Text(viewModel.fileSummary)
                .font(.callout).foregroundColor(.secondary)
            Spacer().frame(height: 40)
        }
        .padding()
    }

    // MARK: Single folder

    @ViewBuilder
    private func folderDetail(_ item: WebDavItem) -> some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 32)
            Image(systemName: "folder.fill")
                .font(.system(size: 52))
                .foregroundColor(.accentColor.opacity(0.85))
            Text(item.name)
                .font(.headline).lineLimit(2).multilineTextAlignment(.center)
            if let modified = item.modified {
                Text("Modified \(relDate(modified))")
                    .font(.caption).foregroundColor(.secondary)
            }
            detailButtons(
                primary: ("Open Folder", { viewModel.navigate(to: item.path) }),
                secondary: ("Download Folder", { Task { await viewModel.download(item) } }),
                item: item
            )
            Spacer().frame(height: 24)
        }
        .padding(.vertical)
    }

    // MARK: Single image — fills available height

    @ViewBuilder
    private func imageDetail(_ item: WebDavItem) -> some View {
        VStack(spacing: 0) {
            // Preview area — expands to fill whatever height is available
            ZStack {
                Color.secondary.opacity(0.07)
                if viewModel.isLoadingDetailPreview {
                    ProgressView()
                } else if let preview = viewModel.detailPreview, case .image(let img) = preview.kind {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                } else {
                    Image(systemName: item.sfSymbol)
                        .font(.system(size: 44)).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Fixed-height bottom section
            bottomSection(item: item,
                primaryLabel: "Full Screen Preview",
                primaryAction: { Task { await viewModel.preview(item) } },
                secondaryLabel: "Download",
                secondaryAction: { Task { await viewModel.download(item) } })
        }
    }

    // MARK: Single PDF — fills available height

    @ViewBuilder
    private func pdfDetail(_ item: WebDavItem) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.secondary.opacity(0.07)
                if viewModel.isLoadingDetailPreview {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading PDF…").font(.caption).foregroundColor(.secondary)
                    }
                } else if let preview = viewModel.detailPreview, case .pdf(let url) = preview.kind {
                    PDFRepresentable(url: url)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 44)).foregroundColor(.secondary)
                        Text("PDF").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            bottomSection(item: item,
                primaryLabel: "Full Screen Preview",
                primaryAction: { Task { await viewModel.preview(item) } },
                secondaryLabel: "Download",
                secondaryAction: { Task { await viewModel.download(item) } })
        }
    }

    // MARK: Single video — fills available height

    @ViewBuilder
    private func videoDetail(_ item: WebDavItem) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if viewModel.isLoadingDetailPreview {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Downloading video…")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                } else if let p = detailPlayer {
                    VideoPlayer(player: p)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 44)).foregroundColor(.white.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            bottomSection(item: item,
                primaryLabel: "Full Screen",
                primaryAction: { Task { await viewModel.preview(item) } },
                secondaryLabel: "Download",
                secondaryAction: { Task { await viewModel.download(item) } })
        }
    }

    // MARK: Single other file

    @ViewBuilder
    private func fileDetail(_ item: WebDavItem) -> some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 32)
            Image(systemName: item.sfSymbol).font(.system(size: 52)).foregroundColor(.secondary)
            Text(item.name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
            Text(item.displayKind).font(.callout).foregroundColor(.secondary)
            metaGroup(item)
            detailButtons(
                primary: ("Download", { Task { await viewModel.download(item) } }),
                secondary: nil,
                item: item
            )
            Spacer().frame(height: 24)
        }
        .padding(.vertical)
    }

    // MARK: Multi-selection

    @ViewBuilder
    private func multiDetail(count: Int, size: Int64) -> some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 32)
            Image(systemName: "square.stack").font(.system(size: 52)).foregroundColor(.secondary)
            Text("\(count) items selected").font(.headline)
            if size > 0 {
                Text(formatSize(size)).font(.callout).foregroundColor(.secondary)
            }
            VStack(spacing: 8) {
                Button("Download All") { Task { await viewModel.downloadSelectedItems() } }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                Button("Delete All", role: .destructive) { viewModel.deleteSelected() }
                    .foregroundColor(.red).buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            Spacer().frame(height: 24)
        }
        .padding(.vertical)
    }

    // MARK: Shared sub-views

    // Bottom section used by image and PDF detail (fixed height)
    private func bottomSection(
        item: WebDavItem,
        primaryLabel: String,
        primaryAction: @escaping () -> Void,
        secondaryLabel: String,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Text(item.name)
                .font(.headline).lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            metaGroup(item)
            VStack(spacing: 6) {
                Button(primaryLabel, action: primaryAction)
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                Button(secondaryLabel, action: secondaryAction)
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                Button("Delete", role: .destructive) {
                    viewModel.selection = [item.id]
                    viewModel.deleteSelected()
                }
                .foregroundColor(.red).buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    // Buttons used by folder/video/file detail (inside ScrollView)
    private func detailButtons(
        primary: (String, () -> Void),
        secondary: (String, () -> Void)?,
        item: WebDavItem
    ) -> some View {
        VStack(spacing: 8) {
            Button(primary.0, action: primary.1)
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            if let sec = secondary {
                Button(sec.0, action: sec.1)
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
            Button("Delete", role: .destructive) {
                viewModel.selection = [item.id]
                viewModel.deleteSelected()
            }
            .foregroundColor(.red).buttonStyle(.bordered).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func metaGroup(_ item: WebDavItem) -> some View {
        VStack(spacing: 4) {
            if !item.isDirectory {
                Text(item.displaySize).font(.callout).foregroundColor(.secondary)
            }
            if let modified = item.modified {
                Text("Modified \(relDate(modified))").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func relDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }

    private func formatSize(_ bytes: Int64) -> String {
        let d = Double(bytes)
        if d < 1_024          { return "\(bytes) B" }
        if d < 1_048_576      { return String(format: "%.1f KB", d / 1_024) }
        if d < 1_073_741_824  { return String(format: "%.1f MB", d / 1_048_576) }
        return String(format: "%.2f GB", d / 1_073_741_824)
    }
}

// MARK: - PDF representable

private struct PDFRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.documentURL != url else { return }
        view.document = PDFDocument(url: url)
        view.autoScales = true
    }
}

// MARK: - Media preview overlay

private struct MediaPreviewOverlay: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @State private var player: AVPlayer? = nil
    @State private var isExpanded = false
    @State private var monitor: Any? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()

            if let preview = viewModel.mediaPreview {
                VStack(spacing: 0) {
                    headerBar(preview: preview)
                    mediaContent(preview: preview)
                }
            } else {
                ProgressView().scaleEffect(1.4).tint(.white)
            }
        }
        .onAppear {
            setupPlayer(for: viewModel.mediaPreview)
            installKeyboardMonitor()
        }
        .onDisappear {
            tearDownKeyboardMonitor()
            player?.pause()
        }
        .onChange(of: viewModel.previewIndex) { _ in
            isExpanded = false
            setupPlayer(for: viewModel.mediaPreview)
        }
    }

    private func headerBar(preview: MediaPreview) -> some View {
        HStack(spacing: 12) {
            Group {
                if let index = viewModel.previewIndex {
                    Text("\(index + 1) / \(viewModel.previewableItems.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.55))
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 52, alignment: .leading)

            Spacer()

            Text(preview.item.name)
                .font(.callout.weight(.medium)).foregroundColor(.white).lineLimit(1)

            Spacer()

            HStack(spacing: 18) {
                // Expand/fit toggle — images only
                if case .image = preview.kind {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "Fit to window" : "Expand to fill")
                }

                Button { viewModel.closePreview() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.75))
                        .font(.system(size: 20))
                }
                .buttonStyle(.borderless).help("Close  (Esc)")
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.45))
    }

    @ViewBuilder
    private func mediaContent(preview: MediaPreview) -> some View {
        ZStack {
            switch preview.kind {
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isExpanded ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

            case .video:
                if let p = player {
                    VideoPlayer(player: p).frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            case .pdf(let url):
                PDFRepresentable(url: url)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if viewModel.isLoadingPreview {
                Color.black.opacity(0.45).ignoresSafeArea()
                ProgressView().scaleEffect(1.4).tint(.white)
            }

            HStack {
                navButton(isLeft: true)
                Spacer()
                navButton(isLeft: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navButton(isLeft: Bool) -> some View {
        let enabled = isLeft ? viewModel.hasPreviousPreview : viewModel.hasNextPreview
        return Button {
            if isLeft { viewModel.previewPrevious() } else { viewModel.previewNext() }
        } label: {
            Image(systemName: isLeft ? "chevron.left" : "chevron.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 68)
                .background(
                    Color.white.opacity(enabled ? 0.14 : 0.04),
                    in: RoundedRectangle(cornerRadius: 10)
                )
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .padding(isLeft ? .leading : .trailing, 14)
    }

    private func setupPlayer(for preview: MediaPreview?) {
        player?.pause()
        player = nil
        guard case .video(let url) = preview?.kind else { return }
        let p = AVPlayer(url: url)
        p.play()
        player = p
    }

    private func installKeyboardMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 123: if viewModel.hasPreviousPreview { viewModel.previewPrevious() }; return nil
            case 124: if viewModel.hasNextPreview     { viewModel.previewNext()     }; return nil
            case 53:  viewModel.closePreview(); return nil
            default:  return event
            }
        }
    }

    private func tearDownKeyboardMonitor() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
    }
}
