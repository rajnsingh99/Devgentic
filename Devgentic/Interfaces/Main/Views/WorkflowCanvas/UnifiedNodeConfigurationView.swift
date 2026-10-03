// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UnifiedNodeConfigurationView.swift
//  Devgentic
//
//  Unified master-detail split-view configuration window for workflow canvas nodes.
//  Inspired by the Model Catalog window design:
//  - Master Sidebar: list of all attached canvas nodes with search, category filters, and status.
//  - Detail View: dedicated inline rename bar, in-settings search bar, and respective node configuration.
//

import SwiftUI

enum NodeCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case agents = "Agents"
    case logic = "Logic"
    case gates = "Gates"
    case code = "Code"
    case tools = "Tools"

    var id: String { rawValue }

    func matches(node: WorkflowNode) -> Bool {
        switch self {
        case .all:
            return true
        case .agents:
            if case .profile = node.kind { return true }
            return false
        case .logic:
            if case .condition = node.kind { return true }
            return false
        case .gates:
            if case .gate = node.kind { return true }
            return false
        case .code:
            if case .code = node.kind { return true }
            return false
        case .tools:
            if case .action = node.kind { return true }
            return false
        }
    }
}

struct UnifiedNodeConfigurationView: View {

    @Bindable var canvasState: WorkflowCanvasState
    @State private var selectedNodeID: UUID
    let profileService: BackendProfileService
    let toastManager: ToastManager
    let router: MainViewRouter
    let themeManager: ThemeManager
    let onClose: () -> Void

    @Environment(\.closeNodeInspector) private var closeInspector
    @Environment(\.appTheme) private var theme

    @State private var nodeSearchText: String = ""
    @State private var selectedCategory: NodeCategoryFilter = .all
    @State private var isRenaming: Bool = false
    @State private var draftNodeName: String = ""

    init(
        canvasState: WorkflowCanvasState,
        initialSelectedNodeID: UUID,
        profileService: BackendProfileService,
        toastManager: ToastManager,
        router: MainViewRouter,
        themeManager: ThemeManager,
        onClose: @escaping () -> Void
    ) {
        self.canvasState = canvasState
        self._selectedNodeID = State(initialValue: initialSelectedNodeID)
        self.profileService = profileService
        self.toastManager = toastManager
        self.router = router
        self.themeManager = themeManager
        self.onClose = onClose
    }

    private var activeNode: WorkflowNode? {
        canvasState.nodes.first(where: { $0.id == selectedNodeID }) ?? canvasState.nodes.first
    }

