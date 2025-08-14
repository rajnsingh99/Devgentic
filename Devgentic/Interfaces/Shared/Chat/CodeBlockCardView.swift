//
//  CodeBlockCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//

import SwiftUI


struct CodeBlockCardView: View {
    let language: String
    let lineCount: Int
    let fileName: String?
    let action: () -> Void

    private var title: String {
        if let fileName = fileName, !fileName.isEmpty {
            return fileName
        }
        if language.isEmpty {
            return "Code Block"
        }
        return "\(language.capitalized) Code"
    }
    
    private var iconName: String {
        if let fileName = fileName, !fileName.isEmpty {
            return "doc.text.fill"
        }
        return "doc.richtext.fill"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: iconName)
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                    .padding(.leading, 5)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(Color(NSColor.labelColor))

                    Text("\(lineCount) lines of code")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Tap to view full code")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding(15)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 300, alignment: .leading)
        .padding(.vertical, 20)
    }
}

// MARK: - Preview Provider
struct CodeBlockCardView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            CodeBlockCardView(language: "swift", lineCount: 78, fileName: "ChatHistoryViewModel.swift") {
                print("File card tapped!")
            }

            CodeBlockCardView(language: "python", lineCount: 150, fileName: nil) {
                print("Language card tapped!")
            }
        }
        .padding()
        .preferredColorScheme(.dark)
        .previewLayout(.sizeThatFits)
    }
}
