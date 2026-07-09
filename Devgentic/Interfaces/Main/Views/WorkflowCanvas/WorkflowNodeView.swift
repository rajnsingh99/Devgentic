//
//  WorkflowNodeView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Individual draggable node card on the workflow canvas.
//  Renders a compact profile card with input/output ports.
//

import SwiftUI

struct WorkflowNodeView: View {
    let node: WorkflowNode
    let isSelected: Bool
    var canvasState: WorkflowCanvasState
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    private var nodeSize: CGSize {
        WorkflowCanvasState.nodeSize(for: node.kind)
    }

    /// Drag offset sourced from centralized state — survives parent re-renders.
    private var dragOffset: CGSize {
        canvasState.nodeDragOffset(for: node.id)
    }

    var body: some View {
        ZStack {
            // Node Card
            nodeCard
                .position(
                    x: node.position.x + nodeSize.width / 2,
                    y: node.position.y + nodeSize.height / 2
                )

            // Output Port(s) (right side) — single for most nodes, multi for condition
            ForEach(Array(outputPortEntries.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 2) {
                    // Port label (only for multi-port nodes)
                    if outputPortEntries.count > 1 {
                        Text(entry.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(profileColor)
                            .opacity(isHovering || canvasState.edgeDragState != nil ? 1.0 : 0.0)
                    }
                    WorkflowPortView(
                        portType: .output,
                        nodeColor: profileColor,
                        isCompatibleTarget: false,
                        isNodeHovered: isHovering,
                        onDragStarted: { startPos in
                            canvasState.edgeDragState = EdgeDragState(
                                sourceNodeID: node.id,
                                sourcePortLabel: entry.label.isEmpty ? nil : entry.label,
                                currentPoint: startPos
                            )
                        },
                        onDragUpdated: { point in
                            canvasState.edgeDragState?.currentPoint = point
                        },
                        onDragEnded: { endPoint in
                            if let targetID = canvasState.findInputPortTarget(near: endPoint, excluding: node.id) {
                                let portLabel = entry.label.isEmpty ? nil : entry.label
                                _ = canvasState.addEdge(sourceNodeID: node.id, targetNodeID: targetID, sourcePortLabel: portLabel)
                            }
                            canvasState.edgeDragState = nil
                        }
                    )
                }
                .position(
                    x: node.position.x + nodeSize.width + (outputPortEntries.count > 1 ? 12 : 0),
                    y: entry.y
                )
            }

            // Input Port (left side)
            WorkflowPortView(
                portType: .input,
                nodeColor: profileColor,
                isCompatibleTarget: isCompatibleDropTarget,
                isNodeHovered: isHovering
            )
            .position(
                x: node.position.x,
                y: node.position.y + nodeSize.height / 2
            )
        }
        // Apply structural offset directly. By avoiding constant .position recalculations
        // inside the nodes, we stop SwiftUI from layout thrashing and causing ghosts.
        .offset(dragOffset)
    }

    // MARK: - Node Card Dispatch

    @ViewBuilder
    private var nodeCard: some View {
        Group {
            switch node.kind {
            case .profile:
                ProfileNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    color: profileColor,
                    isSelected: isSelected
                )
            case .condition:
                ConditionNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    color: profileColor,
                    isSelected: isSelected
                )
            case .code:
                CodeNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    color: profileColor,
                    isSelected: isSelected
                )
            case .gate:
                GateNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    color: profileColor,
                    isSelected: isSelected
                )
            case .loop:
                LoopNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    color: profileColor,
                    isSelected: isSelected
                )
            case .trigger:
                TriggerNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    color: profileColor,
                    isSelected: isSelected
                )
            case .action:
                ActionNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    color: profileColor,
                    isSelected: isSelected
                )
            }
        }
        .frame(width: nodeSize.width, height: nodeSize.height)
        .overlay(alignment: .topLeading) {
            if isOrJoin { orJoinBadge }
        }
        .shadow(
            color: isSelected ? profileColor.opacity(0.35) : Color.black.opacity(isHovering ? 0.12 : 0.06),
            radius: isSelected ? 12 : (isHovering ? 6 : 3),
            x: 0, y: isSelected ? 4 : 2
        )
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        // Set a square content shape to capture hover and clicks easily
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            switch node.kind {
            case .condition, .loop, .code, .gate, .action:
                canvasState.targetConfigNode = node
            case .profile(_, let pType) where pType != .workflow:
                canvasState.targetConfigNode = node
            default:
                break
            }
        }
        .onTapGesture {
            canvasState.select(nodeID: node.id)
        }
        .gesture(nodeDragGesture)
        .onHover { isHovering = $0 }
    }

    // MARK: - Drag to Move

    private var nodeDragGesture: some Gesture {
        // Track dragging in the canvas' unscaled coordinate system.
        // This ensures the mouse translation maps 1:1 visually regardless of scale/pan.
        DragGesture(minimumDistance: 3, coordinateSpace: .named("canvasContent"))
            .onChanged { value in
                if canvasState.activeNodeDrag == nil {
                    canvasState.select(nodeID: node.id)
                }
                canvasState.activeNodeDrag = (nodeID: node.id, offset: value.translation)
            }
            .onEnded { value in
                let newPosition = CGPoint(
                    x: max(0, node.position.x + value.translation.width),
                    y: max(0, node.position.y + value.translation.height)
                )
                canvasState.activeNodeDrag = nil
                canvasState.moveNode(node.id, to: newPosition)
            }
    }

    // MARK: - Helpers

    private var iconName: String {
        switch node.kind {
        case .profile(_, let pType): return pType.iconName
        case .condition:  return "arrow.triangle.branch"
        case .loop:       return "arrow.trianglehead.2.clockwise"
        case .code:       return "chevron.left.forwardslash.chevron.right"
        case .gate:       return "hand.raised"
        case .trigger:    return "bolt"
        case .action:     return "bolt.horizontal.fill"
        }
    }

    private var profileColor: Color {
        switch node.kind {
        case .profile(_, let pType):
            return pType.displayColor
        case .condition:  return .yellow
        case .loop:       return .orange
        case .code:       return .cyan
        case .gate:       return .red
        case .trigger:    return .gray
        case .action:     return .teal
        }
    }

    private var nodeKindLabel: String {
        switch node.kind {
        case .profile(_, let pType): return pType.rawValue
        case .condition:          return "Condition"
        case .loop(let config):   return config.subtitle
        case .code:               return "Code"
        case .gate:       return "Gate"
        case .trigger:    return "Trigger"
        case .action(let config): return config.tool?.name ?? "Action"
        }
    }

    /// Output port entries with label and Y position, computed from the node's kind.
    private var outputPortEntries: [(label: String, y: CGFloat)] {
        let labels = canvasState.outputPortLabels(for: node)
        if labels.isEmpty {
            // Single default output port — centered
            return [("", node.position.y + nodeSize.height / 2)]
        }
        // Multi-port — stack vertically
        let spacing = nodeSize.height / CGFloat(labels.count + 1)
        return labels.enumerated().map { index, label in
            (label, node.position.y + spacing * CGFloat(index + 1))
        }
    }

    /// Whether this node is a valid drop target for the current edge drag.
    private var isCompatibleDropTarget: Bool {
        guard let drag = canvasState.edgeDragState else { return false }
        guard drag.sourceNodeID != node.id else { return false }
        return true
    }

    /// True when this node merges its incoming branches with OR semantics.
    private var isOrJoin: Bool {
        node.nodeConfig?.joinMode == .any
    }

    /// Compact badge surfaced on OR-join nodes so the merge semantics are
    /// visible on the canvas without opening the inspector. Non-interactive so
    /// it never steals taps from node selection / drag.
    private var orJoinBadge: some View {
        Text("OR")
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange))
            .overlay(Capsule().stroke(theme.primaryBackground, lineWidth: 1))
            .padding(4)
            .allowsHitTesting(false)
    }
}

