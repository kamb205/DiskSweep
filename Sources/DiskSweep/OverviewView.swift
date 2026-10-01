import SwiftUI

// MARK: - Smart Care dashboard

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Smart Care", systemImage: "sparkles").font(.title2.bold())
                Text(Category.dashboard.blurb).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            Divider()
            dashboardContent
        }
    }

    private var dashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let result = model.result, !model.hasFullDiskAccess {
                    FullDiskAccessBanner(deniedCount: result.deniedCount)
                }

                DiskBar(volume: model.volume)

                HStack(spacing: 12) {
                    RecommendedCard()
                    LifetimeCard().frame(width: 260)
                }
                .fixedSize(horizontal: false, vertical: true)

                ForEach(Category.sections.dropFirst(), id: \.title) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                            ForEach(section.categories) { CategoryCard(category: $0) }
                        }
                    }
                }

                if let result = model.result {
                    Text("Scanned \(result.scannedFiles.formatted()) files (\(Fmt.bytes(result.scannedBytes))) in \(Int(result.duration)) seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

struct RecommendedCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = model.recommendedItems
        let total = items.reduce(0) { $0 + $1.size }
        let allSelected = !items.isEmpty && items.allSatisfy { model.selection.contains($0.path) }

        HStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 4) {
                Text(items.isEmpty ? "Nothing to clean right now" : "\(Fmt.bytes(total)) of junk is safe to remove")
                    .font(.title3.bold())
                Text(items.isEmpty
                     ? "No caches, logs or build files marked Safe were found."
                     : "\(items.count) caches, logs, installers, build folders and repeat downloads that are rebuilt, downloaded again or kept elsewhere.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !items.isEmpty {
                Button {
                    if allSelected { model.deselectAll(items) } else { model.selectRecommended() }
                } label: {
                    Text(allSelected ? "Deselect" : "Select Recommended").frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(18)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.25)))
    }
}

