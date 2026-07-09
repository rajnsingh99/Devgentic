//
//  WorkflowPortView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Input/output port circles on workflow nodes.
//  Output ports are draggable to create new edges.
//

import SwiftUI

struct WorkflowPortView: View {
    let portType: PortType
    let nodeColor: Color
    var isCompatibleTarget: Bool = false
    var isNodeHovered: Bool = false

    // Edge drawing callbacks (only used for output ports)
    var onDragStarted: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private let radius: CGFloat = WorkflowCanvasState.portRadius

    @State private var pulseIndicator = false

    var body: some View {
        ZStack {
            if isCompatibleTarget || isHovering {
                Circle()
                    .stroke(portProfileColor.opacity(0.35), lineWidth: 1.5)
                    .scaleEffect(pulseIndicator ? 1.6 : 1.1)
                    .opacity(pulseIndicator ? 0.0 : 1.0)
                    .frame(width: radius * 2, height: radius * 2)
            }

            Circle()
                .fill(fillColor)
                .frame(width: radius * 2, height: radius * 2)
                .overlay(
                    Circle()
                        .stroke(strokeColor, lineWidth: 1.5)
                )
                .shadow(color: glowColor, radius: isCompatibleTarget || isHovering ? 5 : 0)
        }
        .scaleEffect(isHovering || isCompatibleTarget ? 1.35 : 1.0)
        .opacity(isNodeHovered || isHovering || isCompatibleTarget ? 1.0 : 0.0)
        .contentShape(Circle().inset(by: -8)) // Larger hit area
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
        .gesture(portType == .output ? outputDragGesture : nil)
        .onChange(of: isCompatibleTarget, initial: true) { _, compatible in
            if compatible {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    pulseIndicator = true
                }
            } else {
                pulseIndicator = false
            }
        }
    }

    @State private var isDragging = false

    // MARK: - Output Port Drag Gesture

    private var outputDragGesture: some Gesture {
        // Tie to the unscaled canvas layout explicitly
        DragGesture(coordinateSpace: .named("canvasContent"))
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onDragStarted?(value.startLocation)
                }
                onDragUpdated?(value.location)
            }
            .onEnded { value in
                isDragging = false
                onDragEnded?(value.location)
            }
    }

    // MARK: - Colors

    private var fillColor: Color {
        if isCompatibleTarget {
            return portProfileColor.opacity(0.3)
        }
        if isHovering {
            return portProfileColor.opacity(0.2)
        }
        return theme.controlBackground
    }

    private var strokeColor: Color {
        if isCompatibleTarget || isHovering {
            return portProfileColor
        }
        return theme.secondaryText.opacity(0.4)
    }

    private var glowColor: Color {
        isCompatibleTarget ? portProfileColor.opacity(0.4) : .clear
    }

    private var portProfileColor: Color { nodeColor }
}
