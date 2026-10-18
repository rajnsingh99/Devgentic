// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowNodeView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A draggable node card on the workflow canvas: a compact profile card with input and output ports.
struct WorkflowNodeView: View {
    let node: WorkflowNode
    let isSelected: Bool
    var canvasState: WorkflowCanvasState
    /// This node's outcome on the displayed run. Nil when no run is being shown.
    var runStatus: WorkflowCanvasRunOverlay.NodeStatus? = nil
    /// True while that run is still executing — only then does a `.running` node pulse.
    var runIsLive: Bool = false
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false
    @State private var runPulse = false

    private var nodeSize: CGSize {
        WorkflowCanvasState.nodeSize(for: node.kind)
    }

    // MARK: - Run status badge

    /// The node's outcome on the displayed run, drawn in the card's corner slot.
    /// Colour and icon come from `NodeStatus`, shared with the timeline; reduce-motion swaps the pulse for a static ring.
    @ViewBuilder
    private var runStatusBadge: some View {
        if let runStatus {
            Image(systemName: runStatus.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(runStatus.color(theme))
                .padding(3)
                .background(
                    Circle().fill(theme.primaryBackground)
                        .overlay(Circle().stroke(runStatus.color(theme).opacity(0.35), lineWidth: 1))
                )
                .scaleEffect(shouldPulse && runPulse ? 1.18 : 1.0)
                .offset(x: -6, y: -6)
                .animation(.easeInOut(duration: 0.15), value: runStatus)
                // Why: not `.onAppear`: the badge exists as `.pending` long before the run; the reset also lets a retried node re-arm
                // Arms and disarms the pulse when the decision changes; `initial: true` covers entering the canvas mid-run.
                .onChange(of: shouldPulse, initial: true) { _, pulsing in
                    runPulse = false
                    guard pulsing else { return }
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        runPulse = true
                    }
                }
                // Hidden because the card's `children: .ignore` swallows it; run status is folded into `accessibilityDescription`.
                .accessibilityHidden(true)
        }
    }

    /// Only the node executing right now pulses; a historical run's `.running` node never settled and must not animate.
    /// Delegates to `WorkflowCanvasRunOverlay.badgeShouldPulse` so the rule can be tested outside the view.
    private var shouldPulse: Bool {
        WorkflowCanvasRunOverlay.badgeShouldPulse(status: runStatus, isLive: runIsLive)
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

            // Output Port(s) (right side) — single for most nodes, multi for condition / gate / error ports
            ForEach(Array(outputPortEntries.enumerated()), id: \.offset) { index, entry in
                let portColor = node.kind.portColor(forLabel: entry.label, in: theme)

                WorkflowPortView(
                    portType: .output,
                    nodeColor: portColor,
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
                        let portLabel = entry.label.isEmpty ? nil : entry.label
                        if let targetID = canvasState.findInputPortTarget(near: endPoint, excluding: node.id) {
                            _ = canvasState.addEdge(sourceNodeID: node.id, targetNodeID: targetID, sourcePortLabel: portLabel)
                        } else {
                            // A missed drop is recorded; the state decides whether it was a real miss or an aborted drag near the source port.
                            canvasState.recordMissedEdgeDrop(from: node.id, sourcePortLabel: portLabel, at: endPoint)
                        }
                        canvasState.edgeDragState = nil
                    }
                )
                .overlay(alignment: .leading) {
                    // Label badge hangs strictly to the RIGHT of the port circle with a 6pt gap.
                    // Background capsule protects text from wire-clipping and background dots.
                    if !entry.label.isEmpty {
                        // Why: a Gate option has no length cap and `.fixedSize()` below defeats view-level truncation
                        // The badge text is capped while `entry.label` stays raw as the routing identity.
                        Text(WorkflowCanvasState.portBadgeText(entry.label))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .foregroundColor(portColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(theme.primaryBackground.opacity(0.92))
                                    .overlay(
                                        Capsule()
                                            .stroke(portColor.opacity(0.35), lineWidth: 0.75)
                                    )
                            )
                            .fixedSize()
                            .opacity(isHovering || canvasState.edgeDragState != nil || runStatus != nil ? 1.0 : 0.0)
                            .offset(x: WorkflowCanvasState.portRadius * 2 + 6)
                            .allowsHitTesting(false)
                    }
                }
                .position(
                    x: node.position.x + nodeSize.width,
                    y: entry.y
                )
            }

