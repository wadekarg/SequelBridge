//
//  ConnectionRowView.swift
//  SequelBridge
//
//  Created by Gajanan.Wadekar on 4/16/26.
//

import SwiftUI

struct ConnectionRowView: View {
    let connection: Connection
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? connection.displayColor : .secondary)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)

            Circle()
                .fill(connection.displayColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(connection.name)
                        .font(.body)
                    if connection.readOnly {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("Read-only (safe mode)")
                    }
                }
                Text("\(connection.host):\(connection.port) / \(connection.database)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .padding(.vertical, 4)
    }
}