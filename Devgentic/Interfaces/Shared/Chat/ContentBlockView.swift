//
//  ContentBlockView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/08/25.
//
//  Phase 5: Motion & Polish - Added Blinking Cursor & Text Smoothing.

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ContentBlockView")
private let CODE_BLOCK_LINE_LIMIT = 50

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
    // New prop to determine if we should show the cursor
    var isLastBlock: Bool = false
    
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(UITheme.CornerRadius.medium)
                            .overlay(RoundedRectangle(cornerRadius: UITheme.CornerRadius.medium).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                    case .failure(_):
                        VStack(spacing: UITheme.Spacing.xsmall) {
                            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundColor(.secondary)
                            Text("Failed to load image").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: 500, minHeight: 150, alignment: .center)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(UITheme.CornerRadius.medium)
                    case .empty:
                        HStack {
                            Spacer()
                            VStack {
                                ProgressView()
                                if let alt = altText, !alt.isEmpty { Text(alt).font(.caption).foregroundColor(.secondary).padding(.top, 4) }
                            }
                            Spacer()
                        }
                        .frame(height: 150)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(UITheme.CornerRadius.medium)
                    @unknown default: EmptyView()
                    }
                }
                .padding(.vertical, UITheme.Spacing.small)
                .frame(maxWidth: 500, alignment: .leading)
            } else { EmptyView() }
        }
    }
    
    // MARK: - Text Rendering with Motion & Polish
    
    /// Renders the styled text and optionally adds the blinking cursor if this is the active stream block.
    @ViewBuilder
    private func renderTextView(text: String, font: Font = UITheme.Fonts.body, weight: Font.Weight = .regular) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Text(createStyledString(from: text, font: font, weight: weight))
                .lineSpacing(4) // Phase 4: Editorial spacing
                .textSelection(.enabled)
                // Smooth out text updates slightly to avoid harsh token jitter
                .animation(.linear(duration: 0.05), value: text.count)
            
            // Phase 5: The Blinking Cursor
            if message.isStreaming && isLastBlock {
                BlinkingCursor()
                    .padding(.leading, 2)
                    .padding(.bottom, 4) // Align with baseline
            }
        }
    }
    
    private func createStyledString(from text: String, font: Font, weight: Font.Weight) -> AttributedString {
        if var attributedString = try? AttributedString(markdown: text) {
            for run in attributedString.runs {
                if run.inlinePresentationIntent == .code {
                    attributedString[run.range].backgroundColor = UITheme.Colors.inlineCodeBackground
                    attributedString[run.range].foregroundColor = UITheme.Colors.inlineCodeText
                    attributedString[run.range].font = .system(.body, design: .monospaced)
                } else {
                    attributedString[run.range].font = font.weight(weight)
                    attributedString[run.range].foregroundColor = UITheme.Colors.primaryText
                }
            }
            return attributedString
        } else {
            var fallbackString = AttributedString(text)
            fallbackString.font = font.weight(weight)
            fallbackString.foregroundColor = UITheme.Colors.primaryText
            return fallbackString
        }
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

// MARK: - Blinking Cursor View
struct BlinkingCursor: View {
    @State private var isVisible = true
    
    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 16)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(Animation.easeInOut(duration: 0.6).repeatForever()) {
                    isVisible.toggle()
                }
            }
    }
}
