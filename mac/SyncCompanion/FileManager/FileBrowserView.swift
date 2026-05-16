import SwiftUI
import AppKit

struct FileBrowserView: View {
    @StateObject var viewModel: FileBrowserViewModel
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            fileContent
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 400)
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await viewModel.createFolder(named: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: viewModel.goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundColor(viewModel.canGoBack ? .primary : .secondary)
            .disabled(!viewModel.canGoBack)

            // Breadcrumb
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(viewModel.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Button(crumb.name) { viewModel.navigate(to: crumb.path) }
                            .buttonStyle(.plain)
                            .font(idx == viewModel.breadcrumbs.count - 1
                                  ? .callout.weight(.semibold) : .callout)
                            .foregroundColor(idx == viewModel.breadcrumbs.count - 1
                                             ? .primary : .secondary)
                    }
                }
            }

            Spacer()

            Button(action: viewModel.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button { showNewFolderAlert = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help("New Folder")

            Button(action: viewModel.uploadToCurrentFolder) {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.plain)
            .help("Upload Files")

            Button {
                Task { await viewModel.deleteSelected() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(viewModel.selection.isEmpty ? .secondary : .red)
            .disabled(viewModel.selection.isEmpty)
            .help("Delete Selected")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - File list

    @ViewBuilder
    private var fileContent: some View {
        if viewModel.isLoading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("Empty folder")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(viewModel.items, selection: $viewModel.selection) {
                TableColumn("Name") { item in
                    Label(item.name, systemImage: item.sfSymbol)
                        .lineLimit(1)
                }
                .width(min: 160, ideal: 280)

                TableColumn("Size") { item in
                    Text(item.displaySize)
                        .foregroundColor(.secondary)
                }
                .width(80)

                TableColumn("Modified") { item in
                    Text(item.modified.map { relativeDate($0) } ?? "—")
                        .foregroundColor(.secondary)
                }
                .width(130)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first,
                   let item = viewModel.items.first(where: { $0.id == id }) {
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
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            Text(viewModel.items.isEmpty ? "No items" : "\(viewModel.items.count) item\(viewModel.items.count == 1 ? "" : "s")")
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

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }
}
