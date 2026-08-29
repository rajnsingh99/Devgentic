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
                .onAppear {
                    guard shouldPulse else { return }
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
    private var shouldPulse: Bool {
        runIsLive && runStatus == .running
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
                // ⚠️ The label is an OVERLAY, not a sibling in the layout.
                //
                // It used to sit in an `HStack` with the port, and the whole stack was centred at
                // `node.x + width + 12`. So the port CIRCLE was pushed right by half the label's
                // width while `outputPortPosition` — which every edge anchors to — kept returning
                // `node.x + width`. The drawn port and the edge endpoint disagreed by
                // `12 + labelWidth/2 + 1`: about 13pt on the default port, 23pt on `error`, 33pt on
                // a long Condition rule. Since the `error` port made profile/action/code/loop nodes
                // multi-port, that also left a node's two circles 10pt out of vertical alignment
                // with EACH OTHER, and long labels drawn on top of the node card.
                //
                // As an overlay the label cannot move the port, so any label length is safe.
                ZStack {
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
                    // Label hangs to the RIGHT of the circle without displacing it. `fixedSize`
                    // keeps it from being compressed, and the overlay is unbounded so a long
                    // Condition rule label extends outward instead of over the node card.
                    if outputPortEntries.count > 1 {
                        Text(entry.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(profileColor)
                            .fixedSize()
                            // ⚠️ Also visible whenever a run is on screen. "Which branch did it
                            // take?" is the question the canvas is uniquely able to answer, and it
                            // is unanswerable if the user has to hover each port to learn its name.
                            .opacity(isHovering || canvasState.edgeDragState != nil || runStatus != nil ? 1.0 : 0.0)
                            .alignmentGuide(.leading) { _ in 0 }
                            .offset(x: WorkflowCanvasState.portRadius + 5)
                            .allowsHitTesting(false)
                    }
                }
                // ⚠️ EXACTLY `outputPortPosition`'s answer — no `+12`. These two numbers are the
                // same point expressed twice (drawn here, anchored there); when they drifted, every
                // edge visibly stopped short of the circle it was supposed to leave.
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
            // ⚠️ `theme.shadowColor`, not `Color.black` (WF-CU10). The token exists precisely so
            // pale themes get a softer shadow — OneLight overrides it — and this card was the one
            // elevated surface on the canvas bypassing it.
            color: isSelected ? profileColor.opacity(0.35) : theme.shadowColor.opacity(isHovering ? 0.12 : 0.06),
            radius: isSelected ? 12 : (isHovering ? 6 : 3),
            x: 0, y: isSelected ? 4 : 2
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
        case .condition:          return String(localized: "Router")
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
    /// This highlight pulses, glows and scales the input port to say "drop here, this is valid" —
    /// and it used to say that for a drop that would create a cycle or duplicate an existing
    /// connection, both of which were then refused in silence. Promising a connection the canvas
    /// will refuse is worse than not highlighting at all.
    private var isCompatibleDropTarget: Bool {
        guard let drag = canvasState.edgeDragState else { return false }
        return canvasState.edgeRefusalReason(
            sourceNodeID: drag.sourceNodeID,
            targetNodeID: node.id,
            sourcePortLabel: drag.sourcePortLabel
        ) == nil
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
        // ⚠️ ONE `.background` with the tint as an `.overlay` INSIDE it (WF-CU10). Chained
        // `.background` calls stack progressively FURTHER BACK, and `theme.controlBackground` is
        // opaque in every theme — so the gradient declared as a SECOND `.background` below it was
        // painted behind an opaque fill and never rendered at all. That, not a design decision, is
        // why a border was this card's only colour.
        .background(
            WorkflowHexagon()
                .fill(theme.controlBackground)
                .overlay(
                    WorkflowHexagon().fill(
                        LinearGradient(
                            colors: [color.opacity(0.12), color.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
        )
        .overlay(
                    // ⚠️ Unselected border is a THEME token, matching what ProfileNodeCard and CodeNodeCard
            // already do. `color.opacity(0.5)` measured 1.17:1 against OneLight's `#f0f0f0` card —
            // invisible — which made selection a 0.5→1.0 opacity step of an already-invisible hue.
            // Neutral → identity colour is a change the eye can actually see; the lineWidth step
            // stays as a non-colour cue.
            WorkflowHexagon()
                .stroke(isSelected ? color : theme.surfaceOverlayStrong,
                        lineWidth: isSelected ? 2.5 : 1.5)
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
            .background(color.opacity(0.04))
            .background(theme.controlBackground)
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
        // ⚠️ ONE `.background` with the tint as an `.overlay` INSIDE it (WF-CU10). Chained
        // `.background` calls stack progressively FURTHER BACK, and `theme.controlBackground` is
        // opaque in every theme — so the gradient declared as a SECOND `.background` below it was
        // painted behind an opaque fill and never rendered at all. That, not a design decision, is
        // why a border was this card's only colour.
        .background(
            Capsule()
                .fill(theme.controlBackground)
                .overlay(
                    Capsule().fill(
                        LinearGradient(
                            colors: [color.opacity(0.15), color.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
        )
        .overlay(
            // Gate keeps its identity hue unselected — at 0.8 opacity and lineWidth 2 it clears
            // the 3:1 component bar on both light and dark cards with the new ramp.
            Capsule()
                .stroke(isSelected ? color : color.opacity(0.8), lineWidth: isSelected ? 3 : 2)
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
            // ⚠️ Was `.white` on a `.gray` chevron FILL — 3.26:1 in light, worse in dark. The title
            // is real TEXT, so it takes the 4.5:1 bar and failed in BOTH appearances (WF-CU10).
            // Fixed structurally rather than by adding a "foreground-on-fill" token: no card fills
            // a shape with the identity colour any more, so there is nothing to compute a safe
            // foreground against.
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
                .overlay(WorkflowChevron().fill(color.opacity(0.15)))
        )
        .overlay(
            // ⚠️ Was `isSelected ? .white : .clear` — a white ring on a grey chevron on a near-white
            // canvas, so a selected Trigger was indistinguishable from an unselected one. Selection
            // is a UI-state indicator (3:1 bar) and NOTHING else conveyed it here, unlike node TYPE
            // which shape + icon + label already carry three ways.
            WorkflowChevron()
                .stroke(isSelected ? color : theme.surfaceOverlayStrong,
                        lineWidth: isSelected ? 2.5 : 1.5)
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
            // ⚠️ Was `.white` on a SOLID `color` tile — 2.57:1 against systemTeal, failing even
            // the 3:1 graphical-object bar, and unfixable by the light ramp alone because the DARK
            // arm keeps systemTeal. Glyph-on-tint matches ConditionNodeCard's already-correct
            // treatment (WF-CU10).
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
        // ⚠️ ONE `.background` with the tint as an `.overlay` INSIDE it (WF-CU10). Chained
        // `.background` calls stack progressively FURTHER BACK, and `theme.controlBackground` is
        // opaque in every theme — so the gradient declared as a SECOND `.background` below it was
        // painted behind an opaque fill and never rendered at all. That, not a design decision, is
        // why a border was this card's only colour.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(color.opacity(0.06))
                )
        )
        .overlay(
                    // ⚠️ Unselected border is a THEME token, matching what ProfileNodeCard and CodeNodeCard
            // already do. `color.opacity(0.5)` measured 1.17:1 against OneLight's `#f0f0f0` card —
            // invisible — which made selection a 0.5→1.0 opacity step of an already-invisible hue.
            // Neutral → identity colour is a change the eye can actually see; the lineWidth step
            // stays as a non-colour cue.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? color : theme.surfaceOverlayStrong,
                        lineWidth: isSelected ? 2 : 1.5)
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
