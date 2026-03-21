//
//  ChatSearchBar.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI

struct ChatSearchBar: View {
    @ObservedObject var searchViewModel: ChatSearchViewModel
    @FocusState private var isTextFieldFocused: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            // Search Icon
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.secondaryText)

            // Search TextField
            TextField("Search in conversation...", text: $searchViewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isTextFieldFocused)
                .onSubmit {
                    searchViewModel.nextMatch()
                }

            // Match Count
            if !searchViewModel.searchQuery.isEmpty {
                Text(matchCountLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(searchViewModel.totalMatchCount > 0 ? theme.secondaryText : theme.errorColor.opacity(0.8))
                    .fixedSize()
            }

            // Navigation Buttons
            if searchViewModel.totalMatchCount > 0 {
                HStack(spacing: 2) {
                    Button(action: { searchViewModel.previousMatch() }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)

                    Button(action: { searchViewModel.nextMatch() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(theme.secondaryText)
                }
            }

            // Close Button
            Button(action: { searchViewModel.dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(theme.surfaceOverlay)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.controlBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.dividerColor.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
        .padding(.horizontal, 16)
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private var matchCountLabel: String {
        if searchViewModel.totalMatchCount == 0 {
            return "No results"
        }
        return "\(searchViewModel.currentMatchIndex + 1) of \(searchViewModel.totalMatchCount)"
    }
}
