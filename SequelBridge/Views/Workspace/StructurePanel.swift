//  StructurePanel.swift — Editable table structure (Sequel Ace style)

import SwiftUI
import AppKit

// MARK: - NSScrollView wrapper (definitive top-left anchor, no SwiftUI centering)
//
// SwiftUI ScrollView([.horizontal, .vertical]) centers content shorter than the
// container — no pure-SwiftUI fix exists. NSScrollView never centers content.
//
// Architecture:
//  NSScrollView
//    └─ FlippedClipView  (NSClipView subclass, isFlipped=true → y=0 at TOP)
//         └─ NSHostingView  (SwiftUI content, frame = fittingSize, at origin)
//
// FlippedClipView is used instead of FlippedContainerView because NSClipView.isFlipped
// can be overridden (it's a computed var on NSView). NSHostingView.isFlipped cannot
// be overridden in this SDK version — that caused the previous build failure.

private struct AppKitScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content
    var minContentWidth: CGFloat = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers    = true
        scroll.borderType            = .noBorder

        // Flipped clip view: y=0 is the TOP of the scroll area.
        // The document (NSHostingView) placed at origin appears at top-left.
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip

        let host = NSHostingView(rootView: content())
        let sz = host.fittingSize
        host.frame = CGRect(x: 0, y: 0,
                            width:  max(sz.width,  minContentWidth),
                            height: max(sz.height, 1))
        scroll.documentView = host
        context.coordinator.host     = host
        context.coordinator.minWidth = minContentWidth
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let host = scrollView.documentView as? NSHostingView<Content> else { return }
        host.rootView = content()
        // Resize frame to match updated content (column added/removed, filter changed, etc.)
        DispatchQueue.main.async {
            let sz = host.fittingSize
            let w  = max(sz.width, context.coordinator.minWidth)
            let h  = max(sz.height, 1)
            if abs(host.frame.width - w) > 1 || abs(host.frame.height - h) > 1 {
                host.setFrameSize(NSSize(width: w, height: h))
            }
        }
    }

    func makeCoordinator() -> AppKitScrollCoordinator { AppKitScrollCoordinator() }
}