// MARK: - Dedicated Node Shapes

struct ProfileNodeCard: View {
    let title: String
    let subtitle: String
    let iconName: String
    let color: Color
    let isSelected: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(.subheadline, weight: .bold))
                .foregroundColor(color)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.15)))
                .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(.caption2))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.controlBackground, theme.controlBackground.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? color : theme.surfaceOverlayStrong, lineWidth: isSelected ? 2 : 1)
        )
    }
}

struct ConditionNodeCard: View {
    let title: String
    let subtitle: String
    let iconName: String
    let color: Color
    let isSelected: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(color)
            
            Text(title)
                .font(theme.fontCaption.weight(.bold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundColor(theme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            WorkflowHexagon()
                .fill(theme.controlBackground)
        )
        .overlay(
            WorkflowHexagon()
                .stroke(isSelected ? color : color.opacity(0.5), lineWidth: isSelected ? 2.5 : 1.5)
        )
        .background(
            WorkflowHexagon()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.12), color.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }
}

struct CodeNodeCard: View {
    let title: String
    let subtitle: String
    let iconName: String
    let color: Color
    let isSelected: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").foregroundColor(.red).font(.system(size: 6))
                Image(systemName: "circle.fill").foregroundColor(.yellow).font(.system(size: 6))
                Image(systemName: "circle.fill").foregroundColor(.green).font(.system(size: 6))
                Spacer()
                Text(subtitle)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(color.opacity(0.95))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.surfaceOverlay.opacity(0.9))

