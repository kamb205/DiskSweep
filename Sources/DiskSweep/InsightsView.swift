import SwiftUI

// MARK: - Storage Insights page

/// Storage Insights: a plain-words explanation of where the disk space goes, what changed since
/// the last scan, and what to do about it. The analysis itself lives in `StorageAnalyst`.
struct InsightsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label(Category.insights.title, systemImage: Category.insights.symbol).font(.title2.bold())
                Text(Category.insights.blurb).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            Divider()
            if let report = model.result?.insights {
                content(report)
            } else {
                ContentUnavailableView("No insights yet", systemImage: Category.insights.symbol,
                                       description: Text("Scan again to see what's using your space. Results saved by an older version of DiskSweep don't include insights."))
            }
        }
    }

    private func content(_ report: StorageReport) -> some View {
        let findings = report.findings.filter { finding in
            finding.paths.isEmpty || finding.paths.contains { FileManager.default.fileExists(atPath: $0) }
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SummaryCard(report: report)
                if let message = model.insightsMessage {
                    Label(message, systemImage: "doc.on.clipboard")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                }
                if !report.wholeDisk {
                    Label("This scan covered \(Fmt.path(model.result?.root ?? "")) only. Scan the Entire Disk to see apps, system files and space macOS manages.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                AreasCard(report: report)
                if !report.growth.isEmpty { GrowthCard(report: report) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("What DiskSweep found").font(.headline)
                    ForEach(findings) { FindingCard(finding: $0) }
                }
            }
            .padding(20)
        }
    }
}

private struct SummaryCard: View {
    let report: StorageReport

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 34))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 10) {
                Text(report.summary.first ?? "").font(.title3.bold())
                Text(report.summary.dropFirst().joined(separator: " "))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FreeSpaceBar(report: report)
            }
        }
        .padding(18)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.25)))
    }
}

/// Used, purgeable and free space side by side.
private struct FreeSpaceBar: View {
    let report: StorageReport

    var body: some View {
        let total = max(Double(report.capacity), 1)
        let used = Double(max(report.capacity - report.freeUsable, 0))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(.linearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * used / total)
                    Rectangle().fill(.orange.opacity(0.7))
                        .frame(width: geo.size.width * Double(report.purgeable) / total)
                    Rectangle().fill(.quaternary)
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                legend(.purple, "Used", report.capacity - report.freeUsable)
                if report.purgeable > 0 { legend(.orange, "Purgeable", report.purgeable) }
                legend(.secondary, "Free", report.freeNow)
                Spacer()
                Text("of \(Fmt.bytes(report.capacity))").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private func legend(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(Fmt.bytes(max(bytes, 0)))").monospacedDigit()
        }
    }
}

private struct AreasCard: View {
    let report: StorageReport

    var body: some View {
        let largest = max(report.areas.first?.size ?? 1, 1)
        VStack(alignment: .leading, spacing: 10) {
            Text("Where your space goes").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(report.areas.prefix(14).enumerated()), id: \.element.id) { index, area in
                    HStack(spacing: 10) {
                        Image(systemName: area.symbol).frame(width: 22).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(area.name)
                            Text(area.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 300, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(.tint.opacity(0.55))
                                .frame(width: max(geo.size.width * Double(area.size) / Double(largest), 3))
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 8)
                        Text(Fmt.bytes(area.size))
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(index.isMultiple(of: 2) ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear))
                }
            }
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct GrowthCard: View {
    @EnvironmentObject var model: AppModel
    let report: StorageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What changed since your last scan\(report.previousScan.map { " (\($0.formatted(date: .abbreviated, time: .shortened)))" } ?? "")")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.growth) { growth in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Fmt.path(growth.path)).lineLimit(1).truncationMode(.middle)
                            Text(growth.reason.map { "\(Fmt.bytes(growth.before)) → \(Fmt.bytes(growth.after)) · \($0)" }
                                 ?? "\(Fmt.bytes(growth.before)) → \(Fmt.bytes(growth.after))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("+\(Fmt.bytes(growth.delta))").bold().monospacedDigit().foregroundStyle(.orange)
                        Button("Show") { model.reveal([growth.path]) }
                    }
                }
            }
            .padding(14)
            .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.2)))
        }
    }
}

private struct FindingCard: View {
    @EnvironmentObject var model: AppModel
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: finding.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(finding.title).font(.headline)
                    SafetyBadge(safety: finding.safety)
                    if let verdict = finding.verdict {
                        Label("AI · \(Int((verdict.confidence * 100).rounded()))% sure", systemImage: "brain")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.purple)
                            .background(.purple.opacity(0.15), in: Capsule())
                            .help("DiskSweep's own AI model, which runs on your Mac, recognised this from its name and location.")
                    }
                    Spacer()
                    if finding.reclaimable > 0 {
                        Text("Could free \(Fmt.bytes(finding.reclaimable))")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.green)
                    } else if finding.size > 0 {
                        Text(Fmt.bytes(finding.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(finding.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !finding.buttons.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(finding.buttons, id: \.self) { button in
                            Button(button.label) { model.perform(button.action, for: finding) }
                                .disabled(isDisabled(button.action))
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func isDisabled(_ action: Finding.Action) -> Bool {
        if case let .trash(paths) = action { return paths.isEmpty || model.isTrashing }
        return false
    }
}

/// Smart Care teaser: the first lines of the insights summary with a link to the page.
struct InsightsTeaser: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let report = model.result?.insights {
            Button {
                model.navigate(to: .insights)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: Category.insights.symbol).font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Storage Insights").font(.headline)
                        Text(report.summary.prefix(2).joined(separator: " "))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }
}
