//
//  CodeBlockCardView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI

/// A view that acts as a placeholder card for large code blocks in the chat history.
/// It displays a summary of the code and acts as a button to open the full viewer.
struct CodeBlockCardView: View {
    let language: String?
    let lineCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading) {
                    Text(language ?? "Code Snippet")
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Text("\(lineCount) lines of code")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 400) // Give the card a reasonable max width
    }
}

struct CodeBlockCardView_Previews: PreviewProvider {
    static var previews: some View {
        CodeBlockCardView(language: "Swift", lineCount: 152, action: {})
            .padding()
    }
}
