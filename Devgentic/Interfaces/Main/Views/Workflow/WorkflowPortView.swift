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
    let profileType: ProfileType
    var isCompatibleTarget: Bool = false
    var isNodeHovered: Bool = false

    // Edge drawing callbacks (only used for output ports)
    var onDragStarted: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private let radius: CGFloat = WorkflowCanvasState.portRadius

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: radius * 2, height: radius * 2)
            .overlay(
                Circle()
                    .stroke(strokeColor, lineWidth: 1.5)
            )
            .scaleEffect(isHovering || isCompatibleTarget ? 1.4 : 1.0)
            .shadow(color: glowColor, radius: isCompatibleTarget ? 4 : 0)
            .opacity(isNodeHovered || isHovering || isCompatibleTarget ? 1.0 : 0.0)
            .contentShape(Circle().inset(by: -8)) // Larger hit area
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .gesture(portType == .output ? outputDragGesture : nil)
    }

    // MARK: - Output Port Drag Gesture

    private var outputDragGesture: some Gesture {
        // Tie to the unscaled canvas layout explicitly
        DragGesture(coordinateSpace: .named("canvasContent"))
            .onChanged { value in
                if value.translation.width == 0 && value.translation.height == 0 {
                    onDragStarted?(value.startLocation)
                }
                onDragUpdated?(value.location)
            }
            .onEnded { value in
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

    private var portProfileColor: Color {
        switch profileType {
        case .bot: return .blue
        case .agent: return .green
        case .workflow: return .purple
        case .imageGen: return .orange
        }
    }
}
