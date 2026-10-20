//
//  Theme.swift
//  SequelBridge
//
//  The design tokens every view draws from. One idea runs through the app: the
//  connection's color is the thread that tells you which server you are touching,
//  and everything else stays quiet, native macOS.
//
//  Spacing, radii and type come in fixed steps — a view picks a step, never a
//  bare number, so screens stay consistent without coordination.
//

import SwiftUI
import AppKit

enum Theme {

    // MARK: - Monospaced face
    //
    // Menlo — the same font Sequel Ace ships and uses — reads warmer and more openly
    // than the system SF Mono (`monospacedSystemFont`), which is tighter and more
    // geometric. Menlo is a standard macOS font, so it resolves by name everywhere;
    // if a future macOS ever dropped it, both helpers fall back to the system
    // monospaced face automatically. Every data cell, the SQL editor and all code
    // snippets go through these two helpers, so the face is set in one place.

    static let monoFamily = "Menlo"

    /// SwiftUI monospaced font (labels, code snippets, panels).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(monoFamily, size: size).weight(weight)
    }

    /// AppKit monospaced font (the SQL editor and code/DDL views).
    static func monoNSFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont(name: monoFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        guard weight != .regular else { return base }
        if weight.rawValue >= NSFont.Weight.semibold.rawValue {
            return NSFont(name: "\(monoFamily)-Bold", size: size)
                ?? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
        return base
    }

    // MARK: - Data face
    //
    // The results/content grid uses the SYSTEM (proportional) font, like Sequel Ace —
    // its content grid is `.SFNS-Regular` 13pt, not a monospaced face. A proportional
    // font reads cleaner and more native for a table of values than a code font.
    // `monospacedDigitSystemFont` keeps letters proportional but makes DIGITS tabular,
    // so number columns still line up — the one refinement over Sequel Ace's plain
    // proportional figures.

    /// AppKit font for grid cells and the values the user reads.
    static func dataNSFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
    /// Point size for grid data — matches Sequel Ace's 13pt content font.
    static let dataFontSize: CGFloat = 13

    // MARK: - Spacing (pt)

    /// Hairline gaps inside a cell.
    static let space1: CGFloat = 2
    /// Between glyph and label.
    static let space2: CGFloat = 4
    /// Between controls in a row.
    static let space3: CGFloat = 8
    /// Between groups.
    static let space4: CGFloat = 12
    /// Panel padding.
    static let space5: CGFloat = 16
    /// Section padding.
    static let space6: CGFloat = 20

    // MARK: - Radii

    /// Small controls: badges, chips, inline fields.
    static let radiusControl: CGFloat = 4
    /// Cards and sheets.
    static let radiusCard: CGFloat = 8
    /// The data grid is square — rounding rows of data is decoration.
    static let radiusGrid: CGFloat = 0

    // MARK: - Type scale
    //
    // Five steps replace the ad-hoc 8–13pt sizes that grew per view.
    // Data cells and SQL use monospaced; chrome uses the system face.

    /// 13pt — body copy, sheet fields.
    static let fontBody = Font.system(size: 13)
    /// 13pt system, tabular digits — data cells (proportional, like Sequel Ace).
    static let fontData = Font.system(size: dataFontSize).monospacedDigit()
    /// 11pt — chrome: buttons, panel rows, sidebar entries.
    static let fontChrome = Font.system(size: 11)
    /// 11pt semibold — emphasized chrome: column names, row counts.
    static let fontChromeStrong = Font.system(size: 11, weight: .semibold)
    /// 10pt — captions and hints.
    static let fontCaption = Font.system(size: 10)
    /// 10pt — micro labels: column types under names, badges. Small, still legible.
    static let fontMicro = Font.system(size: 10)

    // MARK: - Grid metrics

    static let rowHeight: CGFloat = 22
    static let headerHeight: CGFloat = 40
    static let cellPaddingH: CGFloat = 10
    /// Grid hairlines — a soft, single-strength line for both axes, quieter than a
    /// full separator so the data reads first and the rules only guide the eye.
    static let gridLine = Color(NSColor.separatorColor).opacity(0.3)

    // MARK: - Semantic colors

    /// Panel and toolbar surfaces.
    static let surface = Color(NSColor.controlBackgroundColor)
    /// The document area behind data.
    static let canvas = Color(NSColor.textBackgroundColor)
    /// Every-other-row tint in the grid, just enough to carry the eye across.
    static let rowStripe = Color.primary.opacity(0.04)
    /// Row under the pointer.
    static let rowHover = Color.primary.opacity(0.05)
    /// Hairlines.
    static let separator = Color(NSColor.separatorColor)

    /// A NULL is the absence of a value; it recedes rather than reads as text.
    static let nullText = Color.secondary.opacity(0.55)
    /// A cell edit that reached the server.
    static let savedFlash = Color.green.opacity(0.18)
    /// A cell edit the server rejected.
    static let errorFlash = Color.red.opacity(0.18)

    // MARK: - Connection color helpers

    /// The connection's color at chrome strength — enough to identify, not shout.
    static func connectionTint(_ color: Color) -> Color { color.opacity(0.16) }
    /// The connection's color as a thin identifying edge.
    static let edgeWidth: CGFloat = 3
}

// MARK: - Engine badge

/// The engine monogram shown beside a connection: which product is on the other
/// end, at a glance, without reading.
struct EngineBadge: View {
    let engine: DatabaseEngine

    private var label: String {
        switch engine {
        case .mysql:    return "My"
        case .postgres: return "Pg"
        case .sqlite:   return "Lite"
        case .clickhouse: return "CH"
        }
    }

    var body: some View {
        Text(label)
            .font(Theme.mono(9, weight: .semibold))
            .lineLimit(1)
            .fixedSize()                     // never squeezed: a long alias beside it truncates instead
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl))
            .help(engine.displayName)
            .accessibilityIdentifier("engine.badge")
    }
}