// Deliberately NOT nested inside the generic AppKitScrollView<Content>: a Coordinator
// nested in a generic type has a generic deinit, and the -O SIL optimizer crashed
// generating it when targeting macOS 14/15. A standalone, non-generic class avoids that.
// `host` is only retained (never read), so a plain NSView suffices.
final class AppKitScrollCoordinator {
    var host: NSView?
    var minWidth: CGFloat = 0
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Editable column model

nonisolated struct ColumnEdit: Identifiable {
    var id = UUID()
    var originalName: String?   // nil = new column
    var name: String
    var baseType: String        // VARCHAR, INT, etc.
    var length: String          // "255" or ""
    var unsigned: Bool
    var nullable: Bool
    var keyType: String         // "PRI", "UNI", "MUL", ""
    var defaultValue: String
    var extra: String
    var encoding: String
    var collation: String
    var comment: String

    var isNew: Bool { originalName == nil }

    var fullType: String {
        var t = baseType.uppercased()
        if !length.isEmpty { t += "(\(length))" }
        if unsigned { t += " UNSIGNED" }
        return t
    }

    init(from col: ColumnInfo) {
        originalName = col.name
        name         = col.name
        nullable     = col.nullable
        keyType      = col.keyType
        defaultValue = col.defaultValue
        extra        = col.extra
        encoding     = col.encoding
        collation    = col.collation
        comment      = col.comment
        unsigned     = col.dataType.lowercased().contains("unsigned")
        let (b, l)   = Self.parse(col.dataType)
        baseType = b; length = l
    }

    init() {
        originalName = nil
        name = "new_column"; baseType = "VARCHAR"; length = "255"
        unsigned = false; nullable = true; keyType = ""; defaultValue = ""
        extra = ""; encoding = ""; collation = ""; comment = ""
    }

    static func parse(_ type: String) -> (base: String, length: String) {
        let clean = type
            .replacingOccurrences(of: " unsigned", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        if let p = clean.range(of: "("), let q = clean.range(of: ")") {
            return (String(clean[..<p.lowerBound]).uppercased(),
                    String(clean[clean.index(after: p.lowerBound)..<q.lowerBound]))
        }
        return (clean.uppercased(), "")
    }

    func hasChanges(from col: ColumnInfo) -> Bool {
        guard let orig = originalName else { return true }
        return name != orig ||
               fullType.lowercased() != col.dataType.lowercased() ||
               nullable != col.nullable || keyType != col.keyType ||
               defaultValue != col.defaultValue || extra != col.extra ||
               encoding != col.encoding || collation != col.collation ||
               comment != col.comment
    }
}

// MARK: - Editable index model

nonisolated struct IndexEdit: Identifiable {
    var id = UUID()
    var originalName: String?
    var name: String
    var indexType: String       // "PRIMARY KEY", "UNIQUE", "INDEX"
    var columns: [String]
    var isNew: Bool { originalName == nil }
}

// MARK: - Structure panel

struct StructurePanel: View {
    let table: TableInfo
    let conn: Connection
    @ObservedObject var session: WorkspaceSession
    @EnvironmentObject private var manager: ConnectionManager

    @State private var columnEdits: [ColumnEdit] = []
    @State private var deletedColumnNames: Set<String> = []
    @State private var indexEdits: [IndexEdit] = []
    @State private var deletedIndexNames: Set<String> = []
    @State private var originalColumns: [ColumnInfo] = []
    @State private var originalIndexes: [IndexInfo] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var selectedColId: UUID? = nil
    @State private var selectedIdxId: UUID? = nil
    @State private var showAddIndexSheet = false
    @State private var columnFilter: String = ""    // Sequel Ace-style column search
    /// Share of the panel height the columns pane owns; the divider drags it.
    @State private var splitFraction: CGFloat = 0.62

    private var filteredEdits: [ColumnEdit] {
        let visible = columnEdits.filter { !deletedColumnNames.contains($0.originalName ?? "") }
        guard !columnFilter.isEmpty else { return visible }
        return visible.filter { $0.name.localizedCaseInsensitiveContains(columnFilter) }
    }

    // Column widths for the structure grid
    private let wIcon:    CGFloat = 36
    private let wName:    CGFloat = 140
    private let wType:    CGFloat = 100
    private let wLen:     CGFloat = 54
    private let wNull:    CGFloat = 40
    private let wKey:     CGFloat = 80
    private let wDef:     CGFloat = 140
    private let wExtra:   CGFloat = 130
    private let wComment: CGFloat = 160
    private var colWidth: CGFloat { wIcon+wName+wType+wLen+wNull+wKey+wDef+wExtra+wComment }

    private var hasChanges: Bool {
        !deletedColumnNames.isEmpty || !deletedIndexNames.isEmpty ||
        columnEdits.contains(where: { e in
            e.isNew ? true :
            originalColumns.first(where: { $0.name == e.originalName }).map { e.hasChanges(from: $0) } ?? false
        }) ||
        indexEdits.contains(where: { $0.isNew })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading && columnEdits.isEmpty {
                ProgressView("Loading structure…").padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A manual split instead of VSplitView: VSplitView hands the whole
                // height to the first flexible pane and ignores idealHeight, which
                // left the indexes as a sliver pinned to the bottom. Here the top
                // pane owns a fraction of the height, the divider drags to retune
                // it, and both panes always get real space.
                GeometryReader { outer in
                    VStack(alignment: .leading, spacing: 0) {
                        // ── COLUMNS (top pane) ──────────────────────────────
                        VStack(alignment: .leading, spacing: 0) {
                            columnSectionHeader
                            Divider()
                            GeometryReader { geo in
                                ScrollView([.horizontal, .vertical]) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        columnTableHeader
                                            .background(Color(NSColor.controlBackgroundColor))
                                        Divider()
                                        ForEach(Array(filteredEdits.enumerated()), id: \.element.id) { idx, edit in
                                            columnRow(edit, rowIdx: idx)
                                        }
                                        if filteredEdits.isEmpty && !columnFilter.isEmpty {
                                            Text("No columns match \"\(columnFilter)\"")
                                                .font(.caption).foregroundColor(.secondary)
                                                .padding(12)
                                        }
                                    }
                                    .frame(
                                        minWidth:  max(colWidth, geo.size.width),
                                        minHeight: geo.size.height,
                                        alignment: .topLeading
                                    )
                                }
                            }
                        }
                        .frame(height: max(120, outer.size.height * splitFraction))

                        // ── DIVIDER (draggable) ─────────────────────────────
                        // The grab zone is real layout space, not an overlay: an
                        // overlay wider than its parent is culled from hit-testing,
                        // which left only the hairline itself clickable.
                        ZStack {
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 9)
                        .contentShape(Rectangle())
                        .gesture(
                            // Location-based, in the container's space: the handle
                            // moves while it is being dragged, so translation-based
                            // math feeds back on itself and undershoots. The pointer's
                            // absolute position is immune to the handle moving.
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("structureSplit"))
                                .onChanged { drag in
                                    let h = outer.size.height
                                    guard h > 0 else { return }
                                    splitFraction = min(0.85, max(0.25, drag.location.y / h))
                                }
                        )
                        .onHover { inside in
                            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                        }

                        // ── INDEXES (bottom pane) ───────────────────────────
                        // alignment matters: an unconstrained frame centers its
                        // content, which floated the index list away from the
                        // divider and left dead space between them.
                        indexesSection
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .coordinateSpace(name: "structureSplit")
                }
            }

            if let err = saveError {
                HStack {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(err).font(.caption).foregroundColor(.red)
                    Spacer()
                    Button("Dismiss") { saveError = nil }.font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
                .overlay(Divider(), alignment: .top)
            }

            if hasChanges { saveBar }
        }
        .task(id: table.id) { await loadAll() }
    }

