import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @StateObject var viewModel: FileBrowserViewModel
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var isDropTarget = false

    var body: some View {
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
        .frame(minWidth: 640, minHeight: 400)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .sheet(item: $viewModel.mediaPreview, onDismiss: {
            viewModel.closePreview()
        }) { preview in
            MediaPreviewView(preview: preview)
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
                            Text(crumb.name)
                                .lineLimit(1)
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
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 180)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            Button(action: viewModel.reconnect) {
                Image(systemName: "wifi")
            }
            .buttonStyle(.borderless)
            .help("Reconnect")
            .keyboardShortcut("k", modifiers: [.command])

            Button(action: viewModel.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .keyboardShortcut("r", modifiers: [.command])

            Button { showNewFolderAlert = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("New Folder")
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(action: viewModel.uploadToCurrentFolder) {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.borderless)
            .help("Upload Files")
            .keyboardShortcut("u", modifiers: [.command])

            Button {
                Task { await previewSelection() }
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .disabled(selectedPreviewItem == nil || viewModel.isLoadingPreview)
            .help("Preview Selected")
            .keyboardShortcut(.space, modifiers: [])

            Button {
                Task { await viewModel.deleteSelected() }
            } label: {
                Image(systemName: "trash")
            }
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
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - File list

    @ViewBuilder
    private var fileContent: some View {
        if viewModel.isLoading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredItems.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: isDropTarget ? "tray.and.arrow.down.fill" : "folder")
                    .font(.system(size: 40))
                    .foregroundColor(isDropTarget ? .accentColor : .secondary)
                Text(viewModel.emptyStateTitle)
                    .font(.headline)
                Text(viewModel.emptyStateMessage)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                Table(viewModel.filteredItems, selection: $viewModel.selection) {
                    TableColumn("Name") { item in
                        Label(item.name, systemImage: item.sfSymbol)
                            .lineLimit(1)
                    }
                    .width(min: 180, ideal: 340)

                    TableColumn("Size") { item in
                        Text(item.displaySize)
                            .foregroundColor(.secondary)
                    }
                    .width(90)

                    TableColumn("Modified") { item in
                        Text(item.modified.map { relativeDate($0) } ?? "—")
                            .foregroundColor(.secondary)
                    }
                    .width(130)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let item = viewModel.items.first(where: { $0.id == id }) {
                        if item.isPreviewableMedia {
                            Button("Preview") { Task { await viewModel.preview(item) } }
                        }
                        if !item.isDirectory {
                            Button("Download") { Task { await viewModel.download(item) } }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            viewModel.selection = ids
                            Task { await viewModel.deleteSelected() }
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
                        Text("Loading preview…")
                            .font(.callout)
                            .foregroundColor(.secondary)
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
                            Text(job.name)
                                .lineLimit(1)
                            Text(job.error ?? "\(job.kind.rawValue) · \(job.state.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        ProgressView(value: job.progress)
                            .frame(width: 110)
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
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
                .frame(height: 12)
            Text("Connected to \(viewModel.endpointLabel)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if viewModel.isTransferring {
                ProgressView(value: viewModel.transferProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text(viewModel.transferStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var conflictMessage: String {
        guard let conflict = viewModel.pendingUploadConflict else { return "" }
        let names = conflict.conflictingNames.prefix(3).joined(separator: ", ")
        let suffix = conflict.conflictingNames.count > 3 ? " and \(conflict.conflictingNames.count - 3) more" : ""
        return "\(names)\(suffix) already exists in this folder."
    }

    private var selectedPreviewItem: WebDavItem? {
        guard viewModel.selection.count == 1,
              let id = viewModel.selection.first,
              let item = viewModel.items.first(where: { $0.id == id }),
              item.isPreviewableMedia else {
            return nil
        }
        return item
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }

    private func transferColor(_ state: TransferState) -> Color {
        switch state {
        case .queued: return .secondary
        case .running: return .accentColor
        case .complete: return .green
        case .failed: return .red
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

        group.notify(queue: .main) {
            viewModel.prepareUploadFiles(urls.filter { !$0.hasDirectoryPath })
        }
        return true
    }

    private func previewSelection() async {
        guard let item = selectedPreviewItem else { return }
        await viewModel.preview(item)
    }
}

private struct MediaPreviewView: View {
    let preview: MediaPreview

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(preview.item.name, systemImage: preview.item.sfSymbol)
                    .lineLimit(1)
                Spacer()
            }
            .padding(12)
            .background(.regularMaterial)

            switch preview.kind {
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.92))
            case .video(let url):
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onDisappear {
            if let url = preview.temporaryURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