            // Input Port (left side)
            WorkflowPortView(
                portType: .input,
                nodeColor: profileColor,
                isCompatibleTarget: isCompatibleDropTarget,
                isPrimaryTarget: isPrimaryDropTarget,
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

    // Split from `nodeCard` so the switch plus the long modifier chain stay within the type-checker's budget.
    @ViewBuilder
    private var nodeCardContent: some View {
        Group {
            switch node.kind {
            case .profile(_, let pType):
                ProfileNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    profileType: pType,
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
            case .unsupported:
                // A preserved-but-unknown node: profile-card chrome, colourless identity and a dashed-question icon;
                // the subtitle says why it cannot run.
                ProfileNodeCard(
                    title: node.displayName,
                    subtitle: nodeKindLabel,
                    iconName: iconName,
                    color: profileColor,
                    isSelected: isSelected
                )
            }
        }
    }

    @ViewBuilder
    private var nodeCard: some View {
        nodeCardContent
        .frame(width: nodeSize.width, height: nodeSize.height)
        // A node that did not run recedes, so an unchosen branch looks quiet and inactive rather than failed.
        .opacity(runStatus == .skipped ? 0.45 : 1.0)
        .overlay(alignment: .topLeading) {
            runStatusBadge
        }
        .shadow(
            // Natural elevation shadow
            color: theme.shadowColor.opacity(isSelected ? 0.22 : (isHovering ? 0.12 : 0.06)),
            radius: isSelected ? 8 : (isHovering ? 6 : 3),
            x: 0, y: isSelected ? 4 : 2
        )
        .shadow(
            // Subtle, restrained color halo for selected nodes (avoids overpowering diffuse bloom)
            color: isSelected ? profileColor.opacity(0.16) : Color.clear,
            radius: 6,
            x: 0, y: 0
        )
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        // Set a square content shape to capture hover and clicks easily
        .contentShape(Rectangle())
        // MARK: Accessibility
        // Node-level accessibility: the actions below call the same handlers as the pointer gestures.
        // Keyboard traversal and nudge-to-move are not provided; they compete with three live gesture recognizers.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Select")) {
            canvasState.select(nodeID: node.id)
        }
        // Gated like the double-tap gesture: `.trigger` and `.unsupported` nodes have nothing to configure.
        // Without the gate VoiceOver opens a blank inspector panel.
        .accessibilityAction(named: Text("Configure")) {
            switch node.kind {
            case .trigger, .unsupported: break
            default: canvasState.targetConfigNode = node
            }
        }
        .accessibilityAction(named: Text("Delete node")) {
            canvasState.removeNode(node.id)
        }
        .onTapGesture(count: 2) {
            switch node.kind {
            case .condition, .code, .gate, .action, .profile:
                // Why: excluding them leaves a sub-workflow node with no way to set failure policy, retries or join mode
                // `.profile` is unconditional: `targetConfigNode` is written only from this handler,
                // and workflow-backed profiles need an inspector.
                canvasState.targetConfigNode = node
            case .trigger, .unsupported:
                // `.unsupported`: there is nothing this build could show or edit — the node's
                // config is opaque preserved JSON. Selection, moving and DELETION all still work.
                break
            }
        }
        .onTapGesture {
            canvasState.select(nodeID: node.id)
        }
        .gesture(nodeDragGesture)
        .onHover { isHovering = $0 }
        .pointingHandCursor()
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
                // Why: inline arithmetic here lets the preview and the commit drift apart
                // Goes through `committedDragPosition`, the one place a bound would go, which the preview also reads.
                let newPosition = WorkflowCanvasState.committedDragPosition(
                    origin: node.position,
                    translation: value.translation
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
        case .code:       return "chevron.left.forwardslash.chevron.right"
        case .gate:       return "hand.raised"
        case .trigger:    return "bolt"
        case .action:     return "bolt.horizontal.fill"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    /// Single source for node identity colour via `WorkflowNodeKind.identityColor(in:)`, shared with the edge gradient.
    private var profileColor: Color { node.kind.identityColor(in: theme) }

    /// Composed by `WorkflowCanvasState` so the wording and the edge counts are testable.
    private var accessibilityDescription: String {
        canvasState.accessibilityDescription(for: node, runStatusLabel: runStatus?.label)
    }

    // Why: `Text(subtitle)` does not localize, so every literal needs `String(localized:)`
    /// The card's visible subtitle, separate from `WorkflowCanvasState.accessibilityKindLabel`.
    /// An Action node's subtitle is its configured tool name, which is data and not translated.
    private var nodeKindLabel: String {
        switch node.kind {
        case .profile(_, let pType): return pType.localizedTitleString
        case .condition(let config):
            if node.displayName.caseInsensitiveCompare("Router") == .orderedSame || node.displayName.caseInsensitiveCompare("Condition") == .orderedSame {
                let count = config.rules.count
                return count == 0 ? String(localized: "Conditional branch") : (count == 1 ? String(localized: "1 rule") : String(localized: "\(count) rules"))
            }
            return String(localized: "Router")
        case .code:               return String(localized: "Code")
        case .gate:               return String(localized: "Gate")
        case .trigger:            return String(localized: "Trigger")
        case .action(let config): return config.tool?.name ?? String(localized: "Action")
        case .unsupported:        return String(localized: "Needs a newer Devgentic")
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

    /// Whether this node is a valid drop target for the current edge drag, using the same predicate `addEdge` uses.
    /// Drives the weak highlight tier (visible port, coloured ring); the full pulse belongs to `isPrimaryDropTarget`.
    private var isCompatibleDropTarget: Bool {
        guard let drag = canvasState.edgeDragState else { return false }
        return canvasState.edgeRefusalReason(
            sourceNodeID: drag.sourceNodeID,
            targetNodeID: node.id,
            sourcePortLabel: drag.sourcePortLabel
        ) == nil
    }

    /// The one node the drop would land on right now: valid, with the nearest input port within the accept radius.
    /// Same test as `onDragEnded`; tracks the pointer live via `edgeDragState.currentPoint`.
    private var isPrimaryDropTarget: Bool {
        guard let drag = canvasState.edgeDragState, isCompatibleDropTarget else { return false }
        return canvasState.findInputPortTarget(near: drag.currentPoint, excluding: drag.sourceNodeID) == node.id
    }

}

// MARK: - Dedicated Node Shapes

struct ProfileNodeCard: View {
    let title: String
    let subtitle: String
    let iconName: String
    var profileType: ProfileType? = nil
    let color: Color
    let isSelected: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.15))
                Circle().stroke(color.opacity(0.35), lineWidth: 0.5)

                if let profileType {
                    ProfileTypeIcon(type: profileType, size: 16, color: color)
                } else {
                    Image(systemName: iconName)
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundColor(color)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(theme.fontCaption2)
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
                .fill(color.opacity(isSelected ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? color : theme.surfaceOverlayStrong, lineWidth: isSelected ? 1.75 : 1)
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
                .overlay(
                    WorkflowHexagon().fill(
                        LinearGradient(
                            colors: [color.opacity(isSelected ? 0.14 : 0.08), color.opacity(isSelected ? 0.05 : 0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
        )
        .overlay(
            WorkflowHexagon()
                .stroke(isSelected ? color : theme.surfaceOverlayStrong,
                        lineWidth: isSelected ? 1.75 : 1.0)
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
                // Why: raw red/yellow would read as a Gate-red status signal on every Code node
                // Decorative traffic lights from theme tokens, not identity colours.
                Image(systemName: "circle.fill").foregroundColor(theme.errorColor).font(.system(size: 6))
                Image(systemName: "circle.fill").foregroundColor(theme.warningColor).font(.system(size: 6))
                Image(systemName: "circle.fill").foregroundColor(theme.successColor).font(.system(size: 6))
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
            // Why: `theme.controlBackground` is opaque, so a tint declared after it never renders
            // Order matters: chained `.background` calls stack further back, so the tint must be declared first.
            .background(color.opacity(isSelected ? 0.08 : 0.04))
            .background(theme.controlBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? color : theme.surfaceOverlayStrong, lineWidth: isSelected ? 1.75 : 1)
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
                .shadow(color: color.opacity(0.35), radius: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.fontSubheadline.weight(.heavy))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Text(String(localized: "Human approval required"))
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Capsule()
                .fill(theme.controlBackground)
                .overlay(
                    Capsule().fill(
                        LinearGradient(
                            colors: [color.opacity(isSelected ? 0.18 : 0.12), color.opacity(isSelected ? 0.06 : 0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? color : theme.surfaceOverlayStrong, lineWidth: isSelected ? 1.75 : 1.0)
        )
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
                .foregroundColor(color)
            Text(title)
                .font(theme.fontCaption.weight(.bold))
                .foregroundColor(theme.primaryText)
                .padding(.trailing, 12)
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            WorkflowChevron()
                .fill(theme.controlBackground)
                .overlay(WorkflowChevron().fill(color.opacity(isSelected ? 0.20 : 0.12)))
        )
        .overlay(
            WorkflowChevron()
                .stroke(isSelected ? color : theme.surfaceOverlayStrong,
                        lineWidth: isSelected ? 1.75 : 1.0)
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
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.15))
                )

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
                        .font(theme.fontCodeCaption)
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
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(color.opacity(isSelected ? 0.10 : 0.06))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? color : theme.surfaceOverlayStrong,
                        lineWidth: isSelected ? 1.75 : 1.0)
        )
    }
}

// MARK: - Custom Shapes

struct WorkflowHexagon: Shape {
    var cornerRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let angleWidth = rect.width * 0.15
        let r = min(cornerRadius, angleWidth * 0.6, rect.height * 0.15)

        let p0 = CGPoint(x: angleWidth, y: 0)
        let p1 = CGPoint(x: rect.width - angleWidth, y: 0)
        let p2 = CGPoint(x: rect.width, y: rect.height / 2)
        let p3 = CGPoint(x: rect.width - angleWidth, y: rect.height)
        let p4 = CGPoint(x: angleWidth, y: rect.height)
        let p5 = CGPoint(x: 0, y: rect.height / 2)

        path.move(to: CGPoint(x: rect.width / 2, y: 0))
        path.addArc(tangent1End: p1, tangent2End: p2, radius: r)
        path.addArc(tangent1End: p2, tangent2End: p3, radius: r)
        path.addArc(tangent1End: p3, tangent2End: p4, radius: r)
        path.addArc(tangent1End: p4, tangent2End: p5, radius: r)
        path.addArc(tangent1End: p5, tangent2End: p0, radius: r)
        path.addArc(tangent1End: p0, tangent2End: p1, radius: r)
        path.closeSubpath()
        return path
    }
}

struct WorkflowChevron: Shape {
    var cornerRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tailInset = rect.width * 0.15
        let r = min(cornerRadius, tailInset * 0.6, rect.height * 0.15)

        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: rect.width - tailInset, y: 0)
        let p2 = CGPoint(x: rect.width, y: rect.height / 2)
        let p3 = CGPoint(x: rect.width - tailInset, y: rect.height)
        let p4 = CGPoint(x: 0, y: rect.height)

        path.move(to: CGPoint(x: 0, y: rect.height / 2))
        path.addArc(tangent1End: p0, tangent2End: p1, radius: r)
        path.addArc(tangent1End: p1, tangent2End: p2, radius: r)
        path.addArc(tangent1End: p2, tangent2End: p3, radius: r)
        path.addArc(tangent1End: p3, tangent2End: p4, radius: r)
        path.addArc(tangent1End: p4, tangent2End: p0, radius: r)
        path.closeSubpath()
        return path
    }
}
