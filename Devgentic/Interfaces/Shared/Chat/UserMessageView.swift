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

    @EnvironmentObject private var themeManager: ThemeManager
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
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .padding(6)
                            .background(Color.black.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand")
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

        let lowercasedText = text.lowercased()
        let lowercasedQuery = searchQuery.lowercased()

        guard !lowercasedQuery.isEmpty else { return attrString }

        var matchRanges: [Range<String.Index>] = []
        var searchStart = lowercasedText.startIndex
        while searchStart < lowercasedText.endIndex,
              let range = lowercasedText.range(of: lowercasedQuery, range: searchStart..<lowercasedText.endIndex) {
            matchRanges.append(range)
            searchStart = range.upperBound
        }

        let highlightColor = Color.yellow.opacity(0.4)
        let activeHighlightColor = Color.orange.opacity(0.6)

        for (index, range) in matchRanges.enumerated().reversed() {
            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
            let attrStart = attrString.index(attrString.startIndex, offsetByCharacters: startOffset)
            let attrEnd = attrString.index(attrString.startIndex, offsetByCharacters: endOffset)
            let attrRange = attrStart..<attrEnd

            let isActiveMatch = (activeHighlightIndex == index)
            attrString[attrRange].backgroundColor = isActiveMatch ? activeHighlightColor : highlightColor
        }

        return attrString
    }
    
    private func determineTruncation(availableWidth: CGFloat) {
        let fullTextView = Text(text)
            .font(themeManager.chatFont)
            .frame(width: availableWidth, alignment: .leading)

        let truncatedTextView = Text(text)
            .font(themeManager.chatFont)
            .lineLimit(lineLimitCollapsed)
            .frame(width: availableWidth, alignment: .leading)
            
        let fullSize = NSHostingView(rootView: fullTextView).fittingSize
        let truncatedSize = NSHostingView(rootView: truncatedTextView).fittingSize
        
        if fullSize.height > truncatedSize.height + 2 {
            self.isTruncatable = true
        }
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
            .background(
                UserBubbleShape()
                    .fill(.ultraThinMaterial) // Native glass effect
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2) // Floating depth
            )
            .overlay(
                UserBubbleShape()
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.3),
                                Color.white.opacity(0.05)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func userBubbleStyle() -> some View {
        self.modifier(UserBubbleModifier())
    }
}