    private var filteredNodes: [WorkflowNode] {
        var result = canvasState.nodes
        if selectedCategory != .all {
            result = result.filter { selectedCategory.matches(node: $0) }
        }
        let query = nodeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter {
                $0.displayName.lowercased().contains(query)
                || nodeRoleTitle(for: $0).lowercased().contains(query)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Window Header Bar
            windowHeader

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            // Split View: Sidebar + Detail Configuration Pane
            HSplitView {
                // Left Pane: Attached Nodes Sidebar
                sidebarPane
                    .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)

                // Right Pane: Detail Node Configuration
                detailPane
                    .frame(minWidth: 650)
            }
        }
        .frame(minWidth: 1040, idealWidth: 1120, minHeight: 680, idealHeight: 760)
        .background(theme.primaryBackground)
        .onAppear {
            if let node = activeNode {
                draftNodeName = node.displayName
            }
        }
    }

    // MARK: - Window Header Bar

    private var windowHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "slider.horizontal.2.square.on.square")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundStyle(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text("Node Configuration")
                        .font(theme.fontHeadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)

                    Text("\(canvasState.nodes.count) Attached Nodes")
                        .font(theme.fontCaption2.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(theme.surfaceOverlay)
                        )
                }

                Text("Configure parameters, prompts, and routing for canvas nodes")
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            canvasStatusPill

            TactileIconButton(icon: "xmark", tooltip: "Close", size: .compact) {
                closeInspector()
                onClose()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(0.45))
    }

    private var canvasStatusInfo: (text: String, color: Color) {
        if !canvasState.validationErrors.isEmpty {
            let count = canvasState.validationErrors.count
            let label = count == 1 ? "Canvas Error" : "\(count) Canvas Errors"
            return (label, theme.errorColor)
        } else if !canvasState.validationWarnings.isEmpty {
            let count = canvasState.validationWarnings.count
            let label = count == 1 ? "Canvas Warning" : "\(count) Canvas Warnings"
            return (label, theme.warningColor)
        } else {
            return ("Canvas Ready", Color.green)
        }
    }

    private var canvasStatusPill: some View {
        let (statusText, statusColor) = canvasStatusInfo
        return Button {
            if !canvasState.validationIssues.isEmpty {
                canvasState.showValidationPanel.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(theme.fontCaption2.weight(.medium))
                    .foregroundStyle(canvasState.validationIssues.isEmpty ? theme.secondaryText : statusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(theme.surfaceOverlay)
            )
            .overlay(
                Capsule().stroke(statusColor.opacity(canvasState.validationIssues.isEmpty ? 0 : 0.35), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(!canvasState.validationIssues.isEmpty ? "Toggle validation issues panel" : "All canvas nodes and connections are ready")
    }

    // MARK: - Left Pane: Sidebar

    private var sidebarPane: some View {
        VStack(spacing: 0) {
            // Search & Category Filters
            VStack(spacing: 8) {
                // Search Field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(theme.fontCaption2.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                    TextField(
                        "",
                        text: $nodeSearchText,
                        prompt: Text("Filter nodes...").foregroundColor(theme.placeholderText)
                    )
                    .textFieldStyle(.plain)
                    .font(theme.fontFootnote)
                    .foregroundStyle(theme.primaryText)

                    if !nodeSearchText.isEmpty {
                        Button {
                            nodeSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(theme.fontCaption2)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.75)
                )

                // Category Quick Filter Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(NodeCategoryFilter.allCases) { category in
                            categoryFilterPill(category)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            // Node List
            ScrollView {
                LazyVStack(spacing: 4) {
                    if filteredNodes.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "square.dashed")
                                .font(theme.fontTitle2)
                                .foregroundStyle(theme.tertiaryText)
                            Text("No nodes match filter")
                                .font(theme.fontCaption2)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.vertical, 32)
                    } else {
                        ForEach(filteredNodes) { node in
                            nodeSidebarRow(node: node)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            // Sidebar Footer
            HStack {
                Text("Double-tap node on canvas to jump")
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.secondaryBackground.opacity(0.3))
        }
        .background(theme.secondaryBackground.opacity(0.4))
    }

    private func categoryFilterPill(_ category: NodeCategoryFilter) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            Text(category.rawValue)
                .font(theme.fontCaption2.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.accentColor : theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func nodeSidebarRow(node: WorkflowNode) -> some View {
        let isSelected = node.id == selectedNodeID
        let roleColor = node.kind.identityColor(in: theme)

        return Button {
            switchToNode(node.id)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(roleColor.opacity(isSelected ? 0.22 : 0.12))
                        .frame(width: 28, height: 28)
                    nodeIconView(for: node, size: 15)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.displayName)
                        .font(theme.fontFootnote.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? theme.primaryText : theme.primaryText.opacity(0.9))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(nodeRoleTitle(for: node))
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Spacer()

                if isSelected {
                    Circle()
                        .fill(theme.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.surfaceOverlayStrong : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? theme.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Right Pane: Detail

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let node = activeNode {
                // A. Dedicated Edit View (Rename, Role Badge, Port Info)
                dedicatedEditBar(for: node)

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                // B. Active Inspector Content
                inspectorContentView(for: node)

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                // C. Detail Footer Navigation
                detailFooter
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.dashed")
                        .font(theme.fontLargeTitle)
                        .foregroundStyle(theme.tertiaryText)
                    Text("Select a node from the sidebar to configure.")
                        .font(theme.fontSubheadline)
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.primaryBackground)
    }

    // MARK: - A. Dedicated Edit View

    private func dedicatedEditBar(for node: WorkflowNode) -> some View {
        let roleColor = node.kind.identityColor(in: theme)

        return HStack(spacing: 14) {
            // Large Node Icon Badge
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(roleColor.opacity(0.18))
                    .frame(width: 40, height: 40)
                nodeIconView(for: node, size: 22)
            }

            VStack(alignment: .leading, spacing: 3) {
                // Name Row: View vs Inline Edit
                if isRenaming {
                    HStack(spacing: 8) {
                        TextField(
                            "",
                            text: $draftNodeName,
                            prompt: Text("Node name").foregroundColor(theme.placeholderText)
                        )
                        .textFieldStyle(.plain)
                        .font(theme.fontHeadline.weight(.bold))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(theme.accentColor, lineWidth: 1.5)
                        )
                        .onSubmit {
                            saveRename(node: node)
                        }

                        TactileButton(title: "Save", variant: .primary, size: .compact) {
                            saveRename(node: node)
                        }

                        TactileButton(title: "Cancel", variant: .subtle, size: .compact) {
                            isRenaming = false
                            draftNodeName = node.displayName
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(node.displayName)
                            .font(theme.fontHeadline.weight(.bold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)

                        Text(nodeRoleTitle(for: node))
                            .font(theme.fontCaption2.weight(.bold))
                            .foregroundStyle(roleColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(roleColor.opacity(0.12))
                            )

                        TactileIconButton(
                            icon: "pencil",
                            tooltip: "Rename node",
                            accessibilityLabel: "Rename node",
                            size: .compact
                        ) {
                            draftNodeName = node.displayName
                            isRenaming = true
                        }
                    }
                }

                // Subtitle: Ports & Node ID
                HStack(spacing: 6) {
                    Text(nodePortSummary(for: node))
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.secondaryText)

                    Text("•")
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.tertiaryText)

                    Text("ID: \(node.id.uuidString.prefix(8))")
                        .font(theme.fontCaption2.monospaced())
                        .foregroundStyle(theme.tertiaryText)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.secondaryBackground.opacity(0.35))
    }

    // MARK: - Node Icon View Bridge

    @ViewBuilder
    private func nodeIconView(for node: WorkflowNode, size: CGFloat) -> some View {
        let roleColor = node.kind.identityColor(in: theme)
        switch node.kind {
        case .profile(_, .agent):
            AgentRobotIcon(size: size, color: roleColor, isFilled: true)
        case .profile(_, let pType):
            ProfileTypeIcon(type: pType, size: size, color: roleColor, isFilled: true)
        default:
            Image(systemName: nodeIconName(for: node))
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(roleColor)
        }
    }

    // MARK: - Inspector Content Area

    @ViewBuilder
    private func inspectorContentView(for node: WorkflowNode) -> some View {
        switch node.kind {
        case .condition:
            ConditionNodeInspectorView(
                node: bindingForNode(node.id),
                showsHeader: false
            )
            .id(node.id)
        case .code:
            CodeNodeInspectorView(
                node: bindingForNode(node.id),
                showsHeader: false
            )
            .id(node.id)
        case .gate:
            GateNodeInspectorView(
                node: bindingForNode(node.id),
                showsHeader: false
            )
            .id(node.id)
        case .action:
            ActionNodeInspectorView(
                node: bindingForNode(node.id),
                availableVariables: canvasState.knownVariableNames,
                showsHeader: false
            )
            .id(node.id)
        case .profile:
            ProfileNodeInspectorView(
                node: bindingForNode(node.id),
                profile: profileService.profiles.first(where: { $0.id == node.profileID }),
                endCoalescingRun: { canvasState.endUndoCoalescingRun() },
                showsHeader: false
            )
            .id(node.id)
            .environment(profileService)
            .environment(toastManager)
            .environment(router)
            .environment(themeManager)
        default:
            VStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(theme.fontLargeTitle)
                    .foregroundStyle(theme.secondaryText)
                Text("This node kind has no configurable parameters.")
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - D. Detail Footer

    private var detailFooter: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Changes applied live to canvas")
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    selectPreviousNode()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(theme.fontCaption2.weight(.bold))
                        Text("Previous")
                            .font(theme.fontCaption2.weight(.medium))
                    }
                    .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(isFirstNode)

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(width: 1, height: 12)

                Button {
                    selectNextNode()
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                            .font(theme.fontCaption2.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(theme.fontCaption2.weight(.bold))
                    }
                    .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(isLastNode)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(0.35))
    }

    // MARK: - Actions & Helpers

    private func bindingForNode(_ nodeID: UUID) -> Binding<WorkflowNode> {
        Binding(
            get: {
                canvasState.nodes.first(where: { $0.id == nodeID })
                    ?? WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Missing Node")
            },
            set: { newValue in
                canvasState.replaceNode(id: nodeID, with: newValue)
            }
        )
    }

    private func switchToNode(_ id: UUID) {
        NodeInspectorPendingCommit.shared.commitAndClear()
        selectedNodeID = id
        canvasState.selectedNodeID = id
        canvasState.targetConfigNode = canvasState.nodes.first(where: { $0.id == id })
        if let node = canvasState.nodes.first(where: { $0.id == id }) {
            draftNodeName = node.displayName
        }
        isRenaming = false
    }

    private func saveRename(node: WorkflowNode) {
        let trimmed = draftNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var updated = node
            updated.displayName = trimmed
            canvasState.replaceNode(id: node.id, with: updated)
        }
        isRenaming = false
    }

    private var isFirstNode: Bool {
        guard let idx = canvasState.nodes.firstIndex(where: { $0.id == selectedNodeID }) else { return true }
        return idx == 0
    }

    private var isLastNode: Bool {
        guard let idx = canvasState.nodes.firstIndex(where: { $0.id == selectedNodeID }) else { return true }
        return idx == canvasState.nodes.count - 1
    }

    private func selectPreviousNode() {
        guard let idx = canvasState.nodes.firstIndex(where: { $0.id == selectedNodeID }), idx > 0 else { return }
        switchToNode(canvasState.nodes[idx - 1].id)
    }

    private func selectNextNode() {
        guard let idx = canvasState.nodes.firstIndex(where: { $0.id == selectedNodeID }), idx < canvasState.nodes.count - 1 else { return }
        switchToNode(canvasState.nodes[idx + 1].id)
    }

    private func nodeIconName(for node: WorkflowNode) -> String {
        switch node.kind {
        case .profile(_, let pType): return pType.iconName
        case .condition: return "arrow.triangle.branch"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .gate: return "hand.raised"
        case .trigger: return "bolt"
        case .action: return "bolt.horizontal.fill"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    private func nodeRoleTitle(for node: WorkflowNode) -> String {
        switch node.kind {
        case .profile(_, let pType): return pType.localizedTitleString
        case .condition: return "Router"
        case .code: return "Code / Transform"
        case .gate: return "HITL Gate"
        case .trigger: return "Trigger"
        case .action: return "Action"
        case .unsupported: return "Unsupported"
        }
    }

    private func nodePortSummary(for node: WorkflowNode) -> String {
        switch node.kind {
        case .gate(let config):
            let count = config.options.count
            return "1 input • \(count) option port\(count == 1 ? "" : "s")"
        case .condition(let config):
            let count = config.rules.count
            return "1 input • \(count) rule port\(count == 1 ? "" : "s")"
        default:
            return "1 input • 1 output port"
        }
    }
}