    // MARK: - Column section header + filter bar (Sequel Ace style)

    private var columnSectionHeader: some View {
        VStack(spacing: 0) {
            // Toolbar row
            HStack(spacing: 6) {
                Text("COLUMNS")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("\(filteredEdits.count) of \(columnEdits.filter { !deletedColumnNames.contains($0.originalName ?? "") }.count)")
                    .font(.caption2).foregroundColor(.secondary)
                Button {
                    if let id = selectedColId, let edit = columnEdits.first(where: { $0.id == id }) {
                        if let orig = edit.originalName { deletedColumnNames.insert(orig) }
                        columnEdits.removeAll { $0.id == id }
                        selectedColId = nil
                    }
                } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                .buttonStyle(.bordered).controlSize(.mini).disabled(selectedColId == nil)
                Button {
                    let newEdit = ColumnEdit()
                    columnEdits.append(newEdit)
                    selectedColId = newEdit.id
                } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                .buttonStyle(.borderedProminent).controlSize(.mini)
                .help("Add a column")
                .accessibilityIdentifier("structure.addColumn")
                Button { Task { await loadAll() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered).controlSize(.mini)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh the structure (⌘R)")
                .accessibilityIdentifier("structure.refresh")
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Filter bar — same as Sequel Ace's column search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary).font(.caption)
                TextField("Filter columns…", text: $columnFilter)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !columnFilter.isEmpty {
                    Button { columnFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    private var columnTableHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: wIcon + 8, height: 1)
            hdrCell("Field",   wName)
            hdrCell("Type",    wType)
            hdrCell("Length",  wLen)
            hdrCell("Null",    wNull)
            hdrCell("Key",     wKey)
            hdrCell("Default", wDef)
            hdrCell("Extra",   wExtra)
            hdrCell("Comment", wComment)
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func columnRow(_ edit: ColumnEdit, rowIdx: Int) -> some View {
        let isSelected = selectedColId == edit.id
        let binding    = bindingFor(edit)
        // Alternating background replaces per-row dividers — much cleaner visually
        let rowBg: Color = isSelected
            ? Color.accentColor.opacity(0.10)
            : rowIdx % 2 == 0 ? Color.clear
                               : Color(NSColor.alternatingContentBackgroundColors[1]).opacity(0.5)
        return HStack(spacing: 0) {
            // Key icon (always visible, compact)
            keyIcon(edit.keyType)
                .frame(width: wIcon, alignment: .center)
                .padding(.leading, 8)

            // Field name — always editable
            TextField("", text: binding.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: edit.keyType == "PRI" ? .semibold : .regular))
                .frame(width: wName - 4).padding(.horizontal, 2)
                .accessibilityIdentifier("structure.name.\(edit.name)")

            // Type — compact monospaced text, menu on tap
            if isSelected {
                Menu(binding.baseType.wrappedValue.isEmpty ? "TYPE" : binding.baseType.wrappedValue) {
                    ForEach(MySQLTypes.all, id: \.self) { t in
                        Button(t) { binding.baseType.wrappedValue = t }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(Theme.mono(11))
                .frame(width: wType - 4)
            } else {
                Text(binding.baseType.wrappedValue)
                    .font(Theme.mono(11)).foregroundColor(.primary)
                    .frame(width: wType - 4, alignment: .leading).padding(.horizontal, 2)
            }

            // Length — editable when selected; otherwise one line, the whole value in a tooltip
            // (a line-limited field sat below its row).
            if isSelected {
                TextField("", text: binding.length)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(10)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: wLen - 4)
                    .accessibilityIdentifier("structure.length.\(edit.name)")
            } else {
                Text(binding.length.wrappedValue)
                    .font(Theme.mono(10)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: wLen - 4)
                    .help(binding.length.wrappedValue)
                    .accessibilityIdentifier("structure.length.\(edit.name)")
            }

            // Null — checkbox always shown
            Toggle("", isOn: binding.nullable)
                .labelsHidden().toggleStyle(.checkbox)
                .frame(width: wNull, alignment: .center)

            // Key — badge when set, menu when selected
            if isSelected {
                Menu(keyLabel(edit.keyType)) {
                    Button("—")           { binding.keyType.wrappedValue = "" }
                    Button("PRIMARY KEY") { binding.keyType.wrappedValue = "PRI" }
                    Button("UNIQUE")      { binding.keyType.wrappedValue = "UNI" }
                    Button("INDEX")       { binding.keyType.wrappedValue = "MUL" }
                }
                .menuStyle(.borderlessButton).font(.system(size: 10))
                .frame(width: wKey - 4)
            } else {
                keyBadge(edit.keyType).frame(width: wKey - 4, alignment: .leading)
            }

            // Default — editable when selected, plain text otherwise
            if isSelected {
                TextField("", text: binding.defaultValue)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(10))
                    .frame(width: wDef - 4).padding(.horizontal, 2)
            } else {
                Text(binding.defaultValue.wrappedValue.isEmpty ? "" : binding.defaultValue.wrappedValue)
                    .font(Theme.mono(10)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: wDef - 4, alignment: .leading).padding(.horizontal, 2)
                    .help(binding.defaultValue.wrappedValue)
                    .accessibilityIdentifier("structure.default.\(edit.name)")
            }

            // Extra — only show menu when selected; hide "—" clutter
            if isSelected {
                Menu(binding.extra.wrappedValue.isEmpty ? "—" : binding.extra.wrappedValue) {
                    Button("—")                           { binding.extra.wrappedValue = "" }
                    Button("auto_increment")              { binding.extra.wrappedValue = "auto_increment" }
                    Button("on update CURRENT_TIMESTAMP") { binding.extra.wrappedValue = "on update CURRENT_TIMESTAMP" }
                }
                .menuStyle(.borderlessButton).font(.system(size: 10))
                .frame(width: wExtra - 4)
            } else {
                Text(binding.extra.wrappedValue)
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: wExtra - 4, alignment: .leading).padding(.horizontal, 2)
                    .help(binding.extra.wrappedValue)
            }

            // Comment — only show content, no placeholder clutter
            TextField("", text: binding.comment)
                .textFieldStyle(.plain).font(.system(size: 10)).foregroundColor(.secondary)
                .frame(width: wComment - 4).padding(.horizontal, 2)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(rowBg)
        .contentShape(Rectangle())
        .onTapGesture { selectedColId = edit.id }
    }

    // MARK: - Indexes section

    private var indexesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("INDEXES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(Plural.count(indexEdits.filter { !deletedIndexNames.contains($0.originalName ?? "") }.count, "index", "indexes"))
                    .font(.caption2).foregroundColor(.secondary)
                Button {
                    if let id = selectedIdxId,
                       let edit = indexEdits.first(where: { $0.id == id }) {
                        if let orig = edit.originalName { deletedIndexNames.insert(orig) }
                        indexEdits.removeAll { $0.id == id }
                        selectedIdxId = nil
                    }
                } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .disabled(selectedIdxId == nil)
                Button { showAddIndexSheet = true } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .buttonStyle(.borderedProminent).controlSize(.mini)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Index header
            HStack(spacing: 0) {
                hdrCell("Name",    160)
                hdrCell("Type",     90)
                hdrCell("Columns", 200)
                hdrCell("Unique",   50)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            let visible = indexEdits.filter { !deletedIndexNames.contains($0.originalName ?? "") }
            if visible.isEmpty {
                Text("No indexes defined")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                ForEach(visible) { idx in
                    indexRow(idx)
                    Divider().padding(.leading, 12)
                }
            }
        }
        .sheet(isPresented: $showAddIndexSheet) {
            AddIndexSheet(
                columns: columnEdits.filter { !deletedColumnNames.contains($0.originalName ?? "") }.map(\.name)
            ) { newIdx in
                indexEdits.append(newIdx)
                selectedIdxId = newIdx.id
            }
        }
    }

    private func indexRow(_ idx: IndexEdit) -> some View {
        let isSelected = selectedIdxId == idx.id
        let icon: String = idx.name == "PRIMARY" ? "key.fill" :
                           idx.indexType == "UNIQUE" ? "key" : "link"
        let iconColor: Color = idx.name == "PRIMARY" ? .orange :
                               idx.indexType == "UNIQUE" ? .blue : .secondary
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(iconColor).font(.caption2)
                Text(idx.name).font(.system(size: 12, weight: .medium))
            }.frame(width: 160, alignment: .leading)

            Text(idx.indexType)
                .font(.system(size: 10))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(iconColor.opacity(0.15)).cornerRadius(3)
                .frame(width: 90, alignment: .leading)

            Text(idx.columns.joined(separator: ", "))
                .font(Theme.mono(11))
                .foregroundColor(.secondary)
                .frame(width: 200, alignment: .leading)

            Image(systemName: idx.indexType != "INDEX" ? "checkmark" : "")
                .font(.caption2).foregroundColor(.secondary)
                .frame(width: 50, alignment: .center)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedIdxId = idx.id }
    }

    // MARK: - Save bar

    private var saveBar: some View {
        HStack(spacing: 12) {
            if isSaving {
                ProgressView().scaleEffect(0.7)
                Text("Applying changes…").font(.caption).foregroundColor(.secondary)
            } else {
                Text("You have unsaved structure changes")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Revert") { revert() }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isSaving)
            Button("Save Changes") { Task { await saveChanges() } }
                .accessibilityIdentifier("structure.save")
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(isSaving)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Helpers

    private func keyIcon(_ keyType: String) -> some View {
        Group {
            switch keyType.uppercased() {
            case "PRI": Image(systemName: "key.fill").foregroundColor(.orange).font(.caption2)
            case "UNI": Image(systemName: "key").foregroundColor(.blue).font(.caption2)
            case "MUL": Image(systemName: "link").foregroundColor(.secondary).font(.caption2)
            default:    Image(systemName: "circle.dotted").foregroundColor(.secondary.opacity(0.4)).font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func keyBadge(_ k: String) -> some View {
        switch k.uppercased() {
        case "PRI":
            Text("PRI").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.orange).cornerRadius(3)
        case "UNI":
            Text("UNI").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.blue).cornerRadius(3)
        case "MUL":
            Text("IDX").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.gray).cornerRadius(3)
        default:
            EmptyView()
        }
    }

    private func keyLabel(_ k: String) -> String {
        switch k.uppercased() {
        case "PRI": return "PRI"
        case "UNI": return "UNI"
        case "MUL": return "IDX"
        default:    return "—"
        }
    }

    private func hdrCell(_ label: String, _ width: CGFloat) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: width, alignment: .leading)
    }

    // Binding helper for mutating ColumnEdit in the array
    private func bindingFor(_ edit: ColumnEdit) -> (
        name: Binding<String>, baseType: Binding<String>, length: Binding<String>,
        nullable: Binding<Bool>, keyType: Binding<String>, defaultValue: Binding<String>,
        extra: Binding<String>, comment: Binding<String>
    ) {
        let idx = columnEdits.firstIndex(where: { $0.id == edit.id }) ?? 0
        return (
            name:         Binding(get: { columnEdits[idx].name },         set: { columnEdits[idx].name = $0 }),
            baseType:     Binding(get: { columnEdits[idx].baseType },     set: { columnEdits[idx].baseType = $0 }),
            length:       Binding(get: { columnEdits[idx].length },       set: { columnEdits[idx].length = $0 }),
            nullable:     Binding(get: { columnEdits[idx].nullable },     set: { columnEdits[idx].nullable = $0 }),
            keyType:      Binding(get: { columnEdits[idx].keyType },      set: { columnEdits[idx].keyType = $0 }),
            defaultValue: Binding(get: { columnEdits[idx].defaultValue }, set: { columnEdits[idx].defaultValue = $0 }),
            extra:        Binding(get: { columnEdits[idx].extra },        set: { columnEdits[idx].extra = $0 }),
            comment:      Binding(get: { columnEdits[idx].comment },      set: { columnEdits[idx].comment = $0 })
        )
    }

    // MARK: - Data loading

    private func loadAll() async {
        isLoading = true
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        guard !db.isEmpty else { isLoading = false; return }

        if let cols = try? await manager.queryEngine.fetchColumns(alias: conn.alias, database: db, table: table.name) {
            originalColumns = cols
            columnEdits = cols.map { ColumnEdit(from: $0) }
            if let i = session.sidebarTrees[conn.alias]?.firstIndex(where: { $0.id == table.id }) {
                session.sidebarTrees[conn.alias]?[i].columns = cols
            }
        }

        // fetchIndexes now uses SHOW INDEX via mysql_query() — returns ALL MySQL indexes
        // (PRIMARY, UNIQUE, regular, FULLTEXT) reliably without depending on duckdb_constraints().
        var allIdxs = (try? await manager.queryEngine.fetchIndexes(
            alias: conn.alias, database: db, table: table.name)) ?? []
        // Fallback: if SHOW INDEX returned nothing, derive PRIMARY KEY from column keyType
        if allIdxs.isEmpty {
            let pkCols = columnEdits.filter { $0.keyType.uppercased() == "PRI" }.map(\.name)
            if !pkCols.isEmpty {
                allIdxs = [IndexInfo(id: "\(table.name).PRIMARY", name: "PRIMARY",
                                     columns: pkCols, unique: true, indexType: "BTREE")]
            }
        }

        originalIndexes = allIdxs
        indexEdits = allIdxs.map { IndexEdit(id: UUID(), originalName: $0.name, name: $0.name,
                                              indexType: $0.name == "PRIMARY" ? "PRIMARY KEY" :
                                                         ($0.unique ? "UNIQUE" : "INDEX"),
                                              columns: $0.columns) }
        if let i = session.sidebarTrees[conn.alias]?.firstIndex(where: { $0.id == table.id }) {
            session.sidebarTrees[conn.alias]?[i].indexes = allIdxs
        }

        deletedColumnNames = []
        deletedIndexNames  = []
        isLoading = false
    }

    private func revert() {
        columnEdits        = originalColumns.map { ColumnEdit(from: $0) }
        deletedColumnNames = []
        indexEdits         = originalIndexes.map {
            IndexEdit(id: UUID(), originalName: $0.name, name: $0.name,
                      indexType: $0.name == "PRIMARY" ? "PRIMARY KEY" : ($0.unique ? "UNIQUE" : "INDEX"),
                      columns: $0.columns)
        }
        deletedIndexNames  = []
        saveError          = nil
    }

    private func saveChanges() async {
        isSaving = true
        saveError = nil
        let db = session.selectedDatabase[conn.alias] ?? conn.database
        // MySQL DDL: built in MySQL's dialect and passed through to the server.
        // DuckDB can parse none of it, so it must not go through query().
        let stmts: [String]
        switch conn.engine {
        case .clickhouse:
            // ClickHouse schema changes are ALTER TABLE mutations with their own
            // semantics (async, engine-dependent). Typing them in the query tab is
            // the honest interface until a dedicated flow exists.
            saveError = "Editing ClickHouse structure isn't supported yet — run ALTER TABLE from the Query tab."
            isSaving = false
            return
        case .sqlite:
            // SQLite cannot change a column's type, nullability or default at all —
            // the documented workaround is to rebuild the table and copy the data.
            // Generating an ALTER here would only produce a confusing server error.
            saveError = "SQLite does not support altering columns. Recreating the table is the only way to change its structure."
            isSaving = false
            return
        case .mysql:
            let generated = SQLBuilder.generatedColumnEdits(columnEdits, originals: originalColumns)
            guard generated.isEmpty else {
                saveError = "\(generated.joined(separator: ", ")) is a generated column: its expression isn't shown here, "
                    + "so a change would lose it. Change it with ALTER TABLE … MODIFY … AS (…) in the Query tab."
                isSaving = false
                return
            }
            stmts = SQLBuilder.alterStatements(
                database: db, table: table.name,
                columnEdits: columnEdits, originalColumns: originalColumns,
                deletedColumnNames: deletedColumnNames,
                indexEdits: indexEdits, deletedIndexNames: deletedIndexNames
            )
        case .postgres:
            stmts = SQLBuilder.pgAlterStatements(
                schema: db, table: table.name,
                columnEdits: columnEdits, originalColumns: originalColumns,
                deletedColumnNames: deletedColumnNames,
                indexEdits: indexEdits, deletedIndexNames: deletedIndexNames
            )
        }
        do {
            for sql in stmts {
                try await manager.queryEngine.executeDDL(alias: conn.alias, sql: sql)
            }
            // Reload after save
            await loadAll()
        } catch {
            if !QueryEngine.isCancellation(error) { saveError = QueryEngine.extractReason(from: error) }
        }
        isSaving = false
    }

    // SQL generation lives in SQLBuilder.alterStatements — see SQLBuilder.swift.
}

// MARK: - MySQL type list

private enum MySQLTypes {
    static let all: [String] = [
        "VARCHAR","CHAR","TEXT","MEDIUMTEXT","LONGTEXT","TINYTEXT",
        "INT","TINYINT","SMALLINT","MEDIUMINT","BIGINT",
        "FLOAT","DOUBLE","DECIMAL","NUMERIC",
        "DATE","DATETIME","TIMESTAMP","TIME","YEAR",
        "BLOB","MEDIUMBLOB","LONGBLOB","TINYBLOB","BINARY","VARBINARY",
        "BOOLEAN","BIT","ENUM","SET","JSON","GEOMETRY",
    ]
}

// MARK: - Add Index sheet

private struct AddIndexSheet: View {
    let columns: [String]
    let onAdd: (IndexEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var indexName = ""
    @State private var indexType = "INDEX"
    @State private var selectedCols: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Index").font(.title2).bold()
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.title3)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Index Name").font(.caption).foregroundColor(.secondary)
                    TextField("e.g. idx_column", text: $indexName).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Index Type").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $indexType) {
                        Text("INDEX").tag("INDEX")
                        Text("UNIQUE").tag("UNIQUE")
                        Text("PRIMARY KEY").tag("PRIMARY KEY")
                    }.pickerStyle(.segmented).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Columns").font(.caption).foregroundColor(.secondary)
                    VStack(spacing: 2) {
                        ForEach(columns, id: \.self) { col in
                            let on = selectedCols.contains(col)
                            Button {
                                if on { selectedCols.removeAll { $0 == col } }
                                else  { selectedCols.append(col) }
                            } label: {
                                HStack {
                                    Image(systemName: on ? "checkmark.square.fill" : "square")
                                        .foregroundColor(on ? .accentColor : .secondary)
                                    Text(col).font(Theme.mono(12))
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8).background(Color(NSColor.textBackgroundColor)).cornerRadius(6)
                }
            }
            .padding(20)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Index") {
                    let name = indexType == "PRIMARY KEY" ? "PRIMARY" :
                               indexName.isEmpty ? "idx_\(selectedCols.joined(separator: "_"))" : indexName
                    onAdd(IndexEdit(id: UUID(), originalName: nil, name: name,
                                    indexType: indexType, columns: selectedCols))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedCols.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 380)
    }
}
