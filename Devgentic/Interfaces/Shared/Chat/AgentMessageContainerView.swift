//
//  AgentMessageContainerView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import MarkdownUI
import Splash

struct AgentMessageContainerView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    let message: ChatMessage

    private let maxImageWidth: CGFloat = 350
    private let agentForegroundColor = Color.primary
    private let maxCodeBlockWidth: CGFloat = 750
    private let largeCodeBlockThreshold = 100

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            switch message.content {
            case .codeBlock(let language, let code):
                // --- PHASE 3 CHANGE: Check line count and render card or block ---
                let lineCount = code.split(whereSeparator: \.isNewline).count
                if lineCount > largeCodeBlockThreshold {
                    CodeBlockCardView(
                        language: language,
                        lineCount: lineCount,
                        action: {
                            viewModel.showCodeInViewer(language: language, code: code)
                        }
                    )
                } else {
                    CodeBlockView(language: language, code: code)
                        .frame(maxWidth: maxCodeBlockWidth, alignment: .leading)
                }

            case .image(let url, let alt):
                ImageView(url: url, alt: alt)
                    .frame(maxWidth: maxImageWidth, alignment: .leading)

            case .plainText(let text):
                Text(text)
                    .font(.system(size: 16))
                    .textSelection(.enabled)
                    .foregroundColor(agentForegroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 15)

            case .markdownText(let text):
                Markdown(text)
                    .textSelection(.enabled)
                    .markdownTheme(
                        Theme.basic
                            .text {
                                FontSize(16)
                            }
                            .codeBlock { configuration in
                                // --- PHASE 3 CHANGE: Apply same logic to embedded code blocks ---
                                let code = configuration.content
                                let language = configuration.language
                                let lineCount = code.split(whereSeparator: \.isNewline).count

                                if lineCount > largeCodeBlockThreshold {
                                    CodeBlockCardView(
                                        language: language,
                                        lineCount: lineCount,
                                        action: {
                                            viewModel.showCodeInViewer(language: language, code: code)
                                        }
                                    )
                                    .padding(.vertical, 15)
                                } else {
                                    CodeBlockView(
                                        language: language,
                                        code: code
                                    )
                                    .frame(maxWidth: maxCodeBlockWidth, alignment: .leading)
                                    .padding(.vertical, 15)
                                }
                            }
                    )
                    .foregroundColor(agentForegroundColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 15)

            case .error(let title, let details):
                ErrorMessageView(title: title, details: details)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
