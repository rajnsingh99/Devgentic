//
//  UserMessageView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/08/25.
//
//  Phase 4: Modern "Floating" User Bubble with Glassmorphism.

import SwiftUI
import AppKit

struct UserMessageView: View {
    let text: String
    var searchQuery: String = ""
    var activeHighlightIndex: Int? = nil
    private let lineLimitCollapsed = 10
    @State private var isExpanded = false
    @State private var isTruncatable = false

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isTruncatable {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.system(.caption, weight: .bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .padding(6)
                            .background(theme.surfaceOverlayStrong)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand")
                    .accessibilityLabel(isExpanded ? "Collapse message" : "Expand message")
                }
            }

            if !searchQuery.isEmpty {
                Text(highlightedText)
                    .font(themeManager.chatFont)
                    .lineLimit(isExpanded ? nil : lineLimitCollapsed)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.onAppear {
                                determineTruncation(availableWidth: geometry.size.width)
                            }
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(text)
                    .font(themeManager.chatFont)
                    .lineLimit(isExpanded ? nil : lineLimitCollapsed)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.onAppear {
                                determineTruncation(availableWidth: geometry.size.width)
                            }
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .clipped()
    }

    private var highlightedText: AttributedString {
        var attrString = AttributedString(text)
        attrString.font = themeManager.chatFont
        // Shared O(n) forward-cursor highlighter with theme hues (previously an
        // O(matches·n) reversed pass with its own drifted colors).
        return SearchHighlighter.highlight(
            attrString,
            query: searchQuery,
            activeMatchIndex: activeHighlightIndex,
            base: theme.searchHighlight,
            active: theme.searchHighlightActive
        )
    }
    
    /// Cached width for which truncation was last computed — avoids re-creating
    /// expensive NSHostingViews on every GeometryReader callback.
    @State private var lastMeasuredWidth: CGFloat = 0

    private func determineTruncation(availableWidth: CGFloat) {
        // Skip re-computation if the width hasn't changed meaningfully (±2pt tolerance).
        guard abs(availableWidth - lastMeasuredWidth) > 2 else { return }
        lastMeasuredWidth = availableWidth

        // Heuristic fast-path: short messages are never truncatable.
        // Average line at typical chat width holds ~80 chars; if text is shorter
        // than lineLimitCollapsed * 80 chars, skip the expensive hosting views.
        let estimatedCharsPerLine = max(40, Int(availableWidth / 7))
        if text.count < lineLimitCollapsed * estimatedCharsPerLine {
            isTruncatable = false
            return
        }

        let fullTextView = Text(text)
            .font(themeManager.chatFont)
            .frame(width: availableWidth, alignment: .leading)

        let truncatedTextView = Text(text)
            .font(themeManager.chatFont)
            .lineLimit(lineLimitCollapsed)
            .frame(width: availableWidth, alignment: .leading)

        let fullSize = NSHostingView(rootView: fullTextView).fittingSize
        let truncatedSize = NSHostingView(rootView: truncatedTextView).fittingSize

        isTruncatable = fullSize.height > truncatedSize.height + 2
    }
}

// MARK: - Shape & Style

struct UserBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat = 16
        var path = Path()

        // Start just after the top-left corner radius
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        
        // Top-right corner (Slightly sharper to indicate direction, but rounded for modern look)
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - 4, y: rect.minY + 4),
            radius: 4,
            startAngle: Angle(degrees: -90),
            endAngle: Angle(degrees: 0),
            clockwise: false
        )

        // Bottom-right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 0),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )

        // Bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 180),
            clockwise: false
        )
        
        // Top-left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius),
            radius: cornerRadius,
            startAngle: Angle(degrees: 180),
            endAngle: Angle(degrees: 270),
            clockwise: false
        )
        
        path.closeSubpath()
        return path
    }
}

struct UserBubbleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundColor(.primary) // Auto-adapts to light/dark
            // MARK: Liquid Glass
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
            // .background(
            //     UserBubbleShape()
            //         .fill(.ultraThinMaterial) // Native glass effect
            //         .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2) // Floating depth
            // )
            // .overlay(
            //     UserBubbleShape()
            //         .stroke(
            //             LinearGradient(
            //                 gradient: Gradient(colors: [
            //                     Color.white.opacity(0.3),
            //                     Color.white.opacity(0.05)
            //                 ]),
            //                 startPoint: .topLeading,
            //                 endPoint: .bottomTrailing
            //             ),
            //             lineWidth: 1
            //         )
            // )
    }
}

extension View {
    func userBubbleStyle() -> some View {
        self.modifier(UserBubbleModifier())
    }
}
