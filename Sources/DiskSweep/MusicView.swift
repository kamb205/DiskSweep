import SwiftUI

/// Audio and project files grouped by what their names say (Masters, Vocals, Bass & 808s…).
struct MusicView: View {
    var body: some View {
        GroupedItemsView(
            category: .music,
            groups: MusicTagger.groups.map { ($0.name, $0.symbol) } + [(MusicTagger.otherGroup, MusicTagger.symbol(for: MusicTagger.otherGroup))],
            unit: "files",
            emptyTitle: "No music files found", emptySymbol: "music.note",
            emptyText: "Audio files (WAV, AIFF, MP3, FLAC…) and DAW projects in your folders will show up here.")
    }
}

/// A page of items split into named groups with filter chips. Each group can be kept whole,
/// marked for removal whole, or picked through item by item. Used by Music & Stems and Downloads.
struct GroupedItemsView: View {
    @EnvironmentObject var model: AppModel
    @State private var focusedGroup: String?
    let category: Category
    /// Display order and symbol of each group; items in other groups go last.
    let groups: [(name: String, symbol: String)]
    let unit: String
    let emptyTitle: String
    let emptySymbol: String
    let emptyText: String

    private func symbol(_ name: String) -> String { groups.first { $0.name == name }?.symbol ?? "doc" }

    private var grouped: [(name: String, items: [Item])] {
        let search = model.search
        let items = model.items(for: category).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }
        let byGroup = Dictionary(grouping: items) { $0.group ?? "" }
        let known = groups.map(\.name)
        let order = known + byGroup.keys.filter { !known.contains($0) }.sorted()
        return order.compactMap { name in
            guard let items = byGroup[name], !items.isEmpty else { return nil }
            return (name, items.sorted { $0.size > $1.size })
        }
    }

    var body: some View {
        let groups = grouped
        let visible = focusedGroup.map { focus in groups.filter { $0.name == focus } } ?? groups
        let all = groups.flatMap(\.items)
        VStack(spacing: 0) {
            CategoryHeader(category: category, items: all,
                           countLabel: "\(all.count) \(all.count == 1 ? String(unit.dropLast()) : unit) · \(Fmt.bytes(all.reduce(0) { $0 + $1.size }))")
            chips(groups)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyText))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(visible, id: \.name) { group in
                            Section {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    ItemRow(item: item, striped: index.isMultiple(of: 2))
                                }
                            } header: {
                                MusicGroupHeader(name: group.name, symbol: symbol(group.name), unit: unit, items: group.items)
                            }
                        }
                    }
                }
            }
        }
    }

    private func chips(_ groups: [(name: String, items: [Item])]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", symbol: category.symbol, count: groups.reduce(0) { $0 + $1.items.count }, selected: focusedGroup == nil) {
                    focusedGroup = nil
                }
                ForEach(groups, id: \.name) { group in
                    chip(group.name, symbol: symbol(group.name), count: group.items.count,
                         selected: focusedGroup == group.name) {
                        focusedGroup = focusedGroup == group.name ? nil : group.name
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private func chip(_ title: String, symbol: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title)
                Text("\(count)").foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct MusicGroupHeader: View {
    @EnvironmentObject var model: AppModel
    let name: String
    let symbol: String
    let unit: String
    let items: [Item]

    var body: some View {
        let paths = items.map(\.path)
        let selectedCount = paths.filter { model.selection.contains($0) }.count
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(name).font(.headline)
            Text("\(items.count) \(items.count == 1 ? String(unit.dropLast()) : unit) · \(Fmt.bytes(items.reduce(0) { $0 + $1.size }))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if selectedCount > 0 {
                Text("\(selectedCount) to remove").font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Button("Keep All") { model.selection.subtract(paths) }
                .disabled(selectedCount == 0)
                .help("Untick every file in \(name)")
            Button("Remove All…") { model.selection.formUnion(paths) }
                .disabled(selectedCount == items.count)
                .help("Tick every file in \(name) for removal")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
