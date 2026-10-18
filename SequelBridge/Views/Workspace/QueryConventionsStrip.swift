//
//  QueryConventionsStrip.swift
//  SequelBridge
//
//  The collapsible note above the SQL editor: how queries are written here (see
//  QueryConventions). Collapsed it is the one-line summary; clicking the line, or
//  its chevron, expands the explanation. The state is remembered across launches.
//

import SwiftUI

struct QueryConventionsStrip: View {
    let conventions: QueryConventions
    @AppStorage("queryConventionsExpanded") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundColor(.secondary).frame(width: 10)
                    Image(systemName: "server.rack").foregroundColor(.secondary).font(.caption)
                    Text(conventions.summary)
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Query conventions")
            .accessibilityValue(expanded ? "expanded" : "collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(conventions.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").font(.caption).foregroundColor(.secondary.opacity(0.6))
                            Text(line)
                                .font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .overlay(Divider(), alignment: .bottom)
    }
}
