//  PanelHelpers.swift — Shared helpers for feature panels

import SwiftUI

/// Every feature panel opens with this header. `tint` is the connection's color —
/// the thread that says which server the panel is touching.
func panelHeader(icon: String, title: String, subtitle: String, tint: Color = .accentColor) -> some View {
    HStack(spacing: Theme.space3) {
        Image(systemName: icon)
            .foregroundColor(tint)
            .frame(width: 20)
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle).font(Theme.fontCaption).foregroundColor(.secondary)
        }
        Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Theme.surface)
}

func emptyState(icon: String, message: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 36)).foregroundColor(.secondary.opacity(0.3))
        Text(message).foregroundColor(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
}
