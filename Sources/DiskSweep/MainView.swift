import SwiftUI

/// The results window: a fixed sidebar that is always visible, and the selected page beside it.
/// Built from plain SwiftUI stacks and scroll views (no NSTableView-backed Table/List), so page
/// headers, column titles and the Trash bar always keep their place on screen.
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showSidebar") private var showSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                Sidebar()
                    .transition(.move(edge: .leading))
                Divider()
            }
            VStack(spacing: 0) {
                Group {
                    switch model.category {
                    case .dashboard: DashboardView()
                    case .memory: MemoryView()
                    case .background: BackgroundItemsView()
                    case .speedSettings: SpeedSettingsView()
                    case .trash: TrashView()
                    case .spaceLens: SpaceLensView()
                    case .duplicates: DuplicatesView()
                    case .music: MusicView()
                    case .downloads: DownloadsView()
                    default: ItemListView(category: model.category).id(model.category)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The Trash page has its own Put Back / Delete buttons.
                if ![.trash, .memory, .background, .speedSettings].contains(model.category) { ActionBar() }
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Filter by name")
        .navigationTitle(model.category.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
                } label: {
                    Label(showSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(showSidebar ? "Hide the sidebar (⌃⌘S)" : "Show the sidebar (⌃⌘S)")
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back")
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Forward")
            }
            ToolbarItemGroup {
                Button { model.startScan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .help("Scan the same location again")
                Button { model.showStartScreen() } label: { Label("New Scan", systemImage: "plus.magnifyingglass") }
                    .help("Choose what to scan. Your current results stay available.")
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $model.confirmingTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert(item: $model.trashReport) { report in
            Alert(
                title: Text("Moved \(report.movedCount) item\(report.movedCount == 1 ? "" : "s") to the Trash"),
                message: Text(reportMessage(report)),
                dismissButton: .default(Text("Done"))
            )
        }
    }

    private var confirmTitle: String {
        "Move \(model.selection.count) item\(model.selection.count == 1 ? "" : "s") (\(Fmt.bytes(model.selectedBytes))) to the Trash?"
    }

    private var confirmMessage: String {
        var lines = ["You can put items back from the Trash until you empty it."]
        if model.selectedCautionCount > 0 {
            lines.append("⚠️ \(model.selectedCautionCount) selected item(s) are marked Careful (apps or possible app data). Apps are removed together with their caches and settings.")
        }
        if model.fullySelectedDuplicateGroups > 0 {
            lines.append("⚠️ For \(model.fullySelectedDuplicateGroups) duplicate group(s), every copy is selected, so no copy will be kept.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func reportMessage(_ report: TrashReport) -> String {
        var text = "\(Fmt.bytes(report.movedBytes)) will be freed when the Trash is emptied."
        if !report.failures.isEmpty {
            text += "\n\n\(report.failures.count) item(s) couldn't be moved:\n"
            text += report.failures.prefix(6)
                .map { "• \(($0.path as NSString).lastPathComponent): \($0.reason)" }
                .joined(separator: "\n")
            if report.failures.count > 6 { text += "\n…and \(report.failures.count - 6) more" }
        }
        return text
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // A plain stack, not a scroll view: every section fits, and it can never scroll out of view.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Category.sections, id: \.title) { section in
                    Text(section.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, section.title == Category.sections.first?.title ? 4 : 12)
                        .padding(.bottom, 3)
                    ForEach(section.categories) { SidebarRow(category: $0) }
                }
            }
            .padding(10)
            Spacer(minLength: 0)
            if model.lifetime.bytes > 0 {
                Label("\(Fmt.bytes(model.lifetime.bytes)) freed all-time", systemImage: "leaf.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.bottom, 8)
                    .help("Total space DiskSweep has freed since \(model.lifetime.since.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "you started")")
            }
            Divider()
            MadeWithLove()
                .font(.caption)
                .padding(.vertical, 10)
        }
        .frame(width: 250)
        .background(.background.secondary)
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    let category: Category

    private var badge: String? {
        switch category {
        case .memory: return Fmt.bytes(Int64(monitor.memory.used))
        case .background:
            let on = monitor.launchItems.filter(\.isEnabled).count
            return on > 0 ? "\(on) on" : nil
        default:
            let total = model.total(for: category)
            return total > 0 ? Fmt.bytes(total) : nil
        }
    }

    var body: some View {
        let selected = model.category == category
        let badge = badge
        Button {
            model.navigate(to: category)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: category.symbol)
                    .frame(width: 20)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                Text(category.title)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Action bar

struct ActionBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if model.isTrashing {
                ProgressView().controlSize(.small)
                Text("Moving to Trash…")
            } else if model.selection.isEmpty {
                Text("Tick the items you want to remove.").foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                Text("\(model.selection.count) selected · \(Fmt.bytes(model.selectedBytes))")
                    .monospacedDigit()
                if model.fullySelectedDuplicateGroups > 0 {
                    Label("All copies selected in \(model.fullySelectedDuplicateGroups) duplicate group(s)",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            Spacer()
            Button("Clear Selection") { model.selection.removeAll() }
                .disabled(model.selection.isEmpty || model.isTrashing)
            TrashButton()
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct TrashButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.confirmingTrash = true
        } label: {
            Label(model.selection.isEmpty ? "Move to Trash…" : "Move \(model.selection.count) to Trash…", systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(model.selection.isEmpty || model.isTrashing)
    }
}

// MARK: - Category header

struct CategoryHeader: View {
    @EnvironmentObject var model: AppModel
    let category: Category
    let items: [Item]
    var countLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Label(category.title, systemImage: category.symbol).font(.title2.bold())
                Text(countLabel ?? "\(items.count) item\(items.count == 1 ? "" : "s") · \(Fmt.bytes(items.reduce(0) { $0 + $1.size }))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, 6)
                Spacer()
                TrashButton()
            }
            Text(category.blurb)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                filters
                Spacer()
                Button(category == .duplicates ? "Select Extra Copies" : "Select All") {
                    model.selectAll(in: category, items: items)
                }
                .disabled(items.isEmpty)
                Button("Select None") { model.deselectAll(items) }
                    .disabled(items.isEmpty)
            }
        }
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var filters: some View {
        switch category {
        case .large:
            Picker("Bigger than", selection: $model.largeMin) {
                ForEach(AppModel.largeSizeOptions, id: \.self) { Text(Fmt.bytes($0)).tag($0) }
            }
            .fixedSize()
        case .old:
            Picker("Not opened for", selection: $model.oldDays) {
                ForEach(AppModel.oldDayOptions, id: \.days) { Text($0.label).tag($0.days) }
            }
            .fixedSize()
            Picker("and bigger than", selection: $model.oldMin) {
                ForEach(AppModel.oldSizeOptions, id: \.self) { Text(Fmt.bytes($0)).tag($0) }
            }
            .fixedSize()
        default:
            EmptyView()
        }
    }
}

// MARK: - Item list

enum ItemSortKey { case name, size, lastUsed, safety, location }

private enum Column {
    static let check: CGFloat = 22
    static let size: CGFloat = 90
    static let lastUsed: CGFloat = 130
    static let safety: CGFloat = 80
    static let location: CGFloat = 230
}

struct ItemListView: View {
    @EnvironmentObject var model: AppModel
    let category: Category
    @State private var sortKey: ItemSortKey = .size
    @State private var ascending = false

    private var rows: [Item] {
        let search = model.search
        let filtered = search.isEmpty ? model.items(for: category) : model.items(for: category).filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
        }
        let sorted: [Item]
        switch sortKey {
        case .name: sorted = filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: sorted = filtered.sorted { $0.size < $1.size }
        case .lastUsed: sorted = filtered.sorted { $0.lastUsedSort < $1.lastUsedSort }
        case .safety: sorted = filtered.sorted { $0.safetyRank < $1.safetyRank }
        case .location: sorted = filtered.sorted { $0.path < $1.path }
        }
        return ascending ? sorted : sorted.reversed()
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            CategoryHeader(category: category, items: rows)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "checkmark.seal",
                                       description: Text("No items in this category match your filters."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                columnTitles
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            ItemRow(item: item, striped: index.isMultiple(of: 2))
                        }
                    }
                }
            }
        }
    }

    private var columnTitles: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Column.check, height: 1)
            sortButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("Size", .size).frame(width: Column.size, alignment: .trailing)
            sortButton("Last Opened", .lastUsed).frame(width: Column.lastUsed, alignment: .leading)
            sortButton("Safety", .safety).frame(width: Column.safety, alignment: .leading)
            sortButton("Location", .location).frame(width: Column.location, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func sortButton(_ title: String, _ key: ItemSortKey) -> some View {
        Button {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = key == .name || key == .location }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortKey == key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: Item
    let striped: Bool

    var body: some View {
        let checked = model.selection.contains(item.path)
        HStack(spacing: 10) {
            Toggle("", isOn: model.binding(for: item.path))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: Column.check)
            HStack(spacing: 8) {
                FileIcon(path: item.path, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1)
                    Text(item.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.bytes(item.size))
                .monospacedDigit()
                .frame(width: Column.size, alignment: .trailing)
            Text(Fmt.relative(item.lastUsed))
                .frame(width: Column.lastUsed, alignment: .leading)
            SafetyBadge(safety: item.safety)
                .frame(width: Column.safety, alignment: .leading)
            Text(Fmt.path(item.parentPath))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Column.location, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(checked ? AnyShapeStyle(.tint.opacity(0.14)) : striped ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        // Click anywhere on the row to tick it; double-click shows it in Finder.
        .onTapGesture(count: 2) { model.reveal([item.path]) }
        .onTapGesture { model.binding(for: item.path).wrappedValue.toggle() }
        .help(item.path)
        .contextMenu {
            Button("Show in Finder") { model.reveal([item.path]) }
            Button(checked ? "Untick" : "Tick") { model.binding(for: item.path).wrappedValue.toggle() }
        }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let groups = model.duplicateGroups.filter { group in
            model.search.isEmpty || group.items.contains { $0.name.localizedCaseInsensitiveContains(model.search) }
        }
        VStack(spacing: 0) {
            CategoryHeader(
                category: .duplicates,
                items: groups.flatMap(\.items),
                countLabel: "\(groups.count) groups · \(Fmt.bytes(model.total(for: .duplicates))) wasted"
            )
            Divider()
            if groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "checkmark.seal",
                                       description: Text("No identical files over 1 MB were found in your folders."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in
                            VStack(spacing: 0) {
                                DuplicateHeader(group: group)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                Divider()
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    DuplicateRow(item: item, suggestedKeep: index == 0)
                                        .padding(.horizontal, 12)
                                    if index < group.items.count - 1 { Divider().padding(.leading, 12) }
                                }
                            }
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct DuplicateHeader: View {
    @EnvironmentObject var model: AppModel
    let group: DuplicateGroup

    var body: some View {
        HStack {
            Text("\(group.items.count) copies of \(group.items.first?.name ?? "")")
                .font(.headline)
                .lineLimit(1)
            Text("· \(Fmt.bytes(group.fileSize)) each").foregroundStyle(.secondary)
            Spacer()
            if group.items.allSatisfy({ model.selection.contains($0.path) }) {
                Label("No copy kept", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Text("\(Fmt.bytes(group.wasted)) wasted").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct DuplicateRow: View {
    @EnvironmentObject var model: AppModel
    let item: Item
    let suggestedKeep: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: model.binding(for: item.path))
                .toggleStyle(.checkbox)
                .labelsHidden()
            FileIcon(path: item.path, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1)
                    if suggestedKeep && !model.selection.contains(item.path) {
                        Text("Keep")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundStyle(.green)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }
                Text(Fmt.path(item.parentPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Opened \(Fmt.relative(item.lastUsed).lowercased())").font(.caption)
                Text("Modified \(Fmt.relative(item.modified).lowercased())").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                model.reveal([item.path])
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.binding(for: item.path).wrappedValue.toggle() }
    }
}