struct CategoryCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    let category: Category

    var body: some View {
        Button {
            model.navigate(to: category)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: category.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(category.title).font(.headline)
                Text(value)
                    .font(.title3.bold())
                    .monospacedDigit()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var value: String {
        switch category {
        case .memory: Fmt.bytes(Int64(monitor.memory.used))
        case .background: "\(monitor.launchItems.filter(\.isEnabled).count) on"
        case .speedSettings: "Checklist"
        default: Fmt.bytes(model.total(for: category))
        }
    }

    private var subtitle: String {
        switch category {
        case .memory: "in use right now"
        case .background: "helpers running in the background"
        case .speedSettings: "Settings that speed up your Mac"
        case .duplicates: "\(model.count(for: category)) groups"
        case .spaceLens: "Browse by folder"
        case .trash: model.result?.trashSize == nil ? "Needs Full Disk Access" : Fmt.items(model.count(for: category))
        default: Fmt.items(model.count(for: category))
        }
    }
}

// MARK: - Space Lens

/// Drill-down list of the biggest folders measured during the scan. Each folder you open is a
/// step in the Back/Forward history.
struct SpaceLensView: View {
    @EnvironmentObject var model: AppModel

    private var root: String { model.result?.root ?? "/" }
    private var folder: String { model.spaceLensFolder }

    /// Subfolders plus files of 1 MB or more directly inside the current folder, biggest first.
    private var rows: [(path: String, size: Int64)] {
        guard let sizes = model.result?.folderSizes else { return [] }
        let folders = (model.children[folder] ?? []).map { ($0, sizes[$0] ?? 0) }
        let files = (model.result?.files ?? []).filter { $0.parentPath == folder }.map { ($0.path, $0.size) }
        return (folders + files)
            .filter { $0.1 > 0 && (model.search.isEmpty || ($0.0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(model.search)) }
            .sorted { $0.1 > $1.1 }
            .prefix(80)
            .map { $0 }
    }

    private var breadcrumbs: [String] {
        var crumbs = [folder]
        var path = folder
        while path != root {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            crumbs.insert(parent, at: 0)
            path = parent
        }
        return crumbs
    }

    var body: some View {
        let rows = rows
        let maxSize = rows.first?.size ?? 1
        VStack(spacing: 0) {
            lensHeader
            Divider()
            HStack(spacing: 0) {
                SunburstView(folder: folder, root: root)
                    .padding(20)
                    .frame(minWidth: 320, maxWidth: .infinity)
                Divider()
                folderList(rows: rows, maxSize: maxSize)
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
        }
    }

    private func folderList(rows: [(path: String, size: Int64)], maxSize: Int64) -> some View {
            ScrollView {
            VStack(spacing: 0) {
                ForEach(rows, id: \.path) { row in
                    FolderRow(path: row.path, size: row.size, fraction: Double(row.size) / Double(max(maxSize, 1)),
                              canOpen: !(model.children[row.path] ?? []).isEmpty) {
                        model.openFolder(row.path)
                    }
                    Divider()
                }
                if rows.isEmpty {
                    Text("Nothing measured inside this folder.").foregroundStyle(.secondary).padding(30)
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
            }
    }

    private var lensHeader: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Space Lens", systemImage: "chart.pie").font(.title2.bold())
                    Spacer()
                    Text(Fmt.bytes(model.result?.folderSizes[folder] ?? 0))
                        .font(.title3.bold())
                        .monospacedDigit()
                }
                Text(Category.spaceLens.blurb).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(breadcrumbs, id: \.self) { crumb in
                        if crumb != breadcrumbs.first {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button(crumb == "/" ? "Macintosh HD" : (crumb as NSString).lastPathComponent) {
                            model.openFolder(crumb)
                        }
                        .buttonStyle(.link)
                        .disabled(crumb == folder)
                    }
                    Spacer()
                    Button("Show in Finder") { model.reveal([folder]) }
                }
                .font(.callout)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 10)
    }
}

struct FolderRow: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let size: Int64
    let fraction: Double
    let canOpen: Bool
    let open: () -> Void

    var body: some View {
        let selectable = model.canSelectInSpaceLens(path)
        let checked = model.selection.contains(path)
        HStack(spacing: 10) {
            Toggle("", isOn: model.spaceLensBinding(for: path))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!selectable)
                .help(selectable ? "Tick to move this to the Trash" : "Protected by macOS. DiskSweep won't remove this")
            FileIcon(path: path)
            Text((path as NSString).lastPathComponent)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(.tint.opacity(0.7))
                    .frame(width: max(geo.size.width * fraction, 2), height: 8)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            Text(Fmt.bytes(size))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Image(systemName: "chevron.right")
                .foregroundStyle(canOpen ? .secondary : .quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(checked ? AnyShapeStyle(.red.opacity(0.14)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture { if canOpen { open() } }
        .contextMenu {
            if canOpen { Button("Open") { open() } }
            if selectable {
                Button(checked ? "Untick" : "Tick for Trash") { model.spaceLensBinding(for: path).wrappedValue.toggle() }
            }
            Button("Show in Finder") { model.reveal([path]) }
        }
    }
}

// MARK: - Trash bins

/// Lists what's actually in the macOS Trash. Items can be put back where they came from or erased
/// one by one; both change the real Trash, exactly as Finder's Put Back and Delete Immediately do.
struct TrashView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmingErase = false
    @State private var confirmingEmpty = false

    private var entries: [TrashEntry] {
        let all = model.trashEntries ?? []
        guard !model.search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(model.search) }
    }

    var body: some View {
        let entries = entries
        let total = (model.trashEntries ?? []).reduce(0) { $0 + $1.size }
        let selected = model.selectedTrashEntries
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    Label("Trash Bins", systemImage: "trash").font(.title2.bold())
                    if model.trashEntries != nil {
                        Text("\(Fmt.items(model.trashEntries?.count ?? 0)) · \(Fmt.bytes(total))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.leading, 6)
                    }
                    Spacer()
                    Button {
                        confirmingEmpty = true
                    } label: {
                        if model.isEmptyingTrash { ProgressView().controlSize(.small) } else { Label("Empty Trash…", systemImage: "trash.slash") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled((model.trashEntries?.isEmpty ?? false) || model.isEmptyingTrash)
                }
                Text("Everything currently in your Trash. Put back the items you want to keep, then erase the rest or empty the whole Trash. Changes here happen in the real macOS Trash.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Select All") { model.trashSelection = Set((model.trashEntries ?? []).map(\.path)) }
                        .disabled(entries.isEmpty)
                    Button("Select None") { model.trashSelection = [] }
                        .disabled(model.trashSelection.isEmpty)
                    Spacer()
                    Button {
                        model.putBackSelected()
                    } label: {
                        Label("Put Back \(selected.isEmpty ? "" : "\(selected.count) ")", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(selected.isEmpty)
                    Button(role: .destructive) {
                        confirmingErase = true
                    } label: {
                        Label("Delete Permanently…", systemImage: "xmark.bin")
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)
            Divider()

            if model.trashEntries == nil {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("DiskSweep can't see inside the Trash").font(.title3.bold())
                    Text("macOS only lets apps with Full Disk Access read the Trash.").foregroundStyle(.secondary)
                    if !model.hasFullDiskAccess { FullDiskAccessBanner().frame(maxWidth: 620) }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("The Trash is empty", systemImage: "trash",
                                       description: Text("Items you move to the Trash will show up here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 22, height: 1)
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Size").frame(width: 90, alignment: .trailing)
                    Text("Trashed").frame(width: 130, alignment: .leading)
                    Text("Put Back To").frame(width: 260, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            TrashRow(entry: entry, striped: index.isMultiple(of: 2))
                        }
                    }
                }
            }
        }
        .confirmationDialog("Permanently erase \(selected.count) item\(selected.count == 1 ? "" : "s") (\(Fmt.bytes(selected.reduce(0) { $0 + $1.size })))?",
                            isPresented: $confirmingErase, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) { model.deleteSelectedPermanently() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Permanently erase everything in the Trash?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. macOS may ask whether DiskSweep can control Finder. That's how the Trash gets emptied.")
        }
        .alert("Trash", isPresented: Binding(get: { model.trashMessage != nil }, set: { if !$0 { model.trashMessage = nil } })) {
            Button("OK") { model.trashMessage = nil }
        } message: {
            Text(model.trashMessage ?? "")
        }
        .onAppear { model.refreshTrash() }
    }
}

struct TrashRow: View {
    @EnvironmentObject var model: AppModel
    let entry: TrashEntry
    let striped: Bool

    var body: some View {
        let checked = model.trashSelection.contains(entry.path)
        let toggle = { if checked { model.trashSelection.remove(entry.path) } else { model.trashSelection.insert(entry.path) } }
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { checked }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 22)
            HStack(spacing: 8) {
                FileIcon(path: entry.path, size: 22)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.bytes(entry.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(Fmt.relative(entry.trashedDate)).frame(width: 130, alignment: .leading)
            Text(entry.originalPath.map { Fmt.path(($0 as NSString).deletingLastPathComponent) } ?? "Downloads › Restored from Trash")
                .foregroundStyle(entry.originalPath == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 260, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(checked ? AnyShapeStyle(.tint.opacity(0.14)) : striped ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .help(entry.originalPath ?? entry.path)
    }
}

struct LifetimeCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Lifetime", systemImage: "leaf.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Text(Fmt.bytes(model.lifetime.bytes))
                .font(.title2.bold())
                .monospacedDigit()
            Text(model.lifetime.bytes == 0
                 ? "Freed with DiskSweep. Space counts once it leaves the Trash."
                 : "freed with DiskSweep · \(model.lifetime.items) items since \(model.lifetime.since.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "today")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.lifetime.pendingBytes > 0 {
                Label("\(Fmt.bytes(model.lifetime.pendingBytes)) waiting in the Trash", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Counts once the Trash is emptied. Items you put back aren't counted.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(18)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.green.opacity(0.25)))
    }
}
