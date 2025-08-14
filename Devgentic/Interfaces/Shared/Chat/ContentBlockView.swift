//
//  ContentBlockView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/08/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ContentBlockView")
private let CODE_BLOCK_LINE_LIMIT = 50

// MARK: - FIX: Removed the Identifiable conformance.
// The ID was unstable during streaming because multiple blocks (like horizontal rules)
// could have the same hash value, causing UI glitches and scrolling issues.
// The ForEach loop will now use the array index for a stable identity.
enum ContentBlock: Equatable, Hashable {
    case paragraph(String)
    case code(language: String, content: String, fileName: String?)
    case heading(level: Int, text: String)
    case listItem(prefix: String, text: String, indentation: Int)
    case horizontalRule
    case table(headers: [String], rows: [[String]])
    case image(url: String, altText: String?)
}

struct ContentBlockView: View {
    let block: ContentBlock
    let message: ChatMessage
    
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel

    var body: some View {
        switch block {
        case .paragraph(let text):
            renderTextView(text: text)
                .padding(.bottom, UITheme.Spacing.small)

        case .code(let lang, let codeContent, let fileName):
            if codeContent.components(separatedBy: .newlines).count > CODE_BLOCK_LINE_LIMIT {
                CodeBlockCardView(language: lang, lineCount: codeContent.components(separatedBy: .newlines).count, fileName: fileName) {
                    let snippet = CodeSnippet(language: lang, code: codeContent)
                    chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
                }
            } else {
                CodeBlockView(language: lang, content: codeContent)
                    .padding(.bottom, UITheme.Spacing.medium)
                    .frame(maxWidth: 700, alignment: .leading)
            }

        case .heading(let level, let text):
            renderTextView(text: text, font: fontForHeading(level: level), weight: fontWeightForHeading(level: level))
                .padding(.top, UITheme.Spacing.medium)
                .padding(.bottom, UITheme.Spacing.xsmall)

        case .listItem(let prefix, let text, let indentation):
            HStack(alignment: .top, spacing: UITheme.Spacing.small) {
                Text(prefix)
                    .font(UITheme.Fonts.body)
                    .foregroundColor(UITheme.Colors.secondaryText)
                    .frame(minWidth: 20, alignment: .leading)
                
                renderTextView(text: text)
            }
            .padding(.leading, CGFloat(indentation * 20))
            .padding(.bottom, UITheme.Spacing.xxsmall)

        case .horizontalRule:
            Divider()
                .padding(.vertical, UITheme.Spacing.medium)
        
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
            
        case .image(let url, let altText):
            if let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(UITheme.CornerRadius.medium)
                            .overlay(
                                RoundedRectangle(cornerRadius: UITheme.CornerRadius.medium)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .onAppear {
                                logger.info("✅ Successfully loaded image from URL: \(url)")
                            }
                    
                    case .failure(let error):
                        VStack(spacing: UITheme.Spacing.xsmall) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("Failed to load image")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: 500, minHeight: 150, alignment: .center)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(UITheme.CornerRadius.medium)
                        .onAppear {
                            logger.error("❌ Failed to load image from URL: \(url). Error: \(error.localizedDescription)")
                        }

                    case .empty:
                        HStack {
                            Spacer()
                            VStack {
                                ProgressView()
                                if let alt = altText, !alt.isEmpty {
                                    Text(alt)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 4)
                                }
                            }
                            Spacer()
                        }
                        .frame(height: 150)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(UITheme.CornerRadius.medium)
                        .onAppear {
                            logger.debug("⏳ Loading image (placeholder) for URL: \(url)")
                        }

                    @unknown default:
                        EmptyView()
                    }
                }
                .padding(.vertical, UITheme.Spacing.small)
                .frame(maxWidth: 500, alignment: .leading)
            } else {
                EmptyView()
            }
        }
    }
    
    @ViewBuilder
    private func renderTextView(text: String, font: Font = UITheme.Fonts.body, weight: Font.Weight = .regular) -> some View {
        Text(try! AttributedString(markdown: text))
            .font(font)
            .fontWeight(weight)
            .lineSpacing(UITheme.Spacing.xsmall)
            .foregroundColor(UITheme.Colors.primaryText)
            .textSelection(.enabled)
    }
    
    private func fontForHeading(level: Int) -> Font {
        switch level {
        case 1: return UITheme.Fonts.title1
        case 2: return UITheme.Fonts.title2
        default: return UITheme.Fonts.title3
        }
    }
    
    private func fontWeightForHeading(level: Int) -> Font.Weight {
        switch level {
        case 1: return .bold
        case 2: return .semibold
        default: return .semibold
        }
    }
}
