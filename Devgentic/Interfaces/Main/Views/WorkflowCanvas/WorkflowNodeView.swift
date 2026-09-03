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

    /// The node's outcome on the displayed run, drawn into the corner slot that sat empty until
    /// 2026-08-15 — the canvas showed no execution state at all, so a user watching a workflow
    /// could not tell a running node from a finished one from one that never ran.
    ///
    /// Colour and icon come from `NodeStatus`, the same vocabulary the timeline uses, so the two
    /// views cannot disagree about the same node. Reduce-motion is honoured: the pulse is the only
    /// animation, and a static ring reads the same.
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
                // [CVV-4] Arm AND disarm on the DECISION changing, not on the badge appearing.
                //
                // ⚠️ `.onAppear` could never work here. `WorkflowRunDisplayData.buildNodesFromLayout`
                // pre-populates a `.pending` placeholder for every layout node, so this `Image` is
                // inserted the moment the canvas is — long before the node starts. `onAppear` fired
                // once, with `shouldPulse == false`, the guard dropped the arming, and the later
                // `.pending → .running` transition only UPDATED the same view, so nothing re-ran it.
                // The result: the pulse effectively never started during a live run.
                //
                // The unconditional reset is load-bearing twice — it ends the in-flight
                // `repeatForever` when the node settles, and it guarantees the arming write is a
                // real `false → true` change. Without it a RETRIED node (a `.failed` row reopened
                // as `.running`) would find `runPulse` already true, so SwiftUI would coalesce the
                // write, animate nothing, and leave the badge statically enlarged.
                //
                // `initial: true` preserves the one case `.onAppear` got right: entering the canvas
                // mid-run on a node that is already `.running`.
                .onChange(of: shouldPulse, initial: true) { _, pulsing in
                    runPulse = false
                    guard pulsing else { return }
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        runPulse = true
                    }
                }
                // ⚠️ Hidden, NOT unlabelled. The node card below is an accessibility element with
                // `children: .ignore`, which swallows this one — so the run status is folded into
                // `accessibilityDescription` instead. Re-adding a label here would be dead code that
                // looks like coverage.
                .accessibilityHidden(true)
        }
    }

    /// Only the node executing RIGHT NOW pulses. A historical run's `.running` node is a node that
    /// never settled — animating it would claim work is still happening in a run that has ended.
    ///
    /// ⚠️ Delegates to `WorkflowCanvasRunOverlay.badgeShouldPulse` so the rule is truth-tableable
    /// (WF-UI5) — a `View`'s private computed property is unreachable from a test, and this rule is
    /// exactly what CVV-4 got wrong.
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
                            // CVV-2: the miss was the one silent non-event left on this path —
                            // no edge, no banner, no log. The state decides whether it was a
                            // real miss or an aborted drag (release near the source port).
                            canvasState.recordMissedEdgeDrop(from: node.id, sourcePortLabel: portLabel, at: endPoint)
                        }
                        canvasState.edgeDragState = nil
                    }
                )
                .overlay(alignment: .leading) {
                    // Label badge hangs strictly to the RIGHT of the port circle with a 6pt gap.
                    // Background capsule protects text from wire-clipping and background dots.
                    if !entry.label.isEmpty {
                        // [CVV-3] The badge text is CAPPED; `entry.label` stays raw everywhere it
                        // is used as a routing identity above. A Gate option has no length cap at
                        // any layer, and `.fixedSize()` below defeats any view-level truncation.
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

    // ⚠️ Split from `nodeCard` because the switch PLUS the ~15-modifier chain in one expression
    // exceeds the type-checker's budget ("unable to type-check this expression in reasonable
    // time"). Two named halves check independently and instantly.
    @ViewBuilder
    private var nodeCardContent: some View {
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
                // [WF-PE4] Preserved-but-unknown node. Profile-card chrome (same footprint), the
                // colourless identity and a dashed-question icon make it read as "not one of
                // ours"; the subtitle says why it cannot run.
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
        // A node that did NOT run recedes rather than shouting. This is the whole point of the
        // typed skip model reaching the canvas: an unchosen branch should look quiet and obviously
        // inactive, not like something went wrong.
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
        //
        // ⚠️ The canvas had NO node-level accessibility at all: a VoiceOver user got the node's
        // `Text` runs as loose, untraited strings with no indication that they formed a control,
        // no selection state, and no way to act on them — while the very mode switch that reveals
        // the canvas is properly labeled. Selection, inspection and deletion existed ONLY as
        // pointer gestures (tap, double-tap, drag) with no context menu anywhere in the directory.
        //
        // The three actions below are wired to the same handlers the gestures use, so this is a
        // second route to existing behaviour rather than a new interaction model. Keyboard
        // traversal (arrow-key focus over the node set, keyboard connect, nudge-to-move) is
        // deliberately NOT here — that is a real interaction design for a node-graph editor and it
        // competes with three live gesture recognizers.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Select")) {
            canvasState.select(nodeID: node.id)
        }
        // [WF-PE4] Gated the same way the double-tap gesture below is gated — found on
        // adversarial audit that this VoiceOver twin had no such guard, so a screen-reader user
        // invoking "Configure" on a `.trigger` or `.unsupported` node opened a borderless,
        // effectively blank inspector panel (`.unsupported`'s config is opaque preserved JSON;
        // there is nothing this build could show or edit — see the gesture's own comment).
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
                // ⚠️ `.profile` is unconditional on purpose. Excluding workflow-backed profiles
                // here left them with NO way to reach an inspector — `targetConfigNode` is
                // written only from this handler — while the validator still demanded a task
                // description and told the user to double-click. `ProfileNodeInspectorView`
                // has always rendered every profile type (`WorkflowCanvasView` routes plain
                // `case .profile:`); only the gesture refused, so a sub-workflow node could
                // never have its failure policy, retries or join mode configured either.
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
                // ⚠️ Goes through `committedDragPosition` even though it is now plain addition:
                // it is the ONE place a bound would go, and the preview reads the same rule. Doing
                // the arithmetic inline here is how the preview and the commit drifted apart for
                // months (register CVC-10).
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

    /// ⚠️ Single source (WF-CU10). This switch used to be open-coded here AND verbatim in
    /// `WorkflowCanvasState.nodeColor(for:)`, which fed the edge gradient — so the two had to agree
    /// for an edge to match the node it leaves. Both are now `WorkflowNodeKind.identityColor(in:)`.
    private var profileColor: Color { node.kind.identityColor(in: theme) }

    /// Composed by `WorkflowCanvasState` so the wording and the edge counts are testable.
    private var accessibilityDescription: String {
        canvasState.accessibilityDescription(for: node, runStatusLabel: runStatus?.label)
    }

    /// The card's VISIBLE subtitle.
    ///
    /// ⚠️ Deliberately separate from `WorkflowCanvasState.accessibilityKindLabel`: an Action node's
    /// subtitle is its configured TOOL name, which is data and must NOT be translated.
    ///
    /// ⚠️ `String(localized:)` on every literal (WF-CU8, widened). This feeds `subtitle:`, rendered
    /// by `Text(subtitle)` — the non-localizing `StringProtocol` overload — so "Router" / "Gate" /
    /// "Trigger" / "Bot" were printed untranslated on every node card inside otherwise translated
    /// chrome. Same defect as the accessibility labels, and higher user impact because it is on
    /// screen rather than spoken. `pType.rawValue` was doubly wrong here: a persistence token used
    /// as a display string.
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

    /// Whether this node is a valid drop target for the current edge drag.
    /// ⚠️ Asks the SAME predicate `addEdge` will use, rather than only excluding the source node.
    /// This highlight used to be the FULL "drop here" treatment for every valid node on the
    /// canvas — while the drop itself only lands within `inputPortHitRadius` of a port. It now
    /// drives the WEAK tier (visible port, colored ring — "you could connect here"); the full
    /// pulse belongs to `isPrimaryDropTarget`.
    private var isCompatibleDropTarget: Bool {
        guard let drag = canvasState.edgeDragState else { return false }
        return canvasState.edgeRefusalReason(
            sourceNodeID: drag.sourceNodeID,
            targetNodeID: node.id,
            sourcePortLabel: drag.sourcePortLabel
        ) == nil
    }

    /// The ONE node the drop would actually land on right now (register CVV-2): valid AND the
    /// nearest input port within the accept radius of the live drag point. This is what earns
    /// the full pulse/scale/glow — the same test `onDragEnded` runs at release, so the pulse can
    /// no longer promise a connection the 20pt radius will refuse. Tracks the pointer live:
    /// `edgeDragState.currentPoint` is written on every drag tick and the state is `@Observable`.
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
                // ⚠️ Decorative traffic lights, NOT identity (WF-CU10). Two were raw `.red` and
                // `.yellow` — the same literals the Gate and Router kinds used — so every Code node
                // carried a 6pt Gate-red dot that read as a status signal.
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
            // ⚠️ ORDER SWAPPED (WF-CU10). Chained `.background` calls stack progressively FURTHER
            // BACK, and `theme.controlBackground` is opaque in every theme — so the tint, declared
            // second, was painted behind an opaque fill and never rendered at all.
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
                    .font(.system(.caption2))
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
