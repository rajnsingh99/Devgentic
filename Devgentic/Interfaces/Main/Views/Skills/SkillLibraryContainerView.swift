// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillLibraryContainerView.swift
//  Devgentic
//
//  The Skills tab's content area: every skill in the library, and which ones this profile links.
//
//  ## Copied wholesale from `ToolLibraryContainerView`, on purpose
//
//  That view already solved this exact problem for tools, and its solution is load-bearing in ways
//  that are not obvious from the outside:
//
//    - **Route > remembered > none.** An explicit route profile always wins over the remembered one,
//      because arriving from a profile's own config is a statement about WHICH profile you are
//      configuring; silently writing to whatever was last picked here would edit a profile the user
//      did not open.
//    - **Hide, never disable.** Every mutating control is absent when there is nowhere to write —
//      "a control that appears functional with nowhere to write is worse than an absent one".
//    - **`.id(profileID)`.** Resets view state on a profile switch, so search text and scroll
//      position cannot leak across targets inside one destination.
//
//  ⚠️ Filtered to `.agent` only. `.code` reuses `AgentConfig` and persists `skillConfig`, but
//  `AgentConnect` deliberately does not load skills for it (the S0 hygiene pass made that
//  disagreement explicit rather than silent). Offering Code profiles here would let a user link
//  skills that provably never run.
//

import SwiftUI
import AppKit

struct SkillLibraryContainerView: View {

    /// Profile supplied by the route, if any. Nil when opened from the Skills rail tab.
    let routeProfileID: UUID?

    /// A skill to open on arrival, from a sidebar row that named it. Nil for a plain visit.

    @Environment(BackendProfileService.self) private var profileService
    @Environment(\.appTheme) private var theme
    @Environment(MainViewRouter.self) private var router

    @AppStorage("skillLibrary.lastProfileID") private var rememberedProfileIDRaw: String = ""
    @State private var revision = 0
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    /// Name of a just-linked skill that wants a shell this profile lacks. Nil means no offer.
    @State private var shellToolOffer: String?
    /// The skill a delete has been requested for, held while the user confirms.
    @State private var pendingDeletion: SkillSD?
    /// Folders the V6 import sweep could not read, re-read from the capture file.
    ///
    /// ⚠️ Read from the FILE rather than passed down from the sweep, and that is not laziness: after
    /// a pass the capture holds exactly what failed, and it survives relaunches. A value handed from
    /// a launch-time run would be gone the moment the user navigated away, which is precisely when
    /// they would come looking for it.
    @State private var failedImports: [SkillLibraryMigration.LegacySkillRef] = []
    @State private var isRetryingImports = false

    /// A write that failed, shown to the user rather than only logged.
    ///
    /// ⚠️⚠️ ADDED BECAUSE EVERY WRITE IN THIS VIEW FAILED SILENTLY. Link, unlink, delete and the
    /// shell grant each logged their error and returned, so a failed save left the toggle switched
    /// ON, the profile summary claiming the skill was linked, and the link simply gone after the
    /// next launch. The log line said exactly that — to a file nobody watching this screen reads.
    @State private var actionError: String?

    /// Precedence: route > remembered > none.
    private var profileID: UUID? {
        if let routeProfileID { return routeProfileID }
        guard let remembered = UUID(uuidString: rememberedProfileIDRaw),
              linkableProfiles.contains(where: { $0.id == remembered }) else { return nil }
        return remembered
    }

    /// True when there is a profile to write links into. Everything that mutates hides when false.
    private var canConfigureSkills: Bool { profileID != nil }

    /// ⚠️ `sharedProfiles`, not `profiles` — the latter includes every workflow node's private
    /// configuration, and offering those for editing here is how a picker fills with rows the user
    /// never created.
    private var linkableProfiles: [BackendProfileModel] {
        profileService.sharedProfiles.filter {
            if case .agent = $0.details { return true }
            return false
        }
    }

    /// ⚠️ Observes the STORE's revision as well as this view's own. A skill added or deleted in the
    /// sidebar pane mutates the library but not this view's `@State`, so without the store's counter the
    /// new skills never appeared while the library was open.
    private var skillsResult: Result<[SkillSD], SkillStoreError> {
        _ = revision
        _ = SkillStore.shared.revision
        return SkillStore.shared.fetchSkills()
    }

    private var skills: [SkillSD] {
        (try? skillsResult.get()) ?? []
    }

