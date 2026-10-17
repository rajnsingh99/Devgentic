// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PromptDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Displays a prompt's editable details in the main content area.
//
//  2026-04-21 — overhaul:
//    · dirty-aware Save (disabled when buffer matches loaded prompt)
//    · unsaved-changes guard on back navigation
//    · toast feedback for save success/failure
//    · category pill chips (replaces cramped 9-segment picker)
//    · interactive tags editor with chips preview
//    · detected template placeholders footer
//    · metadata footer (created · last used · user/built-in)
//    · overflow menu (Copy · Duplicate · Delete) — separates destructive action
//    · focus rings + accessibility labels on plain TextFields
//

import SwiftUI
import AppKit

struct PromptDetailContainerView: View {

    let promptID: UUID

    @State private var editVM = PromptEditViewModel()
    @State private var showingDeleteAlert: Bool = false
    @State private var showingBackAlert: Bool = false
    @State private var showingConflictAlert: Bool = false
    @State private var incomingExternalPrompt: DevPrompt? = nil
    @State private var isInitialLoad: Bool = true
    @State private var isMenuHovered: Bool = false

    @Environment(MainViewRouter.self) private var router
    @Environment(ToastManager.self) private var toastManager
    @Environment(ChatInputViewModel.self) private var chatInputVM
    @Environment(\.appTheme) private var theme

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case text
        case tagInput
    }

    private var prompt: DevPrompt? {
        PromptService.shared.prompts.first(where: { $0.id == promptID })
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar(
                title: editVM.title.isEmpty ? "Prompt" : editVM.title,
                icon: "text.quote",
                onBack: handleBackTap
            ) {
                actionButtons
            }

            content
        }
        .onAppear {
            loadPrompt()
            // Settle isInitialLoad after the first frame so SwiftData hydration
            // gets a moment to populate `PromptService.shared.prompts`. Prevents
            // a "Prompt Not Found" flash if the view is created before init.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                isInitialLoad = false
            }
        }
        .onChange(of: promptID) {
            isInitialLoad = true
            loadPrompt()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                isInitialLoad = false
            }
        }
        .onChange(of: prompt) { _, newValue in
            handleExternalPromptChange(newValue)
        }
        .alert("Delete Prompt?", isPresented: $showingDeleteAlert, presenting: prompt) { p in
            Button("Delete", role: .destructive) {
                _ = editVM.deleteLoadedPrompt()
                toastManager.show("Deleted “\(p.title)”", style: .success)
                router.returnToChat()
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("“\(p.title)” will be permanently removed.")
        }
        .confirmationDialog(
            "Unsaved changes",
            isPresented: $showingBackAlert,
            titleVisibility: .visible
        ) {
            Button("Save & Go Back") {
                if performSave(silent: false) {
                    router.goBack()
                }
            }
            Button("Discard Changes", role: .destructive) {
                router.goBack()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have unsaved edits to this prompt.")
        }
        .alert(
            "Prompt modified elsewhere",
            isPresented: $showingConflictAlert,
            presenting: incomingExternalPrompt
        ) { remote in
            Button("Reload from Library") {
                editVM.loadDraft(from: remote)
                toastManager.show("Reloaded from library", style: .success)
                incomingExternalPrompt = nil
            }
            Button("Keep My Changes", role: .cancel) {
                incomingExternalPrompt = nil
            }
        } message: { _ in
            Text("This prompt was updated outside this editor. Your unsaved edits differ from the latest version in the library.")
        }
    }

    // MARK: - Content Switching

    @ViewBuilder
    private var content: some View {
        if prompt != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    titleSection
                    categorySection
                    promptTextSection
                    tagsSection
                    metadataFooter
                }
                .padding(24)
                .frame(maxWidth: ViewLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        } else if isInitialLoad {
            loadingView
        } else {
            notFoundView
        }
    }

    /// Shown when the prompt with our `promptID` is gone from the library
    /// (deleted externally). If the user had unsaved edits in the buffer,
    /// offers a "Save as new prompt" recovery path so their work isn't lost.
    /// Otherwise falls back to the standard `ContentNotFoundView`.
    @ViewBuilder
    private var notFoundView: some View {
        if editVM.canSave && editVM.originalPrompt != nil {
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.warningColor.opacity(0.9), theme.warningColor.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 6) {
                    Text("Prompt Deleted Elsewhere")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("The original was removed while you were editing. Save your changes as a new prompt, or discard them.")
                        .font(.system(.callout))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                HStack(spacing: 10) {
                    Button {
                        router.returnToChat()
                    } label: {
                        Text("Discard")
                            .font(theme.fontSubheadline.weight(.medium))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .foregroundColor(theme.secondaryText)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(theme.surfaceOverlay)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        recreateFromBuffer()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.rectangle")
                                .font(.system(.subheadline, weight: .semibold))
                            Text("Save as New Prompt")
                                .font(theme.fontSubheadline.weight(.medium))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(theme.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Prompt deleted externally — save your unsaved changes as a new prompt or discard them.")
        } else {
            ContentNotFoundView(
                icon: "doc.text.magnifyingglass",
                title: "Prompt Not Found",
                subtitle: "This prompt may have been deleted. Use the back button to return."
            )
        }
    }

    /// Writes the current edit buffer as a fresh prompt (generates a new UUID),
    /// then navigates to the new prompt's detail view so edits continue without
    /// interruption.
    private func recreateFromBuffer() {
        let tags = editVM.tagsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let recreated = DevPrompt(
            title: editVM.title,
            text: editVM.text,
            category: editVM.category.rawValue,
            isUserDefined: true,
            tags: tags.isEmpty ? nil : tags,
            isPinned: editVM.isPinned
        )
        if PromptService.shared.addPrompt(recreated) {
            toastManager.show("Saved as new prompt", style: .success)
            router.navigateToPrompt(recreated.id)
        } else {
            toastManager.show("Couldn't save — try again", style: .error)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("Loading prompt…")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading prompt")
    }

    // MARK: - Title

    private var titleSection: some View {
        fieldSection(label: "Title") {
            TextField("Enter a clear and concise title", text: $editVM.title)
                .font(.system(.title3, weight: .medium))
                .textFieldStyle(.plain)
                .foregroundColor(theme.primaryText)
                .focused($focusedField, equals: .title)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(fieldBackground(focused: focusedField == .title))
                .accessibilityLabel("Prompt title")
        }
    }

    // MARK: - Category (pill chips)

    private var categorySection: some View {
        fieldSection(label: "Category") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PromptCategory.allCases) { cat in
                        CategoryChip(
                            title: cat.localizedTitle,
                            isSelected: editVM.category == cat,
                            action: { editVM.category = cat }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityLabel("Category picker")
            .accessibilityValue(editVM.category.displayName)
        }
    }

    // MARK: - Prompt Text

    private var promptTextSection: some View {
        fieldSection(label: "Prompt Text") {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $editVM.text)
                    .font(theme.fontBody)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .text)
                    .padding(12)
                    .frame(minHeight: 250)
                    .background(fieldBackground(focused: focusedField == .text))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.dividerColor.opacity(0.5), lineWidth: 0.5)
                    )
                    .accessibilityLabel("Prompt text body")

                if !detectedPlaceholders.isEmpty {
                    placeholderHint
                }
            }
        }
    }

    /// Finds `[bracketed]` and `{{mustache}}` placeholders so authors can
    /// spot variables at a glance. Empty `[]` or single-word noise is ignored.
    private var detectedPlaceholders: [String] {
        let patterns = [#"\[[^\[\]]{2,60}\]"#, #"\{\{[^{}]{1,60}\}\}"#]
        var found: Set<String> = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = editVM.text as NSString
            let matches = regex.matches(in: editVM.text, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                found.insert(ns.substring(with: m.range))
            }
        }
        return Array(found).sorted()
    }

    private var placeholderHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "curlybraces")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(detectedPlaceholders.count) template placeholder\(detectedPlaceholders.count == 1 ? "" : "s") detected")
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                FlowingChipsRow(items: detectedPlaceholders) { placeholder in
                    Text(placeholder)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundColor(theme.accentColor)
                        .background(
                            Capsule().fill(theme.accentColor.opacity(0.12))
                        )
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.accentColor.opacity(0.06))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Tags (chips + add-tag input)

    private var tagsSection: some View {
        fieldSection(label: "Tags") {
            VStack(alignment: .leading, spacing: 10) {
                if !parsedTags.isEmpty {
                    FlowingChipsRow(items: parsedTags) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.system(.caption, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            Button {
                                removeTag(tag)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(theme.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(theme.surfaceOverlay)
                        )
                        .overlay(
                            Capsule().stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                        )
                    }
                }

                TextField("Comma-separated — e.g. coding, python, review", text: $editVM.tagsString)
                    .font(theme.fontBody)
                    .textFieldStyle(.plain)
                    .foregroundColor(theme.primaryText)
                    .focused($focusedField, equals: .tagInput)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldBackground(focused: focusedField == .tagInput))
                    .help("Use commas to separate multiple tags.")
                    .accessibilityLabel("Tags, comma separated")
            }
        }
    }

    private var parsedTags: [String] {
        editVM.tagsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func removeTag(_ tag: String) {
        editVM.tagsString = parsedTags.filter { $0 != tag }.joined(separator: ", ")
    }

    // MARK: - Metadata Footer

    private var metadataFooter: some View {
        HStack(spacing: 16) {
            metadataItem(icon: "calendar", label: "Created", value: relativeString(from: prompt?.createdAt))
            metadataItem(icon: "clock.arrow.circlepath", label: "Last used", value: relativeString(from: prompt?.lastUsedAt, fallback: "Never"))
            metadataItem(
                icon: prompt?.isUserDefined == true ? "person.crop.circle" : "sparkles",
                label: "Source",
                value: prompt?.isUserDefined == true ? "User prompt" : "Built-in"
            )
            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func metadataItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(theme.tertiaryText)
                Text(value)
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
        }
    }

    private func relativeString(from date: Date?, fallback: String = "—") -> String {
        guard let date else { return fallback }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Field Section Helper

    @ViewBuilder
    private func fieldSection<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .textCase(.uppercase)
                .tracking(0.5)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func fieldBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.surfaceOverlay)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        focused ? theme.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: focused ? 1 : 0
                    )
            )
            .animation(.easeInOut(duration: 0.15), value: focused)
    }

    // MARK: - Island Bar Actions

    private var actionButtons: some View {
        HStack(spacing: 6) {
            IslandPillButton(
                title: "Save",
                style: .primary,
                accessibilityLabel: "Save prompt",
                keyboardShortcut: KeyboardShortcut("s", modifiers: .command)
            ) {
                _ = performSave(silent: false)
            }
            .disabled(!editVM.canSave || !editVM.isDirty)

            Menu {
                Button {
                    useInChat()
                } label: {
                    Label("Use in Chat", systemImage: "arrow.up.forward.app")
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(prompt == nil || editVM.text.isEmpty)

                Button {
                    copyPromptText()
                } label: {
                    Label("Copy Prompt Text", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(editVM.text.isEmpty)

                Button {
                    duplicatePrompt()
                } label: {
                    Label("Duplicate", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(prompt == nil)

                Button {
                    editVM.isPinned.toggle()
                } label: {
                    Label(editVM.isPinned ? "Unpin" : "Pin", systemImage: editVM.isPinned ? "pin.slash" : "pin")
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(prompt == nil)

                Divider()

                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(prompt == nil || !(prompt?.isUserDefined ?? true))
                .help((prompt?.isUserDefined ?? true) ? "Delete prompt" : "Built-in prompts can't be deleted")
            } label: {
                VStack(spacing: 2.5) {
                    Circle().frame(width: 3.0, height: 3.0)
                    Circle().frame(width: 3.0, height: 3.0)
                    Circle().frame(width: 3.0, height: 3.0)
                }
                .foregroundColor(isMenuHovered ? theme.primaryText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(isMenuHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                )
                .contentShape(Circle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .pointingHandCursor()
            .onHover { isMenuHovered = $0 }
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .animation(.easeInOut(duration: 0.15), value: editVM.isDirty)
    }

    // MARK: - Actions

    private func handleBackTap() {
        if editVM.isDirty {
            showingBackAlert = true
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                router.goBack()
            }
        }
    }

    @discardableResult
    private func performSave(silent: Bool) -> Bool {
        guard editVM.canSave else { return false }
        if editVM.save() != nil {
            if !silent {
                toastManager.show("Saved", style: .success)
            }
            return true
        } else {
            let message = PromptService.shared.loadState.errorMessage ?? "Couldn't save prompt"
            toastManager.show(message, style: .error)
            return false
        }
    }

    private func copyPromptText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(editVM.text, forType: .string)
        toastManager.show("Prompt text copied", style: .success)
    }

    /// Stages the prompt text into the chat input (via `ChatInputViewModel`)
    /// and navigates back to the chat view. If the user has unsaved edits,
    /// those are staged — not the library's saved copy — because the buffer
    /// is what the user is actively reading. Usage is still recorded.
    private func useInChat() {
        guard let source = prompt else { return }
        // Compose a prompt object reflecting the current buffer so any
        // uncommitted edits flow into chat. Falls back to the stored prompt
        // for metadata (id, isUserDefined, etc.).
        var stagingCopy = source
        stagingCopy.text = editVM.text
        let staged = chatInputVM.stagePromptFromLibrary(stagingCopy)
        if staged {
            toastManager.show("Ready in chat input", style: .success)
            router.returnToChat()
        } else {
            toastManager.show("Prompt text is empty — nothing to insert", style: .error)
        }
    }

    private func duplicatePrompt() {
        guard let source = prompt else { return }
        let copy = DevPrompt(
            title: source.title + " (Copy)",
            text: source.text,
            category: source.category,
            isUserDefined: true,
            tags: source.tags,
            isPinned: false
        )
        if PromptService.shared.addPrompt(copy) {
            toastManager.show("Duplicated to “\(copy.title)”", style: .success)
            router.navigateToPrompt(copy.id)
        } else {
            toastManager.show("Couldn't duplicate prompt", style: .error)
        }
    }

    private func loadPrompt() {
        if let prompt = prompt {
            editVM.loadDraft(from: prompt)
            // Count opening-for-edit as a usage so Recently-Used sort
            // reflects reading as well as chat insertion. Previously the
            // sort only surfaced prompts the user actually sent to chat,
            // which under-counted reference prompts people skim often.
            PromptService.shared.recordUsage(of: prompt)
            // 50ms lets the content view finish its first layout so the
            // TextField's focus target is mounted — any shorter and the
            // focus set silently fails after a navigation transition.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                focusedField = .title
            }
        }
    }

    // MARK: - External update reconciliation

    /// Called from `.onChange(of: prompt)` whenever `PromptService.shared.prompts`
    /// emits a new snapshot for our current ID. Three outcomes:
    ///
    /// 1. **Deleted elsewhere** (`newValue == nil`) — the view falls through to
    ///    `ContentNotFoundView` automatically; nothing to do here.
    /// 2. **Matches our `originalPrompt`** — either this *was* our own save
    ///    (which already synced `originalPrompt`) or a redundant write;
    ///    silently ignore.
    /// 3. **Diverged from `originalPrompt`** — someone else edited the prompt.
    ///    If our buffer is clean, silently reload. If it's dirty, ask the
    ///    user whether to keep local changes or accept the remote version.
    private func handleExternalPromptChange(_ newValue: DevPrompt?) {
        guard let newValue else { return }
        guard let original = editVM.originalPrompt else {
            // No buffer loaded yet — initial load path handles it.
            return
        }
        if newValue == original {
            return  // No-op or our own save.
        }
        if editVM.isDirty {
            incomingExternalPrompt = newValue
            showingConflictAlert = true
        } else {
            // Clean buffer: silently absorb the remote change.
            editVM.loadDraft(from: newValue)
        }
    }
}

// MARK: - PromptLoadState error message

private extension PromptLoadState {
    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

// MARK: - Flowing chips (auto-wraps to next line)

/// Minimal wrapping row used for placeholders and tag chips. SwiftUI's HStack
/// doesn't wrap, so we drive a custom `Layout` — cheap since the inputs are
/// typically <20 items.
private struct FlowingChipsRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        WrappingHStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

/// Tiny `Layout` that places subviews left-to-right, wrapping to the next
/// line when the cursor would exceed the proposed width.
private struct WrappingHStack: Layout {

    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX + size.width > maxWidth, cursorX > 0 {
                cursorY += lineHeight + spacing
                cursorX = 0
                lineHeight = 0
            }
            cursorX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxRowWidth = max(maxRowWidth, cursorX)
        }
        return CGSize(width: maxRowWidth, height: cursorY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var cursorX: CGFloat = bounds.minX
        var cursorY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX + size.width > bounds.minX + maxWidth, cursorX > bounds.minX {
                cursorY += lineHeight + spacing
                cursorX = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: cursorX, y: cursorY), proposal: ProposedViewSize(size))
            cursorX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
