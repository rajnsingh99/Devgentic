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
    var openSkillID: String?

    @Environment(BackendProfileService.self) private var profileService
    @Environment(\.appTheme) private var theme

    @AppStorage("skillLibrary.lastProfileID") private var rememberedProfileIDRaw: String = ""
    @State private var revision = 0
    @State private var inspecting: SkillSD?
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
        VStack(alignment: .leading, spacing: 0) {
            header

            if let storeFailure {
                ContentNotFoundView(
                    icon: "exclamationmark.triangle",
                    title: "Skill storage is unavailable",
                    subtitle: "\(storeFailure) Your skills are still configured — do not re-import them."
                )
            } else {
                // ⚠️⚠️ THE EMPTY STATE LIVES INSIDE THE LIST, NOT INSTEAD OF IT. It used to be an
                // `else if skills.isEmpty` arm that replaced the whole scroll view — so the failed-
                // import rows and the dangling-link rows were unreachable in precisely the case
                // they exist for. A user whose skills folder was on an unmounted volume saw "No
                // skills yet — add one", was never told that N imports had FAILED, never saw which
                // folders, and had no Retry: the app knew, and showed them the blank-slate screen.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if skills.isEmpty {
                            ContentNotFoundView(
                                icon: "sparkles",
                                title: "No skills yet",
                                subtitle: "Add one from the Skills sidebar — a folder, a .zip or .skill archive, or a .md file with YAML frontmatter — or write your own."
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, failedImports.isEmpty ? 40 : 16)
                        } else {
                            ForEach(skills, id: \.id) { skill in
                                skillRow(skill)
                            }
                        }
                        if !failedImports.isEmpty {
                            failedImportsSection
                        }
                        if let shellToolOffer {
                            shellOfferRow(shellToolOffer)
                        }
                        unresolvedSection
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.primaryBackground)
        .onAppear {
            failedImports = SkillLibraryMigration.peekPendingImports()
            openRoutedSkillIfNeeded()
        }
        // The pane stays mounted across sidebar clicks, so a second row must open too — `onAppear`
        // alone would fire once and every later click would silently do nothing.
        .onChange(of: openSkillID) { _, _ in openRoutedSkillIfNeeded() }
        // Resets @State across a profile switch within the same destination.
        .id(profileID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        .onChange(of: profileID) { _, new in
            if let new { rememberedProfileIDRaw = new.uuidString }
        }
        // ⚠️ NO ON-APPEAR REFRESH, NO STALENESS CHECK AND NO FILE WATCHER SINCE V6. All three
        // existed to reconcile a database index against folders that could change underneath it.
        // The library owns the bytes now, so there is nothing on disk left to drift from and
        // nothing to watch — the store's `revision`, observed above, is the only invalidation.
        // ⚠️ CONFIRMED, and the message counts what is actually lost. The library holds the only
        // copy of a skill — there is no folder on disk to recover it from and no undo — so this is
        // the one place in the feature where a wrong click is unrecoverable. The count of linked
        // profiles is the part users do not otherwise know.
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
        .sheet(item: $inspecting) { skill in
            SkillDetailSheet(skill: skill) { revision += 1 }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Skills")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            Spacer()

            profileSelector
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Always present, disabled when the route pinned a profile — arriving from a profile's own
    /// config is an explicit statement about what is being configured.
    private var profileSelector: some View {
        Menu {
            Button("None (browse only)") { rememberedProfileIDRaw = "" }
            Divider()
            ForEach(linkableProfiles) { profile in
                Button(profile.displayName) { rememberedProfileIDRaw = profile.id.uuidString }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.square")
                Text(currentProfileName)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(routeProfileID != nil)
        .help(routeProfileID != nil
              ? "Configuring the profile you arrived from"
              : "Choose which agent profile these skills apply to")
    }

    private var currentProfileName: String {
        guard let profileID,
              let profile = linkableProfiles.first(where: { $0.id == profileID }) else {
            return "No profile"
        }
        return profile.displayName
    }

    // MARK: - Rows

    @MainActor
    private func skillRow(_ skill: SkillSD) -> some View {
        let selection = selections.first { $0.skillID == skill.id }
        let isLinked = selection != nil
        let isEnabled = selection?.isEnabled ?? false

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    if skill.latestVersion?.hasScripts == true {
                        // ⚠️ LABELS, never grants. Bundling a script is a fact about the package; it
                        // must not decide the profile's tool set. The shell tool is OFFERED, with a
                        // button, and granted only by a person — see `offerShellToolIfNeeded` below,
                        // which is called from `setLink` and routed through `SkillCapabilityHints`.
                        Text("scripts")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(theme.secondaryText.opacity(0.15), in: Capsule())
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Text(skill.latestVersion?.skillDescription ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)

                // ⚠️ Shown only when this profile LINKS the skill and the skill has more than one
                // version. Offering a pin on a single-version skill is a control that cannot change
                // anything, and offering it on an unlinked skill asks about a relationship that does
                // not exist.
                if canConfigureSkills, let selection, skill.versions.count > 1 {
                    pinControl(for: skill, selection: selection)
                }
            }

            Spacer(minLength: 0)

            if canConfigureSkills {
                Toggle("", isOn: Binding(
                    get: { isLinked && isEnabled },
                    set: { setLink(skill, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(isLinked ? "Unlink from this profile" : "Link to this profile")
            }
        }
        .padding(10)
        .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { inspecting = skill }
        .contextMenu {
            Button("Inspect & Edit…") { inspecting = skill }
            // ⚠️ NO "Reveal in Finder" SINCE V6. The library owns a skill's bytes; there is no
            // folder on disk to reveal. Export writes one on demand instead — a menu item that
            // opened an empty or stale directory would be worse than its absence.
            Button("Copy skill ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(skill.id, forType: .string)
            }
            Divider()
            Button("Delete Skill…", role: .destructive) { pendingDeletion = skill }
        }
    }

    /// Links this profile holds that the LIBRARY cannot resolve — the skill was deleted, or is
    /// still a draft. Shown so they can be removed rather than sitting invisible: the tools path
    /// leaves exactly these orphans with no row to un-tick.
    ///
    /// ⚠️ A selection AWAITING RE-LINK is excluded below and must stay excluded. Its skill very
    /// likely still exists and the import sweep repairs it, so offering removal would invite the
    /// user to destroy a link that is about to fix itself.
    @ViewBuilder
    private var unresolvedSection: some View {
        // ⚠️ A selection AWAITING RE-LINK is not dangling and must not be offered for removal —
        // its skill very likely still exists and the import sweep repairs it. Telling the user to
        // delete a link that is about to fix itself is the opposite of helpful.
        let known = Set(skills.map(\.id))
        let dangling = selections.filter { selection in
            guard let skillID = selection.skillID else { return false }
            return !known.contains(skillID)
        }

        if canConfigureSkills, !dangling.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Linked but not found")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 8)

                ForEach(dangling) { selection in
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(selection.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.primaryText)
                            Text(selection.skillID ?? selection.legacyFolderPath ?? "unknown address")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                        Button("Remove") { if let id = selection.skillID { removeLink(skillID: id) } }
                            .font(.system(size: 11))
                    }
                    .padding(10)
                    .background(theme.secondaryBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// ⚠️ A sentence and a button. The grant is a person's answer to a question — that is the whole
    /// reason this may read a declaration at all.
    @ViewBuilder
    private func shellOfferRow(_ skillName: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("'\(skillName)' runs shell commands")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Text("This profile has no shell tool, so the skill's steps that need one will fail. Adding it asks for your confirmation on every command.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Add execute_shell") { acceptShellToolOffer() }
                .font(.system(size: 11))
            Button("Not now") { shellToolOffer = nil }
                .font(.system(size: 11))
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
    private func openRoutedSkillIfNeeded() {
        guard let openSkillID,
              let match = skills.first(where: { $0.id == openSkillID }) else { return }
        inspecting = match
    }

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

    /// Lets a profile freeze on one version of a skill.
    ///
    /// ⚠️ A pin is the ONLY thing that stops an `update_skill` write — or a re-import — reaching this
    /// profile. That is its whole purpose, so the menu says what following latest actually means
    /// rather than leaving the user to infer it from a checkmark.
    ///
    /// ⚠️ A DANGLING pin resolves to nothing rather than silently falling back to latest
    /// (`SkillResolution`), which is why the current selection is shown even when the pinned version
    /// is gone — otherwise the skill would just stop working with nothing on screen to explain it.
    @ViewBuilder
    private func pinControl(for skill: SkillSD, selection: SkillSelection) -> some View {
        let ordered = skill.versions.sorted { $0.createdAt > $1.createdAt }
        let pinned = selection.pinnedVersionID.flatMap { id in ordered.first { $0.id == id } }
        let pinnedButMissing = selection.pinnedVersionID != nil && pinned == nil

        Menu {
            Button {
                setPin(nil, for: skill.id)
            } label: {
                Label("Follow latest — updates reach this profile",
                      systemImage: selection.pinnedVersionID == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(ordered, id: \.id) { version in
                Button {
                    setPin(version.id, for: skill.id)
                } label: {
                    Label("\(version.createdAt.formatted(date: .abbreviated, time: .shortened))\(version.note.isEmpty ? "" : " — \(version.note)")",
                          systemImage: selection.pinnedVersionID == version.id ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: pinnedButMissing ? "exclamationmark.triangle"
                                : pinned != nil ? "pin.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                Text(pinLabel(pinned: pinned, pinnedButMissing: pinnedButMissing))
                    .font(.system(size: 10))
            }
            .foregroundStyle(pinnedButMissing ? Color.orange
                             : pinned != nil ? Color.accentColor : theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
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

    /// ⚠️ Rewrites the selection IN PLACE rather than removing and re-adding it, so `isEnabled`
    /// survives. Re-adding would silently re-enable a skill the user had switched off — a pin change
    /// reading as a settings reset.
    private func setPin(_ versionID: String?, for skillID: String) {
        mutateSelections { SkillLinkEditing.pinning($0, skillID: skillID, toVersionID: versionID) }
    }

    /// Folders the migration sweep could not import — almost always a volume that was not mounted.
    ///
    /// ⚠️ THIS EXISTED ONLY IN THE LOG until now. The sweep computed the list, reported it to
    /// `os_log`, and dropped it — so a user upgrading with an external drive unplugged saw skills
    /// simply missing, with no way to learn why or to retry once the drive was back. A failure the
    /// user cannot see is the same as a silent drop.
    @ViewBuilder
    private var failedImportsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("\(failedImports.count) skill\(failedImports.count == 1 ? "" : "s") could not be imported")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
                if isRetryingImports {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Try again") { retryFailedImports() }
                        .font(.system(size: 11))
                    // ⚠️ "Forget" is destructive in the only sense that matters here: it is the
                    // user deciding those skills are not coming back. Nothing else clears the
                    // capture, so without it the banner would be permanent.
                    Button("Forget") { forgetFailedImports() }
                        .font(.system(size: 11))
                }
            }
            Text("These came from folders your skills used to live in. They are usually on a drive that was not mounted when Devgentic upgraded — reconnect it and try again.")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(failedImports, id: \.folderPath) { ref in
                HStack(spacing: 6) {
                    Text(ref.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    Text(ref.folderPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Re-runs the sweep. Safe to press repeatedly: it reads the capture, imports what it can, and
    /// writes back only what still failed.
    private func retryFailedImports() {
        guard let container = SkillStore.shared.currentContainer else {
            DGLogger(category: "SkillLibrary").error("[SKILLS] Retry requested with no model container. CONSEQUENCE: nothing was imported and the pending list is unchanged; the next launch retries.")
            return
        }
        isRetryingImports = true
        let outcome = SkillLibraryImportSweep.run(container: container)
        failedImports = SkillLibraryMigration.peekPendingImports()
        isRetryingImports = false
        revision += 1

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
              case .agent(let config) = profile.details else { return }

        guard SkillCapabilityHints.shouldOfferShellTool(
            declaredTools: skill.latestVersion?.allowedTools,
            hasScripts: skill.latestVersion?.hasScripts ?? false,
            profileTools: config.tools
        ) else {
            shellToolOffer = nil
            return
        }
        shellToolOffer = skill.name
    }

    /// Adds `execute_shell` because the USER asked, from the offer row.
    private func acceptShellToolOffer() {
        defer { shellToolOffer = nil }
        guard let profileID,
              let index = profileService.profiles.firstIndex(where: { $0.id == profileID }),
              case .agent(var config) = profileService.profiles[index].details else { return }
        guard !config.tools.contains(where: { $0.name == "execute_shell" }) else { return }

        config.tools.append(SkillCapabilityHints.shellTool())

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

        var profile = profileService.profiles[index]
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
        guard let profileID,
              let index = profileService.profiles.firstIndex(where: { $0.id == profileID }),
              case .agent(var config) = profileService.profiles[index].details else { return }

        config.skillSelections = transform(config.skillSelections ?? [])

        // 1. Sync the open edit buffer — facet only.
        if let buffer = profileService.editBuffer,
           buffer.draft.id == profileID,
           case .agent(var draftConfig) = buffer.draft.details {
            draftConfig.skillSelections = config.skillSelections
            buffer.draft.details = .agent(draftConfig)
        }

        // 2. Write the service array.
        var profile = profileService.profiles[index]
        profile.details = .agent(config)
        profileService.profiles[index] = profile

        do {
            try profileService.saveProfile(profile)
            // 3. Rebase, success branch only — rebasing after a FAILED save would baseline the
            //    editor against bytes that were never written.
            profileService.rebaseEditBuffer(to: profile)
        } catch {
            DGLogger(category: "SkillLibrary").error("[SKILLS] Failed to save skill links for '\(profile.displayName)': \(error.localizedDescription). CONSEQUENCE: the toggle shows the new state but it was NOT written to disk — it reverts on relaunch, and the edit buffer was NOT rebased so the editor still describes the previous state.")
            // ⚠️ The toggle is already showing the new state, so silence here is worse than a bad
            // write: the user leaves believing the link exists and finds it gone after a relaunch.
            actionError = "The skill links for '\(profile.displayName)' were not saved: \(error.localizedDescription) The switch shows the new state but it was not written — it reverts when you relaunch."
        }
        revision += 1
    }
}