    private var filteredSkills: [SkillSD] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return skills }
        return skills.filter { skill in
            skill.name.localizedCaseInsensitiveContains(query) ||
            skill.displayName.localizedCaseInsensitiveContains(query) ||
            (skill.latestVersion?.skillDescription.localizedCaseInsensitiveContains(query) ?? false) ||
            skill.id.localizedCaseInsensitiveContains(query)
        }
    }

    /// "Storage is down" must not render as "you have no skills yet" — opposite remedies.
    private var storeFailure: String? {
        if case .failure(let error) = skillsResult { return error.localizedDescription }
        return nil
    }

    private var selections: [SkillSelection] {
        guard let profileID,
              let profile = profileService.profiles.first(where: { $0.id == profileID }),
              case .agent(let config) = profile.details else { return [] }
        return config.skillSelections ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar {
                IslandExpandableSearchHeader(
                    title: "Skills",
                    icon: "puzzlepiece",
                    text: $searchText,
                    placeholder: "Search skills…",
                    isExpanded: $isSearchExpanded,
                    accessibilityIdentifier: "skills.library.search"
                )
            } trailing: {
                HStack(spacing: 8) {
                    IslandSearchToggleButton(isExpanded: $isSearchExpanded)
                    profileSelector
                }
            }

            if let storeFailure {
                ContentNotFoundView(
                    icon: "exclamationmark.triangle",
                    title: "Skill storage is unavailable",
                    subtitle: "\(storeFailure) Your skills are still configured — do not re-import them."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        if canConfigureSkills {
                            agentScopeCard
                        } else {
                            libraryOverviewCard
                        }

                        if !failedImports.isEmpty {
                            failedImportsSection
                        }

                        if let shellToolOffer {
                            shellOfferRow(shellToolOffer)
                        }

                        skillsContentSection

                        unresolvedSection
                    }
                    .padding(.horizontal, ViewLayout.containerPadding)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                    .frame(maxWidth: ViewLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.primaryBackground)
        .onAppear {
            failedImports = SkillLibraryMigration.peekPendingImports()
        }
        // Resets @State across a profile switch within the same destination.
        .id(profileID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        .onChange(of: profileID) { _, new in
            if let new { rememberedProfileIDRaw = new.uuidString }
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete '\($0.displayName)'?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            if let pendingDeletion { Text(deletionWarning(for: pendingDeletion)) }
        }
        .alert("That did not save",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            if let actionError { Text(actionError) }
        }
    }

    // MARK: - Navigation Bar Profile Selector

    /// Pinned when arrived from a route profile (e.g. AgentConfigDetailView); switchable otherwise.
    private var profileSelector: some View {
        let isPinned = routeProfileID != nil

        return Menu {
            if !isPinned {
                Button("No profile (browse only)") { rememberedProfileIDRaw = "" }
                Divider()
            }
            ForEach(linkableProfiles) { profile in
                Button {
                    rememberedProfileIDRaw = profile.id.uuidString
                } label: {
                    if profile.id == profileID {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: canConfigureSkills ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(canConfigureSkills ? theme.accentColor : theme.secondaryText)

                Text(currentProfileName)
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundStyle(canConfigureSkills ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)

                if isPinned {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(theme.secondaryText.opacity(0.8))
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(canConfigureSkills ? theme.accentColor.opacity(0.12) : theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(canConfigureSkills ? theme.accentColor.opacity(0.35) : theme.dividerColor.opacity(0.4), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isPinned)
        .help(isPinned
              ? "Configuring '\(currentProfileName)'. Tap Back (⌘[) to return to this agent."
              : "Choose which agent profile these skills apply to")
    }

    private var currentProfileName: String {
        guard let profileID,
              let profile = linkableProfiles.first(where: { $0.id == profileID }) else {
            return "No profile"
        }
        return profile.displayName
    }

    // MARK: - Header Context Cards

    /// Contextual header when configuring skills for a specific agent profile.
    private var agentScopeCard: some View {
        let enabledCount = selections.filter { $0.isEnabled && !$0.isAwaitingRelink }.count
        let pinnedCount = selections.filter { $0.pinnedVersionID != nil }.count
        let draftCount = skills.filter(\.isDraft).count

        return SettingsCard(title: "Agent Skills Configuration", icon: "puzzlepiece", theme: theme) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Skills provide domain instructions and specialized tools that \(Text(currentProfileName).fontWeight(.semibold).foregroundStyle(theme.primaryText)) activates on demand during task execution.")
                    .font(theme.fontSubheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(enabledCount) of \(skills.count) enabled")
                            .font(theme.fontCaption.weight(.medium))
                    }
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.accentColor.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(theme.accentColor.opacity(0.25), lineWidth: 0.5))

                    if pinnedCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                            Text("\(pinnedCount) pinned")
                                .font(theme.fontCaption.weight(.medium))
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.secondaryBackground, in: Capsule())
                        .overlay(Capsule().stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5))
                    }

                    if draftCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil.and.ruler")
                                .font(.system(size: 9))
                            Text("\(draftCount) in draft")
                                .font(theme.fontCaption.weight(.medium))
                        }
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
                    }

                    Spacer()
                }
            }
            .padding(16)
        }
    }

    /// Overview header when browsing skills without an active profile.
    private var libraryOverviewCard: some View {
        let drafts = skills.filter(\.isDraft).count

        return SettingsCard(title: "Skill Library", icon: "puzzlepiece", theme: theme) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(skills.count) skill\(skills.count == 1 ? "" : "s") in your library")
                    .font(theme.fontHeadline)
                    .foregroundStyle(theme.primaryText)

                Text("Select a skill in the sidebar or from the list below to inspect or edit it. To link skills to an agent, select an agent profile in the top bar or tap \"Manage Skills\" from that agent's settings.")
                    .font(theme.fontSubheadline)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if drafts > 0 {
                    Label("\(drafts) \(drafts == 1 ? "is a draft and is" : "are drafts and are") invisible to agents until Draft Mode is turned off in skill settings.",
                          systemImage: "pencil.and.ruler")
                        .font(theme.fontCaption)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Skills List Content

    @ViewBuilder
    private var skillsContentSection: some View {
        if skills.isEmpty {
            ContentNotFoundView(
                icon: "puzzlepiece",
                title: "No skills yet",
                subtitle: "Add one from the Skills sidebar (+ New or Import) or create your own."
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else if filteredSkills.isEmpty {
            VStack(spacing: 12) {
                ContentNotFoundView(
                    icon: "magnifyingglass",
                    title: "No matching skills",
                    subtitle: "No skills match \"\(searchText)\". Check your spelling or clear the search."
                )
                GlassActionButton(title: "Clear Search", icon: "xmark", isAccent: false) {
                    searchText = ""
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            VStack(spacing: 10) {
                ForEach(filteredSkills, id: \.id) { skill in
                    SkillLibraryCardRow(
                        skill: skill,
                        selection: selections.first { $0.skillID == skill.id },
                        canConfigureSkills: canConfigureSkills,
                        currentProfileName: currentProfileName,
                        theme: theme,
                        onToggle: { enabled in setLink(skill, enabled: enabled) },
                        onSetPin: { versionID in setPin(versionID, for: skill.id) },
                        onOpenDetail: { router.navigate(to: .skillDetail(skillID: skill.id)) },
                        onDelete: { pendingDeletion = skill }
                    )
                }
            }
        }
    }

    // MARK: - Unresolved Links

    @ViewBuilder
    private var unresolvedSection: some View {
        let known = Set(skills.map(\.id))
        let dangling = selections.filter { selection in
            guard let skillID = selection.skillID else { return false }
            return !known.contains(skillID)
        }

        if canConfigureSkills, !dangling.isEmpty {
            SettingsCard(title: "Linked but Not Found", icon: "questionmark.circle", theme: theme) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These skills are linked to this profile but no longer exist in the library. You can safely remove them.")
                        .font(theme.fontCaption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(dangling) { selection in
                        HStack(spacing: 10) {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundStyle(Color.orange)
                                .font(.system(size: 13))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(selection.name)
                                    .font(theme.fontBody.weight(.medium))
                                    .foregroundStyle(theme.primaryText)
                                Text(selection.skillID ?? selection.legacyFolderPath ?? "unknown address")
                                    .font(theme.fontCodeCaption)
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }

                            Spacer(minLength: 0)

                            GlassActionButton(title: "Remove", icon: "trash", isAccent: false) {
                                if let id = selection.skillID {
                                    removeLink(skillID: id)
                                }
                            }
                        }
                        .padding(10)
                        .background(theme.secondaryBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Shell Offer Banner

    @ViewBuilder
    private func shellOfferRow(_ skillName: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("'\(skillName)' runs shell commands")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text("This profile has no shell tool, so the skill's steps that need one will fail. Adding it asks for your confirmation on every command.")
                    .font(theme.fontCaption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                GlassActionButton(title: "Add execute_shell", icon: "plus", isAccent: true) {
                    acceptShellToolOffer()
                }
                GlassActionButton(title: "Not now", icon: "xmark", isAccent: false) {
                    shellToolOffer = nil
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }

    /// Says what goes, and what else it breaks. Counted across ALL agent profiles, not just the one
    /// in context — a skill is global, so deleting it from here reaches profiles this view is not
    /// currently showing.
    private func deletionWarning(for skill: SkillSD) -> String {
        let versions = skill.versions.count
        let linked = profileService.profiles.reduce(into: 0) { count, profile in
            guard case .agent(let config) = profile.details else { return }
            if config.skillSelections?.contains(where: { $0.skillID == skill.id }) == true { count += 1 }
        }

        var message = "This removes all \(versions) version\(versions == 1 ? "" : "s") and every bundled file. Devgentic holds the only copy — there is no folder on disk to restore it from."
        if linked > 0 {
            message += " \(linked) profile\(linked == 1 ? "" : "s") link\(linked == 1 ? "s" : "") it and will report it as missing."
        }
        message += " Export it first if you might want it back."
        return message
    }

    /// Opens the skill the route named, if it is still in the library.
    ///
    /// ⚠️ Silent when the id is unknown rather than showing an error: the only way to hold a stale
    /// id here is to click a row for a skill deleted in the same moment, and an alert for that would
    /// be noise about something the user just did.

    private func confirmDeletion() {
        guard let skill = pendingDeletion else { return }
        let name = skill.displayName
        defer { pendingDeletion = nil }

        // ⚠️ The profile's LINK is deliberately left in place. `SkillResolution` reports an
        // unresolved selection as a NAMED, removable row; silently stripping links here would make
        // a skill disappear from a profile with no trace of what it used to have — which is the
        // orphan-reference failure the tools path is the cautionary tale for.
        if case .failure(let error) = SkillStore.shared.deleteSkill(id: skill.id) {
            DGLogger(category: "SkillLibrary").error("[SKILLS] Failed to delete '\(name)': \(error.localizedDescription). CONSEQUENCE: the skill is still in the library and still linked; nothing was lost.")
            actionError = "'\(name)' was not deleted: \(error.localizedDescription) It is still in the library and still linked — nothing was lost."
            return
        }
        revision += 1
    }



    /// ⚠️ Rewrites the selection IN PLACE rather than removing and re-adding it, so `isEnabled`
    /// survives. Re-adding would silently re-enable a skill the user had switched off — a pin change
    /// reading as a settings reset.
    private func setPin(_ versionID: String?, for skillID: String) {
        mutateSelections { SkillLinkEditing.pinning($0, skillID: skillID, toVersionID: versionID) }
    }

    /// Folders the migration sweep could not import — almost always a volume that was not mounted.
    @ViewBuilder
    private var failedImportsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.orange)
                Text("\(failedImports.count) skill\(failedImports.count == 1 ? "" : "s") could not be imported")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
                if isRetryingImports {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 8) {
                        GlassActionButton(title: "Try again", icon: "arrow.clockwise", isAccent: false) {
                            retryFailedImports()
                        }
                        GlassActionButton(title: "Forget", icon: "xmark", isAccent: false) {
                            forgetFailedImports()
                        }
                    }
                }
            }
            Text("These came from folders your skills used to live in. They are usually on a drive that was not mounted when Devgentic upgraded — reconnect it and try again.")
                .font(theme.fontCaption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                ForEach(failedImports, id: \.folderPath) { ref in
                    HStack(spacing: 8) {
                        Text(ref.name)
                            .font(theme.fontCaption.weight(.medium))
                            .foregroundStyle(theme.primaryText)
                        Text(ref.folderPath)
                            .font(theme.fontCodeCaption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.secondaryBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }

    /// Re-runs the sweep. Safe to press repeatedly: it reads the capture, imports what it can, and
    /// writes back only what still failed.
    private func retryFailedImports() {
        guard let container = SkillStore.shared.currentContainer else {
            DGLogger(category: "SkillLibrary").error("[SKILLS] Retry requested with no model container. CONSEQUENCE: nothing was imported and the pending list is unchanged; the next launch retries.")
            return
        }
        isRetryingImports = true
        // ⚠️ The spinner above is only reachable now that the sweep suspends. Before the ingest moved
        // off the main actor this whole method completed inside one main-actor turn, so
        // `isRetryingImports` went true and false without a frame ever being drawn between them —
        // the ProgressView was unreachable code that looked wired.
        Task { @MainActor in
            let outcome = await SkillLibraryImportSweep.run(container: container)
            failedImports = SkillLibraryMigration.peekPendingImports()
            isRetryingImports = false
            revision += 1
            report(outcome)
        }
    }

    private func report(_ outcome: SkillImportSweepOutcome) {

        if outcome.imported.isEmpty && !outcome.failed.isEmpty {
            DGLogger(category: "SkillLibrary").notice("[SKILLS] Retry imported nothing; \(outcome.failed.count) folder(s) still unreadable. CONSEQUENCE: the banner stays and the capture file is kept — the folders are still missing.")
        }
    }

    private func forgetFailedImports() {
        let count = failedImports.count
        SkillLibraryMigration.setPendingImports([])
        failedImports = []
        DGLogger(category: "SkillLibrary").notice("[SKILLS] User dismissed \(count) unimportable pre-V6 skill folder(s). CONSEQUENCE: they will NOT be retried on any future launch — the record of where they lived is gone, and re-adding them is now a manual import.")
    }

    // MARK: - Writes

    private func setLink(_ skill: SkillSD, enabled: Bool) {
        mutateSelections { current in
            enabled ? SkillLinkEditing.linking(current, toSkillID: skill.id, name: skill.name)
                    : SkillLinkEditing.unlinking(current, skillID: skill.id)
        }
        if enabled { offerShellToolIfNeeded(for: skill) }
    }

    /// Notices that the skill just linked needs a shell this profile does not have — and says so.
    ///
    /// ⚠️ THIS IS THE LINK SITE `SkillCapabilityHints` WAS EXTRACTED FOR, and until now nothing
    /// called it: the whole offer was dead code with passing tests. Importing is global (a skill
    /// belongs to the library, not a profile) while the shell tool is per-profile, so linking is the
    /// only moment both facts are in hand.
    ///
    /// ⚠️ It OFFERS. It must never append the tool itself — that auto-grant was removed because
    /// unreviewed content was deciding a capability, and a frontmatter declaration is weaker
    /// evidence than the directory listing that was already rejected as insufficient.
    private func offerShellToolIfNeeded(for skill: SkillSD) {
        guard let profileID,
              let profile = profileService.profiles.first(where: { $0.id == profileID }),
              case .agent(let config) = profile.details else {
            // ⚠️ A silent early return here means a skill that bundles scripts is linked and the
            // user is never offered the tool that runs them — indistinguishable, from the outside,
            // from the offer logic deciding against it.
            DGLogger(category: "SkillLibrary").notice("[SKILLS] No shell-tool offer evaluated for '\(skill.name)' [skill \(skill.id)]: no AGENT profile is in scope. CONSEQUENCE: if this skill bundles scripts, nothing will prompt for execute_shell — the user must add it from the Tool Library themselves.")
            return
        }

        let declared = skill.latestVersion?.allowedTools
        let hasScripts = skill.latestVersion?.hasScripts ?? false
        let alreadyHas = config.tools.contains { $0.name == "execute_shell" }

        // ⚠️ The decision is logged HERE rather than inside `SkillCapabilityHints`, which stays a
        // pure predicate — it is unit-tested directly, and a logger inside it would fire on every
        // assertion in that suite for no benefit.
        guard SkillCapabilityHints.shouldOfferShellTool(
            declaredTools: declared,
            hasScripts: hasScripts,
            profileTools: config.tools
        ) else {
            DGLogger(category: "SkillLibrary").info("[SKILLS] No shell-tool offer for '\(skill.name)' [skill \(skill.id)] on '\(profile.displayName)': declaredTools=\(declared?.joined(separator: ",") ?? "none") hasScripts=\(hasScripts) profileAlreadyHasShell=\(alreadyHas). CONSEQUENCE: no prompt is shown — either the skill needs no shell, or the profile already has execute_shell and a second copy would be unreachable from the Tool Library.")
            shellToolOffer = nil
            return
        }

        DGLogger(category: "SkillLibrary").notice("[SKILLS] OFFERING execute_shell for '\(skill.name)' [skill \(skill.id)] on '\(profile.displayName)': triggered by \(hasScripts ? "a bundled scripts/ directory" : "the skill's allowed-tools declaration") (declaredTools=\(declared?.joined(separator: ",") ?? "none")). CONSEQUENCE: this is an OFFER and grants nothing — the tool is added only if the user accepts, and it stays confirmation-gated when they do.")
        shellToolOffer = skill.name
    }

    /// Adds `execute_shell` because the USER asked, from the offer row.
    private func acceptShellToolOffer() {
        defer { shellToolOffer = nil }
        // ⚠️⚠️ READ THE ROW FRESH, NEVER `profiles[index]`. The launch sweep re-links every pre-V6
        // skill reference by writing `details` on the SwiftData row directly, and the service's
        // array is a snapshot of VALUE TYPES taken before that. Mutating the stale copy and calling
        // `saveProfile` writes the whole pre-sweep `details` back — `BackendProfileStore.saveProfile`
        // does `existing.details = snapshot.details` — so toggling one skill link would silently
        // revert the entire migration for that profile. `activateEditBuffer` already learned this
        // for three other out-of-band writers; `freshProfile` is that rule with a name.
        guard let profileID,
              let index = profileService.profiles.firstIndex(where: { $0.id == profileID }),
              let current = profileService.freshProfile(id: profileID),
              case .agent(var config) = current.details else {
            DGLogger(category: "SkillLibrary").error("[SKILLS] The user ACCEPTED the execute_shell offer but no agent profile was in scope. CONSEQUENCE: the tool was NOT granted and the offer row disappears anyway — the user believes they granted it and the next run has no shell.")
            return
        }
        guard !config.tools.contains(where: { $0.name == "execute_shell" }) else {
            DGLogger(category: "SkillLibrary").notice("[SKILLS] The user accepted the execute_shell offer for '\(profileService.profiles[index].displayName)' but the profile already has it. CONSEQUENCE: nothing was added — a second copy would render as OFF while the first is live, which is a defect this codebase has already shipped once.")
            return
        }

        config.tools.append(SkillCapabilityHints.shellTool())
        DGLogger(category: "SkillLibrary").notice("[SKILLS] GRANTED execute_shell to '\(profileService.profiles[index].displayName)' [profile \(profileID)] from the skills offer. CONSEQUENCE: this profile can now run shell commands in every conversation, not just for the skill that prompted it — each call still requires per-call confirmation, and the tool can be removed from the Tool Library.")

        // ⚠️ Same three steps as `mutateSelections`, and for the same reasons: sync the open edit
        // buffer FACET-ONLY so an editor showing this profile does not overwrite the new tool on its
        // next save, write through the service, and rebase only on success — rebasing after a failed
        // save would baseline the editor against bytes that were never written.
        if let buffer = profileService.editBuffer,
           buffer.draft.id == profileID,
           case .agent(var draftConfig) = buffer.draft.details {
            draftConfig.tools = config.tools
            buffer.draft.details = .agent(draftConfig)
        }

        // ⚠️ From the FRESH row, for the same reason as `mutateSelections`: starting from the stale
        // snapshot would write the pre-sweep `details` back and revert the skill re-link as a side
        // effect of granting a tool.
        var profile = current
        profile.details = .agent(config)
        profileService.profiles[index] = profile
        do {
            try profileService.saveProfile(profile)
            profileService.rebaseEditBuffer(to: profile)
        } catch {
            DGLogger(category: "SkillLibrary").error("[SKILLS] Failed to add execute_shell for '\(profile.displayName)': \(error.localizedDescription). CONSEQUENCE: the tool was NOT granted and the offer is dismissed — the user must add it from the Tool Library instead.")
            // ⚠️ The offer row is dismissed by the `defer` either way, so without this the click
            // simply appears to have worked and the skill's scripts then fail at run time.
            actionError = "execute_shell was not granted to '\(profile.displayName)': \(error.localizedDescription) Add it from the Tool Library instead."
        }
        revision += 1
    }

    private func removeLink(skillID: String) {
        mutateSelections { SkillLinkEditing.unlinking($0, skillID: skillID) }
    }

    /// ⚠️ Writes `skillSelections` AND leaves the legacy `skillConfig` alone.
    ///
    /// During the dual-read window `SkillResolution` prefers `skillSelections`, so writing only
    /// here is correct — this surface is the new writer. The profile editor's binding merges both,
    /// because it is still writing the legacy shape.
    ///
    /// ## The three-part commit, and why each part is load-bearing
    ///
    /// This is an OUT-OF-BAND write: it persists a profile the user may have open in the editor.
    /// `ToolLibraryContainerView` solved the same problem and this mirrors it, because skipping any
    /// part has a specific, silent failure:
    ///
    ///  1. **Sync the open edit buffer.** Without it the buffer's draft still holds the old
    ///     selections, and the editor's next Save writes that whole stale draft back over this —
    ///     the link disappears with no error. Four routes reach `.profileDetail` WITHOUT
    ///     reactivating the buffer (the composer's profile button and gauge, the advisory banner,
    ///     the QuickAccess deep link), so "they will get a fresh buffer" is not true.
    ///  2. **Write the service array**, or the in-memory list disagrees with disk.
    ///  3. **Rebase after a successful save**, or `original` describes bytes that are no longer on
    ///     disk and the editor's Revert lies about what it would restore.
    ///
    /// ⚠️ The buffer sync writes only the `skillSelections` FACET, never the whole `details` — the
    /// user's other pending edits in that draft must survive.
    private func mutateSelections(_ transform: ([SkillSelection]) -> [SkillSelection]) {
        // ⚠️⚠️ READ THE ROW FRESH, NEVER `profiles[index]`. The launch sweep re-links every pre-V6
        // skill reference by writing `details` on the SwiftData row directly, and the service's
        // array is a snapshot of VALUE TYPES taken before that. Mutating the stale copy and calling
        // `saveProfile` writes the whole pre-sweep `details` back — `BackendProfileStore.saveProfile`
        // does `existing.details = snapshot.details` — so toggling one skill link would silently
        // revert the entire migration for that profile. `activateEditBuffer` already learned this
        // for three other out-of-band writers; `freshProfile` is that rule with a name.
        guard let profileID,
              let index = profileService.profiles.firstIndex(where: { $0.id == profileID }),
              let current = profileService.freshProfile(id: profileID),
              case .agent(var config) = current.details else {
            // ⚠️ A silent return here is the shape that hides a dead toggle: the switch animates,
            // nothing is written, and the user finds out on relaunch.
            DGLogger(category: "SkillLibrary").error("[SKILLS] A skill link change was requested for profile \(profileID?.uuidString ?? "nil") but it is not an AGENT profile in the loaded list. CONSEQUENCE: NOTHING was changed and no error is shown — if a toggle appeared to move, it is lying and will revert on relaunch.")
            return
        }

        let before = config.skillSelections ?? []
        config.skillSelections = transform(before)
        let after = config.skillSelections ?? []

        // 1. Sync the open edit buffer — facet only.
        if let buffer = profileService.editBuffer,
           buffer.draft.id == profileID,
           case .agent(var draftConfig) = buffer.draft.details {
            draftConfig.skillSelections = config.skillSelections
            buffer.draft.details = .agent(draftConfig)
        }

        // 2. Write the service array — from the FRESH row, so every field the sweep or a healer
        //    wrote out of band survives this save instead of being reverted by it.
        var profile = current
        profile.details = .agent(config)
        profileService.profiles[index] = profile

        do {
            try profileService.saveProfile(profile)
            // 3. Rebase, success branch only — rebasing after a FAILED save would baseline the
            //    editor against bytes that were never written.
            profileService.rebaseEditBuffer(to: profile)

            // ⚠️ THE SUCCESS PATH IS LOGGED TOO, and it used not to be. Only failures were, which
            // makes "I linked a skill — did it take?" unanswerable from the log: an unchanged
            // profile and a saved one looked identical. The before/after counts and the pin state
            // are what distinguish a real link from a no-op transform.
            let linked = after.filter(\.isEnabled).count
            let pinned = after.filter { $0.pinnedVersionID != nil }.count
            DGLogger(category: "SkillLibrary").notice("[SKILLS] SAVED skill links for '\(profile.displayName)' [profile \(profile.id)]: \(before.count) selection(s) -> \(after.count), \(linked) enabled, \(pinned) pinned. CONSEQUENCE: this is what the NEXT run of this profile resolves — an enabled selection reaches <available_skills>, a pinned one reads that exact version, and a disabled one is stored but never offered.")
            for selection in after where !before.contains(where: { $0.skillID == selection.skillID && $0.isEnabled == selection.isEnabled && $0.pinnedVersionID == selection.pinnedVersionID }) {
                DGLogger(category: "SkillLibrary").info("[SKILLS]   '\(selection.name)' [skill \(selection.skillID ?? "unlinked")] enabled=\(selection.isEnabled) pinned=\(selection.pinnedVersionID ?? "latest").")
            }
            for removed in before where !after.contains(where: { $0.skillID == removed.skillID }) {
                DGLogger(category: "SkillLibrary").notice("[SKILLS]   UNLINKED '\(removed.name)' [skill \(removed.skillID ?? "unlinked")]. CONSEQUENCE: the next run of this profile does not see it in <available_skills> and cannot load_skill it.")
            }
        } catch {
            DGLogger(category: "SkillLibrary").error("[SKILLS] Failed to save skill links for '\(profile.displayName)': \(error.localizedDescription). CONSEQUENCE: the toggle shows the new state but it was NOT written to disk — it reverts on relaunch, and the edit buffer was NOT rebased so the editor still describes the previous state.")
            // ⚠️ The toggle is already showing the new state, so silence here is worse than a bad
            // write: the user leaves believing the link exists and finds it gone after a relaunch.
            actionError = "The skill links for '\(profile.displayName)' were not saved: \(error.localizedDescription) The switch shows the new state but it was not written — it reverts when you relaunch."
        }
        revision += 1
    }
}

// MARK: - Skill Library Card Row

private struct SkillLibraryCardRow: View {
    let skill: SkillSD
    let selection: SkillSelection?
    let canConfigureSkills: Bool
    let currentProfileName: String
    let theme: any Theme
    let onToggle: (Bool) -> Void
    let onSetPin: (String?) -> Void
    let onOpenDetail: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var isLinked: Bool { selection != nil }
    private var isEnabled: Bool { selection?.isEnabled ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // 36x36 Rounded Glass Icon Container
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((isEnabled ? theme.accentColor : theme.secondaryText).opacity(isEnabled ? 0.16 : 0.08))
                Image(systemName: "puzzlepiece")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isEnabled ? theme.accentColor : theme.secondaryText)
            }
            .frame(width: 36, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder((isEnabled ? theme.accentColor : theme.dividerColor).opacity(isEnabled ? 0.35 : 0.2), lineWidth: 0.5)
            )
            .padding(.top, 2)

            // Center Content
            VStack(alignment: .leading, spacing: 6) {
                // Title & Badges
                HStack(spacing: 8) {
                    Text(skill.displayName.isEmpty ? skill.name : skill.displayName)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    // Origin
                    Text(skill.origin == .imported ? "Imported" : "Created")
                        .font(theme.fontCodeCaption)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.textBackground, in: Capsule())
                        .overlay(Capsule().stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5))

                    // Version count
                    Text("v\(skill.versions.count)")
                        .font(theme.fontCodeCaption)
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.textBackground, in: Capsule())
                        .overlay(Capsule().stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5))

                    // Scripts badge
                    if skill.latestVersion?.hasScripts == true {
                        HStack(spacing: 3) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 8))
                            Text("scripts")
                                .font(theme.fontCodeCaption.weight(.medium))
                        }
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
                    }

                    // Draft badge
                    if skill.isDraft {
                        HStack(spacing: 3) {
                            Image(systemName: "pencil.and.ruler")
                                .font(.system(size: 8))
                            Text("Draft")
                                .font(theme.fontCodeCaption.weight(.medium))
                        }
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
                    }

                    Spacer(minLength: 0)

                    // Hover hint to inspect
                    if isHovered {
                        HStack(spacing: 4) {
                            Text("Details")
                                .font(theme.fontCaption2.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(theme.accentColor)
                    }
                }

                // Description
                if let desc = skill.latestVersion?.skillDescription, !desc.isEmpty {
                    Text(desc)
                        .font(theme.fontSubheadline)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Version Pinning if linked and multi-version
                if canConfigureSkills, let selection, skill.versions.count > 1 {
                    pinControl(for: skill, selection: selection)
                        .padding(.top, 2)
                }
            }

            // Trailing Toggle / Action
            if canConfigureSkills {
                VStack(alignment: .trailing, spacing: 4) {
                    Toggle("", isOn: Binding(
                        get: { isLinked && isEnabled },
                        set: { onToggle($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.regular)
                    .tint(theme.accentColor)
                    .help(isLinked && isEnabled ? "Unlink from \(currentProfileName)" : "Link to \(currentProfileName)")

                    Text(isLinked && isEnabled ? "Enabled" : "Disabled")
                        .font(theme.fontCaption2.weight(.medium))
                        .foregroundStyle(isLinked && isEnabled ? theme.accentColor : theme.secondaryText.opacity(0.7))
                }
                .padding(.leading, 8)
            } else {
                Button {
                    onOpenDetail()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? theme.secondaryBackground.opacity(0.85) : theme.secondaryBackground.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isHovered
                        ? theme.accentColor.opacity(0.4)
                        : (isEnabled ? theme.accentColor.opacity(0.25) : theme.dividerColor.opacity(0.35)),
                    lineWidth: isHovered ? 1 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onOpenDetail()
        }
        .contextMenu {
            Button("Inspect & Edit…") { onOpenDetail() }
            Button("Copy Skill ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(skill.id, forType: .string)
            }
            Divider()
            Button("Delete Skill…", role: .destructive) { onDelete() }
        }
    }

    @ViewBuilder
    private func pinControl(for skill: SkillSD, selection: SkillSelection) -> some View {
        let ordered = skill.versions.sorted { $0.createdAt > $1.createdAt }
        let pinned = selection.pinnedVersionID.flatMap { id in ordered.first { $0.id == id } }
        let pinnedButMissing = selection.pinnedVersionID != nil && pinned == nil

        Menu {
            Button {
                onSetPin(nil)
            } label: {
                Label("Follow latest — updates reach this profile",
                      systemImage: selection.pinnedVersionID == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(ordered, id: \.id) { version in
                Button {
                    onSetPin(version.id)
                } label: {
                    Label("\(version.createdAt.formatted(date: .abbreviated, time: .shortened))\(version.note.isEmpty ? "" : " — \(version.note)")",
                          systemImage: selection.pinnedVersionID == version.id ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: pinnedButMissing ? "exclamationmark.triangle"
                                : pinned != nil ? "pin.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                Text(pinLabel(pinned: pinned, pinnedButMissing: pinnedButMissing))
                    .font(theme.fontCaption2.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(pinnedButMissing ? Color.orange.opacity(0.12)
                          : pinned != nil ? theme.accentColor.opacity(0.12) : theme.textBackground)
            )
            .overlay(
                Capsule()
                    .stroke(pinnedButMissing ? Color.orange.opacity(0.3)
                            : pinned != nil ? theme.accentColor.opacity(0.3) : theme.dividerColor.opacity(0.4), lineWidth: 0.5)
            )
            .foregroundStyle(pinnedButMissing ? Color.orange
                             : pinned != nil ? theme.accentColor : theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(pinnedButMissing
              ? "The pinned version no longer exists, so this skill is skipped for this profile. Pick another version or follow latest."
              : "Choose which version this profile reads")
    }

    private func pinLabel(pinned: SkillVersionSD?, pinnedButMissing: Bool) -> String {
        if pinnedButMissing { return "Pinned version missing" }
        guard let pinned else { return "Follows latest" }
        return "Pinned · \(pinned.createdAt.formatted(date: .abbreviated, time: .omitted))"
    }
}