            Divider()

            // Body
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(color)
                
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxHeight: .infinity)
            .background(theme.controlBackground)
            .background(color.opacity(0.04))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? color : theme.surfaceOverlayStrong, lineWidth: isSelected ? 2 : 1)
        )
    }
}

struct GateNodeCard: View {
    let title: String
    let subtitle: String
    let iconName: String
    let color: Color
    let isSelected: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color))
                .shadow(color: color.opacity(0.4), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.fontSubheadline.weight(.heavy))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text("Halts execution for approval")
                    .font(.system(.caption2))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(theme.controlBackground)
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? color : color.opacity(0.8), lineWidth: isSelected ? 3 : 2)
        )
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.15), color.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }
}

struct LoopNodeCard: View {
    let title: String
    let subtitle: String
    let iconName: String
    let color: Color
    let isSelected: Bool
    @Environment(\.appTheme) private var theme
    @State private var rotationPhase: CGFloat = 0

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(color)

            Text(title)
                .font(theme.fontCaption.weight(.bold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Text(subtitle)
                .font(.system(size: 8))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Circle()
                .fill(theme.controlBackground)
        )
        .overlay(
            Circle()
                .strokeBorder(isSelected ? color : color.opacity(0.5), style: StrokeStyle(lineWidth: isSelected ? 3 : 2, dash: [6, 4], dashPhase: rotationPhase))
        )
        .background(
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.12), color.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .onAppear {
            withAnimation(.linear(duration: 3.0).repeatForever(autoreverses: false)) {
                rotationPhase = 20
            }
        }
    }
}

struct TriggerNodeCard: View {
    let title: String
    let subtitle: String
    let iconName: String
    let color: Color
    let isSelected: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(.white)
            Text(title)
                .font(theme.fontCaption.weight(.bold))
                .foregroundColor(.white)
                .padding(.trailing, 12)
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            WorkflowChevron()
                .fill(color)
        )
        .overlay(
            WorkflowChevron()
                .stroke(isSelected ? .white : .clear, lineWidth: isSelected ? 2 : 0)
        )
    }
}

struct ActionNodeCard: View {
    let title: String
    let subtitle: String   // the tool name (or "Action" when unconfigured)
    let iconName: String
    let color: Color
    let isSelected: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color))
                .shadow(color: color.opacity(0.35), radius: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("ACTION")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(color)
                    Text("\u{00B7}")
                        .foregroundColor(theme.tertiaryText)
                    Text(subtitle)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.controlBackground)
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? color : color.opacity(0.5), lineWidth: isSelected ? 2 : 1.5)
        )
    }
}

// MARK: - Custom Shapes

struct WorkflowHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let angleWidth = rect.width * 0.15
        
        path.move(to: CGPoint(x: angleWidth, y: 0))
        path.addLine(to: CGPoint(x: rect.width - angleWidth, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height / 2))
        path.addLine(to: CGPoint(x: rect.width - angleWidth, y: rect.height))
        path.addLine(to: CGPoint(x: angleWidth, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height / 2))
        path.closeSubpath()
        return path
    }
}

struct WorkflowChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tailInset = rect.width * 0.15
        
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width - tailInset, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height / 2))
        path.addLine(to: CGPoint(x: rect.width - tailInset, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
