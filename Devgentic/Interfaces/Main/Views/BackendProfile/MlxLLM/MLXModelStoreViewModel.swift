// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXModelStoreViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import SwiftUI

@Observable @MainActor
class MLXModelStoreViewModel {

    @ObservationIgnored private let logger = DGLogger(category: "MLXModelStore")

    let filterForTools: Bool

    // MARK: - Inputs (View Actions)
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.applySearchChange()
            }
        }
    }

    /// True while the user is on `.all` only because a query moved them off `.recommended`.
    /// Clearing the query puts them back; picking any tab themselves ends the arrangement.
    @ObservationIgnored private var didAutoLeaveRecommended = false

    /// Set while THIS type assigns `selectedCategory`, so the `didSet` can tell an automatic
    /// switch from one the user made.
    @ObservationIgnored private var isAutoSwitchingCategory = false
    var selectedCategory: StoreCategory = .all {
        didSet {
            if selectedCategory != oldValue {
                // A tab the USER picked ends the auto-switch: clearing the search box must not
                // then yank them back to Recommended from a tab they chose deliberately.
                //
                // ⚠️ AND IT CANCELS A PENDING KEYSTROKE. The fence below guards the synchronous
                // path; nothing guarded the asynchronous one. A debounce armed before the tab
                // switch would fire 500 ms later, route on the NEW category, and yank the user
                // straight back off the tab they had just chosen — then set
                // `didAutoLeaveRecommended`, so clearing the box bounced them a second time.
                if !isAutoSwitchingCategory {
                    didAutoLeaveRecommended = false
                    cancelPendingSearch()
                }
                // ⚠️ Drop the quantization narrowing on a category switch. It was chosen
                // against a different result set, and the picker that undoes it only renders
                // when the NEW set offers more than one quantization — so carrying it over
                // could present an empty grid with no control to clear it, directly
                // contradicting the "3 installed · 12.4 GB" summary above it. This view model
                // is cached by `DestinationCoordinator` for the app lifetime, so leaving the
                // store did not reset it either. A filter the user cannot see is a filter
                // that enforces rather than describes.
                // ⚠️ ONLY ON A TAB THE USER PICKED. The rationale below — "chosen against a
                // different result set", "the picker that undoes it may not render on the new
                // tab" — is about a deliberate navigation. It does not hold for the auto-switch
                // to `.all`, which the code performs on the user's behalf and where the picker
                // always renders: clearing there threw away a width the user had explicitly
                // chosen moments earlier, with no interaction of theirs in between.
                if let cleared = quantizationFilter, !isAutoSwitchingCategory {
                    logger.info("[MLXSTORE] Cleared the \(cleared.rawValue)-bit quantization filter on switching to the \(self.selectedCategory.rawValue) tab. CONSEQUENCE: the new tab shows all its models; the filter was chosen against the previous result set.")
                    // ⚠️ Suppress this clear's OWN refresh. `quantizationFilter`'s didSet now
                    // re-queries HuggingFace, and the `refreshCategoryData()` below is about to
                    // do exactly that for the new tab. Without the fence, every tab switch made
                    // from a filtered tab fires two listing requests plus two rounds of size
                    // lookups; the generation token discards one, but it is still sent.
                    isClearingQuantizationForCategorySwitch = true
                    quantizationFilter = nil
                    isClearingQuantizationForCategorySwitch = false
                }
                refreshCategoryData()
            }
        }
    }

    /// Sorting preference
    var sortOption: SortOption = .popularity {
        didSet {
            // Re-apply filters and sort when option changes
            applyFilterAndSort()
            maybeRefetchForServerSort(from: oldValue)
        }
    }

    /// True only while `refreshCategoryData` is putting `sortBeforeInstalledTab` back, so the
    /// `sortOption` didSet can tell that restore from a choice the user made. Same reason
    /// `isAutoSwitchingCategory` exists for `selectedCategory`.
    @ObservationIgnored private var isRestoringSort = false

    /// The HuggingFace `sort=` field the models currently in `service.availableModels` were
    /// ranked by. `loadMore` pages against THIS, not against `sortOption`, because a `skip`
    /// offset is only meaningful within the ranking that produced the earlier pages.
    @ObservationIgnored private var lastFetchedSort = MLXModelService.defaultSortField

    // MARK: - Outputs (View State)
    var displayedModels: [MLXDisplayModel] = []
    var isLoading: Bool = false

    /// Total on-disk size of installed models, formatted, or nil while the background
    /// sizing pass is still running.
    var installedStorageSummary: String? {
        guard let total = service.totalInstalledBytes, total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// How many models are installed, irrespective of any active filter.
    var installedCount: Int { service.installedModels.count }

    /// True when the Installed tab is showing a filtered subset.
    var isFilteringInstalled: Bool {
        selectedCategory == .installed && !searchText.isEmpty
    }

    /// Update status for an installed card, or nil if no check has run for it.
    func updateStatus(for model: MLXDisplayModel) -> MLXModelRevision.UpdateStatus? {
        service.updateStatus[model.id]
    }

    var isCheckingForUpdates: Bool { service.isCheckingForUpdates }

    func checkForUpdates() {
        Task { await service.checkForModelUpdates() }
    }

    /// The on-disk item behind a card, when it is installed.
    func installedItem(for model: MLXDisplayModel) -> MLXModelItem? {
        service.installedModel(named: model.id)
    }

    /// Formatted size of one installed model, for the delete confirmation.
    func installedSize(of model: MLXDisplayModel) -> String? {
        guard let bytes = service.installedSizeBytes[model.id], bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The last download failure, surfaced as a dismissible banner. A failed MLX download
    /// used to revert the card to a plain Download button with the reason shown nowhere in
    /// the store at all — `MLXModelService.errorMessage` had no reader.
    var downloadError: String?

    /// Why the last remote fetch failed. Mirrored from the service so the grid can explain
    /// itself: rate-limited, offline, gated and genuinely-empty previously all rendered the
    /// same "No models found" dead end with a reload button that re-provoked the failure.
    var loadError: HFRequestError?

    /// The sort the user had before the Installed tab forced `.recent`, so it can be put back.
    @ObservationIgnored private var sortBeforeInstalledTab: SortOption?

    // Pagination State
    @ObservationIgnored private var currentPage = 0
    @ObservationIgnored private let pageSize = 30

    // Download State
    var isDownloading: Bool = false
    var currentDownloadName: String = ""

    // MARK: - Dependencies
    @ObservationIgnored private let service = MLXModelService.shared
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    
    // MARK: - Definitions
    
    enum StoreCategory: String, CaseIterable, Identifiable {
        case installed = "Installed"
        /// Hand-checked starting points. Default tab on a first run, when the raw popularity
        /// listing is at its least helpful. See `CuratedMLXCatalog`.
        case recommended = "Recommended"
        case all = "All"
        case toolUse = "Tool Use"
        case vision = "Vision"
        
        var id: String { rawValue }
        
        /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
        /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
        /// invisible to the String Catalog extractor and would have shipped untranslated inside
        /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .installed:   return "Installed"
            case .recommended: return "Recommended"
            case .all:         return "All"
            case .toolUse:   return "Tool Use"
            case .vision:    return "Vision"
            }
        }

        var icon: String {
            switch self {
            case .recommended: return "sparkles"
            case .installed: return "externaldrive.fill.badge.checkmark"
            case .all: return "square.grid.2x2.fill"
            case .toolUse: return "hammer.fill"
            case .vision: return "eye.fill"
            }
        }
        
        /// Client-side capability to filter on for this category.
        /// We deliberately avoid forwarding capability tags to the HF filter because
        /// `filter=mlx,tool-use` is ANDed server-side — which eliminates most popular
        /// MLX models (Qwen2.5, Llama-3.x, etc.) since their authors rarely add the
        /// `tool-use` / `reasoning` HF tag. Instead, we fetch all MLX models and
        /// classify via `MLXDisplayModel.capabilities` (set by `classifyCapabilities`).
        var clientCapability: MLXModelCapability? {
            switch self {
            case .all, .installed, .recommended: return nil
            case .toolUse: return .toolUse
            case .vision: return .vision
            }
        }
    }
    
    /// ⚠️ Every category stays available even in tool-filtering mode.
    ///
    /// This used to return `[.installed, .toolUse]`, deleting the "All" tab — so a model the
    /// `classifyCapabilities` name heuristic failed to tag had NO browse path at all. Combined
    /// with the hard filter below and the picker's own filter, a heuristic false negative
    /// became a product lockout with no override: the user could not select or download their
    /// own tool-capable model in an Agent profile. Classification may label and group; it must
    /// never gate.
    var availableCategories: [StoreCategory] {
        StoreCategory.allCases
    }

    /// Show only this quantization, or nil for all. The store previously had no way to narrow
    /// to 4-bit even though the listing routinely returns the same model at four different
    /// quantizations as visually identical cards.
    /// ⚠️ On a server-backed tab this is a QUERY, not a client-side sieve — see `remoteQuery`.
    var quantizationFilter: MLXQuantization? {
        didSet {
            guard quantizationFilter != oldValue else { return }
            // A category switch clears this and then refreshes for the new tab itself; without
            // this guard that clear fires a second, immediately-superseded request.
            guard !isClearingQuantizationForCategorySwitch else { return }
            if selectedCategory == .installed || selectedCategory == .recommended {
                // Fixed local sets with no server behind them — the client filter IS the answer.
                applyFilterAndSort()
            } else {
                logger.info("[MLXSTORE] Quantization → \(self.quantizationFilter?.searchToken ?? "any") on the \(self.selectedCategory.rawValue) tab. CONSEQUENCE: re-querying HuggingFace with the bit-width in the search term; narrowing the current 30-row page client-side left only the few of that width that happened to land on it.")
                // ⚠️ This re-query supersedes any pending one. Picking a width within 500 ms of a
                // keystroke — or clicking "Reset Filters", which clears the box and then the
                // width — otherwise sent TWO byte-identical listing requests plus two rounds of
                // ~30 per-repo size lookups. The generation token discards one response, but both
                // requests still go out, at a store HuggingFace rate-limits hard enough to need a
                // dedicated 429 path with no retry.
                cancelPendingSearch()
                refreshCategoryData(reason: .filterChanged)
            }
        }
    }

    /// Set while `selectedCategory`'s didSet clears the quantization filter, so that clear does
    /// not issue a fetch on top of the one the category switch is already about to make.
    @ObservationIgnored private var isClearingQuantizationForCategorySwitch = false

    /// The exact `search=` term the next HuggingFace listing request will carry.
    ///
    /// ⚠️ BOTH remote call sites read this one property, so a page-2 fetch can never drop the
    /// narrowing page 1 was built with.
    var remoteSearchQuery: String? {
        Self.remoteQuery(search: searchText, quantization: quantizationFilter)
    }

    /// Folds the search box and the quantization picker into ONE HuggingFace `search=` term.
    ///
    /// ⚠️ The quantization has to go into the SERVER query. HuggingFace returns 30 rows per page
    /// ranked by downloads; narrowing those 30 locally showed two or three cards — or none —
    /// while HF holds hundreds of repos at that width. `search` ANDs its tokens against the
    /// repo id, so "qwen 4bit" returns only 4-bit Qwen repos.
    ///
    /// ⚠️ A bare bit-width the user TYPED is dropped when it contradicts the picker: HF ANDs, so
    /// "gemma 8bit" plus a 4-bit selection returns literally zero rows — exactly the empty grid
    /// this change exists to remove. The picker is the explicit choice, so it wins. Only a token
    /// that is NOTHING BUT a width is dropped; "Qwen3-8bit" survives intact, because deleting it
    /// would throw away the family name and search for a width alone.
    ///
    /// Pure and `nonisolated` so it is testable without building a view model.
    nonisolated static func remoteQuery(
        search: String, quantization: MLXQuantization?
    ) -> String? {
        // ⚠️ Tokenise on the whitespace CLASS and re-join on plain spaces, on BOTH paths. A
        // trim only cleans the ENDS, so a non-breaking space or tab pasted from a web page rode
        // straight into `search=` — and, with a picker set, glued a contradicting width onto its
        // neighbour so the drop below never saw it.
        let tokens = search.split(whereSeparator: { $0.isWhitespace })
        guard let quantization else {
            return tokens.isEmpty ? nil : tokens.joined(separator: " ")
        }
        let kept = tokens.filter { token in
            let lower = token.lowercased()
            let isBareWidth = MLXQuantization.allCases.contains { quant in
                ["\(quant.rawValue)bit", "\(quant.rawValue)-bit", "\(quant.rawValue)_bit"].contains(lower)
            } || ["bf16", "fp16", "float16"].contains(lower)
            // ⚠️ DROP EVERY bare width, including one that AGREES with the picker.
            //
            // This used to keep an agreeing token and then append `searchToken` as well, which
            // emits two spellings of the same width whenever they differ — "4-bit" + "4bit", or
            // "16bit" + "bf16". HuggingFace ANDs the terms against `filter=mlx`, so the composed
            // query is unsatisfiable: verified live, `search=qwen 4bit` returns 30 rows while
            // `search=qwen 4-bit 4bit` returns 0. The picker's own menu spells widths "4-bit",
            // so the broken spelling is the one the app teaches.
            //
            // The 16-bit case was self-refuting: `searchToken` exists precisely because "16bit"
            // matches almost nothing, and the old filter put the user's literal "16bit" back in.
            //
            // The picker is the explicit choice, so it supplies the one canonical spelling and
            // every typed width defers to it — agreeing or not.
            return !isBareWidth
        }
        return (kept.map(String.init) + [quantization.searchToken]).joined(separator: " ")
    }

    /// Quantizations actually present in the current results — no point offering a 2-bit
    /// filter for a page that has none.
    /// ⚠️ On a server-backed tab this is the FULL set, not what the current page contains.
    /// Now that the choice goes into the HuggingFace query, a 4-bit page contains only 4-bit
    /// models — deriving the menu from the results would leave "Any" and "4-bit" as the only
    /// entries, so 4-bit → 8-bit would mean routing back through "Any" and waiting for a round
    /// trip. HuggingFace has a full page at every width, so every width is a real offer.
    ///
    /// `.installed` and `.recommended` are fixed local sets, so there the rows ARE the universe
    /// and offering a width nothing holds would empty the grid with no server able to fill it.
    /// ⚠️ `.recommended` reads `CuratedMLXCatalog`, NOT `availableModels`: its grid is built
    /// from the curated list, so the old source offered widths left over from whatever tab was
    /// fetched last.
    var availableQuantizations: [MLXQuantization] {
        guard selectedCategory == .installed || selectedCategory == .recommended else {
            return MLXQuantization.allCases.sorted()
        }
        let source: [MLXQuantization]
        if selectedCategory == .installed {
            source = service.installedModels.compactMap { MLXQuantization.parse(fromRepoId: $0.displayName) }
        } else {
            let ramGB = Int(SystemHardwareProfiler.shared.profile.totalRAM / (1024 * 1024 * 1024))
            source = CuratedMLXCatalog.recommended(forSystemRAMGB: ramGB)
                .compactMap { MLXQuantization.parse(fromRepoId: $0.id) }
        }
        var present = Set(source)
        // ⚠️ Always offer the ACTIVE filter, even when nothing in the current results matches
        // it. Otherwise the Picker has no tag for its own selection, renders blank, and the
        // user cannot clear the very filter that emptied the grid.
        if let quantizationFilter { present.insert(quantizationFilter) }
        return Array(present).sorted()
    }

    /// User-facing switch for the tool-capability filter. Defaults on so Agent profiles still
    /// lead with tool-capable models, but the user can always see everything — the heuristic
    /// is advice, not an authority.
    var showToolCapableOnly: Bool = true {
        didSet {
            if showToolCapableOnly != oldValue { applyFilterAndSort() }
        }
    }

    /// Narrow the grid to models this Mac can actually run.
    ///
    /// ⚠️ DEFAULT OFF, unlike `showToolCapableOnly` above. That one narrows inside a mode the
    /// user already opted into (an Agent profile asking for tool-capable models); this one hides
    /// models on a hardware verdict nobody asked about. The store's own precedent for this exact
    /// signal is ORDERING, not hiding — `CuratedMLXCatalog.recommended` calls it "Ordering only —
    /// nothing is hidden" — and the download path refuses to gate on an `.unknown` verdict for
    /// the same reason: describe, don't gate. Turning the badge into a hide is the user's call,
    /// and it stays one click from off at all times.
    var fitsMyMacOnly: Bool = false {
        didSet {
            guard fitsMyMacOnly != oldValue else { return }
            let budget = SystemHardwareProfiler.shared.profile.formattedEffectiveBudget
            logger.info("[MLXSTORE] 'Fits my Mac' \(self.fitsMyMacOnly ? "ON" : "OFF") against a \(budget) budget. CONSEQUENCE: \(self.fitsMyMacOnly ? "models estimated to exceed the budget are hidden; the hidden count renders beside the checkbox, which always clears it" : "every model is shown again").")
            applyFilterAndSort()
        }
    }

    /// How many models the fit filter is hiding right now, for the label beside the checkbox.
    /// ⚠️ Must stay observable — a filter that empties the grid without saying so is the
    /// enforcing kind.
    var hiddenByFitFilter: Int = 0

    /// Whether a verdict survives the "Fits my Mac" filter.
    ///
    /// Pure and `nonisolated` so the rule is testable without building a view model — same shape
    /// as `searchDestination` and `serverSortRefetch`.
    ///
    /// ⚠️ `.unknown` is KEPT, and this case is the whole risk. Remote cards are built with a
    /// `sizeBytes` that is nil until the size pass lands, and `fetchRemoteModels` clears
    /// `isLoading` BEFORE awaiting it. Hiding unknowns would therefore paint "No models found",
    /// with its "Try Reloading" button, over a page that had just loaded fine — and permanently
    /// so under a 429, where the size batch is abandoned and there is deliberately no retry.
    /// Nothing is misrepresented by keeping the card: its own badge renders `.unknown` as
    /// "Size Unknown".
    ///
    /// ⚠️ Exhaustive, no `default:` — a verdict added later must fail the build here rather than
    /// silently inherit "keep".
    nonisolated static func passesFitFilter(_ verdict: ModelFitVerdict) -> Bool {
        switch verdict {
        case .comfortable, .tight:  return true
        case .risky, .incompatible: return false
        case .unknown:              return true
        }
    }

    /// The canonical `owner/name` repo id a pasted string denotes, or nil when the text is a
    /// SEARCH TERM rather than an identifier.
    ///
    /// ⚠️ The store's one text input is a QUERY — it goes to HuggingFace as `search=`, which ranks
    /// and fuzzy-matches. A user holding an exact id from a model card or a blog post had no way
    /// to say "fetch THIS one"; it had to be located in ranked results first. This rule tells the
    /// two apart, so the Fetch affordance appears only when the text really is an id.
    ///
    /// Returns the id rather than a Bool on purpose: the caller needs the cleaned string, and a
    /// separate predicate and normaliser are two rules that can disagree.
    ///
    /// ACCEPTS — all of these yield `mlx-community/Qwen3-8B-4bit`: the bare id; surrounding
    /// whitespace (pasting out of a code block); one trailing `/` (pasting out of an address bar);
    /// `https://huggingface.co/<id>` with or without scheme, with `www.` or `hf.co`, with a `?…`
    /// query or `#…` fragment, and with a trailing `/tree/main` or `/blob/main/…`.
    ///
    /// REJECTS — these stay plain searches: anything with no `/` (`qwen3 8bit`, the common case);
    /// anything with whitespace INSIDE, because `remoteQuery` splits this box on spaces so a space
    /// means the user is typing tokens; a bare form that is not exactly two components.
    ///
    /// ⚠️ The character check is NOT cosmetic. The value is interpolated straight into
    /// `https://huggingface.co/api/models/\(repoId)` and handed to `HubApi.snapshot`, whose
    /// `localRepoLocation` appends it under the models directory. A `.` or `..` component is a
    /// path, not a name.
    nonisolated static func repoIdToDownload(from text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return nil }

        // Strip the URL form down to its path FIRST, so a query or fragment never has to pass
        // the component test below.
        if let hash = s.firstIndex(of: "#") { s = String(s[s.startIndex..<hash]) }
        if let query = s.firstIndex(of: "?") { s = String(s[s.startIndex..<query]) }
        let scheme = s.lowercased()
        if scheme.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        else if scheme.hasPrefix("http://") { s = String(s.dropFirst(7)) }

        var isURLForm = false
        for host in ["www.huggingface.co/", "huggingface.co/", "hf.co/"] where s.lowercased().hasPrefix(host) {
            s = String(s.dropFirst(host.count))
            isURLForm = true
            break
        }

        var parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }          // exactly one trailing slash
        // A model-card URL routinely carries `/tree/main` or `/blob/main/config.json`; the id is
        // the first two components. URL form ONLY — a bare `a/b/c` is not a repo id.
        if isURLForm, parts.count > 2 { parts = Array(parts.prefix(2)) }
        guard parts.count == 2 else { return nil }

        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else { return nil }
            let ok = part.allSatisfy { ch in
                ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")
            }
            guard ok else { return nil }
        }
        return parts.joined(separator: "/")
    }
    
    enum SortOption: String, CaseIterable, Identifiable {
        case popularity = "Popularity"
        case recent = "Recent"
        case sizeSmallest = "Size (Smallest)"
        case sizeLargest = "Size (Largest)"

        var id: String { rawValue }

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .popularity:   return "Popularity"
            case .recent:       return "Recent"
            case .sizeSmallest: return "Size (Smallest)"
            case .sizeLargest:  return "Size (Largest)"
            }
        }

        /// The HuggingFace `sort=` field this option maps to, or nil when the API cannot rank
        /// by it and the ordering can only be imposed client-side.
        ///
        /// ⚠️ The size sorts are nil ON PURPOSE. Repo size is not a field on `/api/models`; it
        /// is fetched per-repo afterwards by `fetchSizes`, so only models already on the page
        /// have one. A size sort is therefore a re-ordering of the pages already loaded, never
        /// a global ranking — which is exactly today's behaviour, preserved deliberately.
        /// ⚠️ No `default:` — a fifth option must fail the build here rather than ship as
        /// `downloads` without anyone deciding that.
        var hfSort: String? {
            switch self {
            case .popularity:   return "downloads"
            case .recent:       return "lastModified"
            case .sizeSmallest, .sizeLargest: return nil
            }
        }

        var icon: String {
            switch self {
            case .popularity: return "arrow.down.circle"
            case .recent: return "clock.arrow.circlepath"
            case .sizeSmallest: return "arrow.up.arrow.down.square"
            case .sizeLargest: return "arrow.up.arrow.down.square.fill"
            }
        }
    }
    
    // MARK: - Initialization

    @ObservationIgnored private var serviceObserver: ObservationStream?

    init(filterForTools: Bool = false) {
        self.filterForTools = filterForTools
        // A first run — no models on disk — lands on the curated list. That is exactly when
        // the raw HuggingFace popularity listing is least helpful: its top results included
        // speech-recognition models badged "Chat" and a 657 GB repo.
        let hasModels = !MLXModelService.shared.installedModels.isEmpty
        self.selectedCategory = hasModels ? (filterForTools ? .installed : .all) : .recommended
        setupObserver()
        refreshCategoryData()
    }

    deinit {
        // Releasing `serviceObserver` triggers `ObservationStream.deinit`,
        // which flips its own `isActive` flag so any in-flight onChange task
        // short-circuits instead of writing to a zombie self.
    }

    /// Bridges MLXModelService (@Observable) changes into this @Observable view model.
    private func setupObserver() {
        serviceObserver = ObservationStream(
            track: { [weak self] in
                guard let self else { return }
                _ = self.service.availableModels
                _ = self.service.installedModels
                _ = self.service.installedSizeBytes
                _ = self.service.updateStatus
                _ = self.service.isCheckingForUpdates
                _ = self.service.isLoadingRemoteModels
                _ = self.service.remoteLoadError
                _ = self.service.isDownloading
                // ⚠️ `downloadProgress` is deliberately NOT tracked here. It ticks
                // continuously during a pull, and this observer's `onChange` runs
                // `applyFilterAndSort()` — a full re-filter and re-sort of the entire grid
                // per tick. The progress UI reads `DownloadManager`'s per-record state
                // directly, so nothing in this view model needs the value.
                _ = self.service.currentDownloadName
                _ = self.service.errorMessage
            },
            onChange: { [weak self] in
                guard let self else { return }
                // Mirror state from service
                self.isLoading = self.service.isLoadingRemoteModels
                self.loadError = self.service.remoteLoadError
                self.isDownloading = self.service.isDownloading
                self.currentDownloadName = self.service.currentDownloadName
                if let message = self.service.errorMessage, !message.isEmpty {
                    self.downloadError = message
                }
                self.applyFilterAndSort()
            }
        )
    }
    
    // MARK: - Logic

    /// Why `refreshCategoryData` is being called. Register A43.
    ///
    /// ⚠️ The Installed tab's forced disk scan is correct for a Refresh click, a tab switch and
    /// first load — all explicit requests for current data — and wrong for a keystroke in the
    /// filter field. `force: true` bypasses both the 2 s debounce AND the in-flight coalescing
    /// (a forcing caller joins the running walk and then deliberately starts a new one), so every
    /// typing pause guaranteed a fresh recursive `FileManager.enumerator` walk plus a full
    /// cognitive-profile rebuild — and none of it could change the result, because filtering the
    /// Installed tab happens entirely client-side in `filterAndSortModels`.
    private enum RefreshReason {
        /// Refresh button, tab switch, first load — re-read the disk.
        case userRequest
        /// A filter keystroke. The data is already current; only the projection changes.
        case filterChanged
    }

    /// Where a search keystroke should send the user, or `nil` to stay on this tab and
    /// re-filter in place.
    ///
    /// Pure and `nonisolated` so the rule can be tested without building a view model (which
    /// would drag in `MLXModelService.shared` and a disk scan).
    ///
    /// ⚠️ THE RECOMMENDED TAB CANNOT ANSWER A QUERY. Its rows come from `CuratedMLXCatalog`,
    /// selected in `filterAndSortModels`, and `refreshCategoryData` serves that tab entirely
    /// locally — it issues no HuggingFace request at all. So a query typed there is routed to
    /// `.all`, which does issue one, instead of being silently dropped.
    ///
    /// ⚠️ MOVING THE TAB IS THE POINT, not a side effect. The results must be labelled by what
    /// they are: a remote search answers from all of HuggingFace, not from the seven hand-picked
    /// entries, so leaving the grid titled "Recommended" would be a lie about its own contents.
    ///
    /// The return trip is deliberate too — the user never asked to leave Recommended, so
    /// clearing the box undoes the move. It is guarded on `.all` as well as on the flag, so that
    /// a stale flag can never bounce the user out of a tab they picked themselves.
    nonisolated static func searchDestination(
        from current: StoreCategory,
        query: String,
        autoLeftRecommended: Bool
    ) -> StoreCategory? {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if current == .recommended && hasQuery { return .all }
        if current == .all && autoLeftRecommended && !hasQuery { return .recommended }
        return nil
    }

    /// The HF `sort=` field a sort change must re-query with, or nil to leave the loaded result
    /// set alone and merely re-order it client-side.
    ///
    /// Pure and `nonisolated` for the same reason `searchDestination` is: testable without
    /// building a view model, whose `init` scans the disk and fetches from HuggingFace.
    ///
    /// ⚠️ nil for `.installed` and `.recommended` — neither has a server behind it. One is a
    /// disk scan; the other is `CuratedMLXCatalog`, served entirely locally.
    /// ⚠️ nil for a size sort — re-querying would throw away every page the user loaded to
    /// change nothing, because the API cannot rank by repo bytes.
    nonisolated static func serverSortRefetch(
        from oldValue: SortOption,
        to newValue: SortOption,
        category: StoreCategory,
        lastFetchedSort: String
    ) -> String? {
        guard oldValue != newValue else { return nil }
        guard category != .installed, category != .recommended else { return nil }
        guard let target = newValue.hfSort, target != lastFetchedSort else { return nil }
        return target
    }

    /// Re-queries HuggingFace when the user's sort choice changes the ranking the SERVER owes us.
    ///
    /// ⚠️ THE `isRestoringSort` GUARD IS MANDATORY. `refreshCategoryData` restores
    /// `sortBeforeInstalledTab` by assigning `sortOption` BEFORE it clears the stash, and this
    /// didSet has no equality guard of its own — so without the fence, leaving the Installed tab
    /// runs didSet → refreshCategoryData → assign → didSet → … and never terminates.
    private func maybeRefetchForServerSort(from oldValue: SortOption) {
        guard !isRestoringSort else { return }
        guard let target = Self.serverSortRefetch(
            from: oldValue, to: sortOption,
            category: selectedCategory, lastFetchedSort: lastFetchedSort
        ) else { return }
        logger.info("[MLXSTORE] Sort \(oldValue.rawValue) → \(self.sortOption.rawValue) re-ranks the query as sort=\(target) (was \(self.lastFetchedSort)). CONSEQUENCE: page 0 is re-fetched and currentPage resets — a skip offset into the old ranking indexes a different result set.")
        refreshCategoryData()
    }

    /// True when the shared `availableModels` was produced by a DIFFERENT query than this
    /// instance is showing.
    ///
    /// ⚠️ TWO STORE VIEW MODELS SHARE ONE PAYLOAD. `DestinationCoordinator` caches an instance
    /// for `filterForTools: true` and another for false, both for the app lifetime, and both read
    /// `MLXModelService.shared.availableModels`. Open the agent store, let it fetch `.all`, come
    /// back to the general store: the category still matches, so the old guard passed and this
    /// instance rendered the OTHER one's rows — then `loadMore` paged its own sort and offset into
    /// them, leaving a coverage hole no further click could fill.
    ///
    /// Local tabs are exempt: `.installed` is a disk scan and `.recommended` is served from
    /// `CuratedMLXCatalog`, so neither reads the shared array at all.
    var sharedPayloadIsForeign: Bool {
        Self.payloadIsForeign(
            category: selectedCategory,
            payloadCategory: service.availableModelsCategory,
            payloadSort: service.availableModelsSort,
            payloadSearch: service.availableModelsSearch,
            expectedSort: lastFetchedSort,
            expectedSearch: remoteSearchQuery
        )
    }

    /// The comparison itself. Pure and `nonisolated`, like `searchDestination` and
    /// `serverSortRefetch`, so it is testable without building a view model — whose `init` scans
    /// the disk and fetches from huggingface.co.
    ///
    /// ⚠️ `payloadCategory == nil` means nothing has been fetched this launch, which is NOT
    /// foreign: returning true there would make a cold store refetch on its own first appearance,
    /// on top of the fetch `init` already issued.
    nonisolated static func payloadIsForeign(
        category: StoreCategory,
        payloadCategory: String?,
        payloadSort: String?,
        payloadSearch: String?,
        expectedSort: String,
        expectedSearch: String?
    ) -> Bool {
        guard category != .installed, category != .recommended else { return false }
        guard payloadCategory != nil else { return false }
        return payloadCategory != category.rawValue
            || payloadSort != expectedSort
            || payloadSearch != expectedSearch
    }

    /// Re-queries when the shared payload belongs to the other store instance.
    ///
    /// Call this on re-entry: neither view model refetches on appear, so returning to a store
    /// whose payload was replaced while you were away otherwise shows the other one's results
    /// until you touch a control.
    func refreshIfSharedPayloadIsForeign() {
        guard sharedPayloadIsForeign else { return }
        logger.info("[MLXSTORE] Shared payload belongs to another store instance (category=\(self.service.availableModelsCategory ?? "<none>") sort=\(self.service.availableModelsSort ?? "<none>") vs mine \(self.selectedCategory.rawValue)/\(self.lastFetchedSort)). CONSEQUENCE: re-querying page 0 rather than rendering or paging another instance's results.")
        refreshCategoryData()
    }

    /// Drops a pending debounced search.
    ///
    /// ⚠️ Call this from any path that is ABOUT TO refresh. The debounced task carries only the
    /// intent to re-query; once another action has re-queried, that task either duplicates the
    /// request byte-for-byte or — after a category change — applies a routing decision computed
    /// against state the user has since moved on from.
    private func cancelPendingSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }

    /// Applies a debounced search change: either move to a tab that can answer it, or re-filter
    /// where we are.
    private func applySearchChange() {
        if let destination = Self.searchDestination(
            from: selectedCategory,
            query: searchText,
            autoLeftRecommended: didAutoLeaveRecommended
        ) {
            logger.info("[MLXSTORE] Search on the \(self.selectedCategory.rawValue) tab moved to \(destination.rawValue). CONSEQUENCE: the query is answered by HuggingFace instead of being dropped; the Recommended tab serves a fixed local list and issues no request.")
            didAutoLeaveRecommended = (destination == .all)
            isAutoSwitchingCategory = true
            selectedCategory = destination   // its `didSet` issues the refresh for the new tab
            isAutoSwitchingCategory = false
            return
        }
        // ⚠️ register A43 — `.filterChanged`, so the Installed tab re-filters without re-walking
        // the disk. Remote categories still issue their fetch: for those the search text is a
        // QUERY the server answers, not a client-side filter.
        refreshCategoryData(reason: .filterChanged)
    }

    private func refreshCategoryData(reason: RefreshReason = .userRequest) {
        currentPage = 0

        if selectedCategory == .recommended {
            // ⚠️ Restore the Installed tab's stashed sort HERE too. Only the remote branch did it,
            // so Installed → Recommended left `sortOption` on the forced `.recent` the user never
            // picked AND kept the stash — then a sort chosen on Recommended was silently
            // overwritten by that stale stash on the next move to a remote tab.
            if let restore = sortBeforeInstalledTab {
                isRestoringSort = true
                sortOption = restore
                isRestoringSort = false
                sortBeforeInstalledTab = nil
            }
            logger.info("Refresh: category=recommended — serving \(CuratedMLXCatalog.models.count) curated model(s) locally")
            applyFilterAndSort()
            // Sizes still come from HuggingFace so the cards show real numbers and the RAM
            // verdict has a denominator; one bounded fetch, not the 30-per-page fan-out.
            Task { await service.fetchSizesForCuratedModels() }
        } else if selectedCategory == .installed {
            // Default the Installed tab to most-recent-first, remembering what to restore.
            // This used to flip the sort and never put it back, so returning to All left the
            // user on "Recent" — which is meaningless for remote results and, before the
            // comparator was made total, reshuffled the grid on every size-update tick.
            if sortOption == .popularity {
                sortBeforeInstalledTab = sortOption
                sortOption = .recent
            }
            // Force: this path is reached from the Refresh button and from switching to the
            // Installed tab, both of which are explicit user requests for current data. The
            // debounce exists to absorb the init + onAppear double-fire, not to ignore the
            // user. (The comment here used to say the window was <2s while the constant was
            // 30s — a refresh could silently do nothing for half a minute.)
            //
            // ⚠️ register A43 — but NOT for a filter keystroke, which this comment predates and
            // was never written for. Filtering is client-side, so the scan could not change what
            // the user sees; it was pure I/O per typing pause, and worse on a custom models
            // directory pointed at an external or network volume.
            if reason == .userRequest {
                logger.info("Refresh: category=installed — scanning local models")
                service.forceRefreshInstalledModels()
            } else {
                logger.info("Refresh: category=installed — filter changed, re-filtering without a disk scan")
            }
            // The observer only fires when the model list actually CHANGED, so re-filter
            // unconditionally to render the installed cards for this tab immediately.
            applyFilterAndSort()
        } else {
            if let restore = sortBeforeInstalledTab {
                // ⚠️ Fence the assignment: `sortOption`'s didSet re-enters this function, and
                // `sortBeforeInstalledTab` is still non-nil at that instant — without the fence
                // this recurses forever.
                isRestoringSort = true
                sortOption = restore
                isRestoringSort = false
                sortBeforeInstalledTab = nil
            }
            // ⚠️ `remoteSearchQuery`, not `searchText`: the quantization is part of the QUERY.
            let search = remoteSearchQuery
            // A size sort has no server equivalent, so keep the ranking the loaded results were
            // fetched with rather than silently reverting the listing to `downloads`.
            let serverSort = sortOption.hfSort ?? lastFetchedSort
            lastFetchedSort = serverSort
            logger.info("Refresh: category=\(self.selectedCategory.rawValue) search=\(search ?? "<none>") sort=\(serverSort) clientCapability=\(self.selectedCategory.clientCapability?.rawValue ?? "<none>")")

            // Clear stale cards from the prior tab so the loading UI shows
            // instead of (incorrectly) rendering the previous category's
            // models until the remote fetch completes.
            //
            // `isLoading` is set here, synchronously, alongside the clear. The service sets
            // its own flag two actor hops later, so for those two hops the grid was empty
            // AND not-loading — which is exactly the "No models found" empty state. Every
            // category switch flashed it.
            isLoading = true
            loadError = nil
            displayedModels = []

            Task { [category = selectedCategory.rawValue, serverSort] in
                await service.fetchRemoteModels(
                    limit: pageSize,
                    offset: 0,
                    tags: nil,
                    search: search,
                    append: false,
                    category: category,
                    sort: serverSort
                )
            }
        }
    }
    
    /// Triggered manually or by publisher changes to update the displayed list
    private func applyFilterAndSort() {
        displayedModels = filterAndSortModels(
            remote: service.availableModels,
            local: service.installedModels,
            query: searchText,
            category: selectedCategory,
            sort: sortOption
        )
    }
    
    func loadMore() {
        // ⚠️ `.recommended` TOO, not just `.installed`. Both are served from a fixed local set, so
        // paging either spends a listing request plus ~30 per-repo size lookups and then changes
        // nothing: `filterAndSortModels` sources the curated tab from `CuratedMLXCatalog` and
        // never looks at what the fetch appended.
        guard selectedCategory != .installed, selectedCategory != .recommended else { return }

        // ⚠️ NEVER APPEND ONTO ANOTHER INSTANCE'S RESULTS. The offset below is measured against
        // the shared array, so if that array came from a different query the page we ask for is
        // indexed into a ranking we are not showing. Re-query page 0 instead — the grid is already
        // displaying the wrong rows at this point, so refetching is a correction, not a loss.
        guard !sharedPayloadIsForeign else {
            logger.info("[MLXSTORE] LoadMore REFUSED — the shared payload is another store instance's. CONSEQUENCE: re-querying page 0 for this instance instead of paging into a ranking it never fetched.")
            refreshCategoryData()
            return
        }

        // ⚠️ THE OFFSET COMES FROM WHAT ACTUALLY LANDED, not from an optimistic page counter.
        // `currentPage += 1` was applied before the fetch and never rolled back, so a 429 or a
        // dropped connection — which the service handles by leaving `availableModels` untouched
        // when `append` is true — left the counter one ahead. The next click then asked for
        // `skip=60` and rows 30-59 were never fetched: a permanent hole no further action could
        // fill short of a full refresh.
        let offset = service.availableModels.count
        currentPage += 1
        // ⚠️ Must match `refreshCategoryData` exactly. Sending the bare `searchText` here would
        // append an UNFILTERED page 2 under a filtered page 1 — and because the client filter in
        // `filterAndSortModels` then drops nearly all of it, "Load More" would appear to do
        // nothing while still spending a request.
        let search = remoteSearchQuery
        logger.info("LoadMore: page=\(self.currentPage) offset=\(offset) sort=\(self.lastFetchedSort) search=\(search ?? "<none>") currentAvailable=\(self.service.availableModels.count)")

        // ⚠️ `lastFetchedSort`, NOT `sortOption.hfSort`. `skip=offset` is only meaningful against
        // the ranking that produced pages 0..n-1, and a size sort deliberately does not re-query —
        // so it must keep paging the listing it started on.
        Task { [category = selectedCategory.rawValue, sort = lastFetchedSort] in
            await service.fetchRemoteModels(
                limit: pageSize,
                offset: offset,
                tags: nil,
                search: search,
                append: true,
                category: category,
                sort: sort
            )
        }
    }
    
    private func filterAndSortModels(
        remote: [MLXDisplayModel],
        local: [MLXModelItem],
        query: String,
        category: StoreCategory,
        sort: SortOption
    ) -> [MLXDisplayModel] {
        
        var sourceModels: [MLXDisplayModel]

        // 1. Select Source
        if category == .recommended {
            let ramGB = Int(SystemHardwareProfiler.shared.profile.totalRAM / (1024 * 1024 * 1024))
            sourceModels = CuratedMLXCatalog.recommended(forSystemRAMGB: ramGB).map { curated in
                MLXDisplayModel(
                    id: curated.id,
                    size: service.modelSizes[curated.id] ?? curated.formattedSize,
                    sizeBytes: service.modelSizeBytes[curated.id] ?? curated.approximateBytes,
                    quantization: MLXQuantization.parse(fromRepoId: curated.id),
                    capabilities: service.classifyCapabilities(tags: [], pipeline: nil, id: curated.id),
                    tags: ["Recommended"],
                    downloads: 0,
                    likes: 0,
                    description: curated.rationale
                )
            }
        } else if category == .installed {
            sourceModels = local.map { item in
                
                // Use cached profile from MLXModelService instead of re-parsing files
                let profile = service.cachedCognitiveProfile(for: item)
                var caps: Set<MLXModelCapability> = []
                
                if profile.capability != .none {
                    caps.insert(.toolUse)
                }
                
                let lowerId = item.displayName.lowercased()
                // Reasoning badge: check the centralized heuristics (catches qwq, magistral,
                // gpt-oss, o1/o3/o4 families) plus the generic "reasoning" / "chain-of-thought"
                // keywords users/publishers sometimes add to model names.
                if ModelCapabilityHeuristics.isReasoningOnly(nameCandidates: item.displayName) ||
                   lowerId.contains("reasoning") || lowerId.contains("chain-of-thought") {
                    caps.insert(.reasoning)
                }
                if lowerId.contains("coder") || lowerId.contains("code") || lowerId.contains("codellama") || lowerId.contains("qwen2.5-coder") {
                    caps.insert(.coding)
                }
                if lowerId.contains("vision") || lowerId.contains("vl") || lowerId.contains("llava") || lowerId.contains("pixtral") || lowerId.contains("qwen2-vl") {
                    caps.insert(.vision)
                }
                
                // Fallback to text generation if nothing matches
                if caps.isEmpty {
                    caps.insert(.textGeneration)
                }
                
                // Installed models used to be mapped with `size: nil`, so the Installed tab
                // showed no disk figure, suppressed the fit badge, and made "Sort by size" a
                // silent no-op there. Sizes arrive from the background sizing pass.
                let bytes = service.installedSizeBytes[item.displayName]
                return MLXDisplayModel(
                    id: item.displayName,
                    size: bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                    sizeBytes: bytes,
                    quantization: MLXQuantization.parse(fromRepoId: item.displayName),
                    capabilities: caps,
                    tags: ["Installed"],
                    downloads: 0,
                    likes: 0,
                    description: nil,
                    createdAt: item.createdAt
                )
            }
            
            // Soft filter only, and only while the user leaves the toggle on. `capabilities`
            // here comes from substring matching over the model id, so a false negative is
            // routine for any newly-released family, re-quantized upload or personal
            // fine-tune. Hiding those outright removed the only way to reach them.
            if filterForTools && showToolCapableOnly {
                sourceModels = sourceModels.filter { $0.capabilities.contains(.toolUse) }
            }
            
        } else {
            // Only use the remote payload if it was actually fetched for this category.
            // ⚠️ Category AND ranking AND search — see `sharedPayloadIsForeign`. Matching on the
            // category alone let the other store instance's `.all` page render here as ours.
            guard service.availableModelsCategory == nil
                    || (service.availableModelsCategory == category.rawValue
                        && service.availableModelsSort == lastFetchedSort
                        && service.availableModelsSearch == remoteSearchQuery) else {
                // ⚠️ This early return sits ABOVE the fit block, so without this the count from
                // the PREVIOUS tab survives: switching tabs rendered "(8 hidden)" over an empty,
                // loading grid for the whole round trip. The property exists to stop a filter
                // emptying the grid silently — saying something false instead is worse.
                hiddenByFitFilter = 0
                return []
            }
            sourceModels = remote

            // Filter remote results by category capability (client-side).
            // HF's server-side tag filter is too restrictive (authors rarely add
            // `tool-use`/`reasoning` tags), so we rely on `classifyCapabilities`
            // heuristics baked into `MLXDisplayModel.capabilities`.
            // NOTE: no log here — `applyFilterAndSort` is invoked on every
            // observer tick (including per-model size updates), so logging
            // would emit 30+ lines per fetch.
            if let cap = category.clientCapability {
                sourceModels = sourceModels.filter { $0.capabilities.contains(cap) }
            }
        }

        // 2. Filter by quantization when the user has narrowed to one.
        if let quantizationFilter {
            sourceModels = sourceModels.filter { $0.quantization == quantizationFilter }
        }

        // 2b. "Fits my Mac" — the RAM advisory used as a filter, because the user asked for it.
        //
        // ⚠️ NEVER on the Installed tab. That tab is the only surface carrying Delete, and the
        // model a user most needs to reach there is the oversized one they want gone. Installed
        // cards are also sizeless until the background sizing pass lands, so they would all read
        // `.unknown` on first paint anyway.
        //
        // ⚠️ `ModelFitAdvisor.verdict`, not `assess`: `assess` logs one line per model and this
        // runs on every observer tick. Same reason the capability filter above has no log.
        //
        // The three arguments are deliberately identical to `ModelCardView.fitAssessment`, so a
        // card can never be hidden while its own badge shows a different verdict.
        if fitsMyMacOnly && category != .installed {
            let before = sourceModels.count
            sourceModels = sourceModels.filter { model in
                Self.passesFitFilter(ModelFitAdvisor.verdict(
                    metadata: MLXQuantization.fitMetadata(forRepoId: model.id),
                    diskSizeString: model.size,
                    diskSizeBytes: model.sizeBytes
                ))
            }
            hiddenByFitFilter = before - sourceModels.count
        } else {
            hiddenByFitFilter = 0
        }

        // 3. Filter by search text.
        //
        // ⚠️ ONLY `.installed` FILTERS CLIENT-SIDE. Every other tab's query is answered by
        // HuggingFace, so filtering here as well would narrow the server's own answer.
        // This used to read `|| !isRemoteSearchEnabled` — a property initialised to `true` and
        // assigned nowhere in the repo, which made the whole branch dead and left `.recommended`
        // with neither a remote fetch nor a local filter. That combination is what made typing
        // on the first-run tab do nothing at all; `applySearchChange` now routes such a query to
        // `.all`, where it is really answered.
        let filtersLocally = category == .installed
        if !query.isEmpty && filtersLocally {
            sourceModels = sourceModels.filter { model in
                model.displayName.localizedCaseInsensitiveContains(query) ||
                (model.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        
        // 3. Sort.
        //
        // Every comparator below tie-breaks down to `id`. Swift's `sort` is introsort and is
        // NOT stable, so a comparator that returns false for every pair (which "Recent" did
        // for remote models, since none carried a date) permutes the array arbitrarily —
        // cards visibly jumped under the cursor on each of the ~30 size-update ticks.
        // The curated list is ordered deliberately — what this machine can run, smallest
        // first — so a popularity sort (every entry has 0 downloads) would scramble it.
        if category == .recommended { return sourceModels }

        switch sort {
        case .popularity:
            // The HF query is already `sort=downloads&direction=-1`, but appended pages and
            // locally-sourced rows are not, so make the order explicit rather than implied.
            sourceModels.sort { lhs, rhs in
                lhs.downloads == rhs.downloads ? lhs.id < rhs.id : lhs.downloads > rhs.downloads
            }

        case .recent:
            sourceModels.sort { lhs, rhs in
                let l = lhs.createdAt, r = rhs.createdAt
                if let l, let r, l != r { return l > r }
                if (l == nil) != (r == nil) { return l != nil }  // dated entries first
                return lhs.id < rhs.id
            }

        case .sizeSmallest:
            sourceModels.sort { lhs, rhs in
                sortableBytes(lhs) == sortableBytes(rhs)
                    ? lhs.id < rhs.id
                    : sortableBytes(lhs) < sortableBytes(rhs)
            }

        case .sizeLargest:
            sourceModels.sort { lhs, rhs in
                sortableBytes(lhs) == sortableBytes(rhs)
                    ? lhs.id < rhs.id
                    : sortableBytes(lhs) > sortableBytes(rhs)
            }
        }

        return sourceModels
    }

    /// Sort key for size. Models whose size hasn't loaded sort last in both directions
    /// rather than pretending to be 0 bytes (which put every unsized card at the top of
    /// "Smallest").
    private func sortableBytes(_ model: MLXDisplayModel) -> Int64 {
        model.sizeBytes ?? Int64.max
    }
    
    
    // MARK: - Actions
    
    /// ⚠️ This used to fall back to `installed.displayName.contains(model.displayName)`.
    /// `model.displayName` is the bare name with the org stripped, so the substring test
    /// matched any installed model that merely *contained* it — a different quantization,
    /// a suffixed variant (`…-4bit` inside `…-4bit-DWQ`), or another org entirely. The card
    /// then rendered a green "Installed" capsule, and since the Download affordance only
    /// exists in the `else` branch there was no way to download that model at all.
    /// Goes through the shared comparator now, which never uses substrings.
    func isInstalled(_ model: MLXDisplayModel) -> Bool {
        service.isInstalled(repoId: model.id)
    }
    
    func downloadModel(_ model: MLXDisplayModel) {
        service.downloadModel(repoId: model.id)
    }
    
    func deleteModel(_ model: MLXDisplayModel) {
        guard let item = service.installedModel(named: model.id) else {
            // Was a silent no-op: the strict `==` lookup here disagreed with the lenient
            // `isInstalled` used to render the card, so a card could offer Delete on a model
            // this lookup could not find, and nothing happened or was logged.
            logger.error("[MLXSTORE] Delete requested for '\(model.id)' but it is not in the installed list (\(self.service.installedModels.count) model(s)). CONSEQUENCE: nothing was deleted and the card still shows it as installed — the list is stale, refresh the store.")
            return
        }
        Task { await service.deleteModel(item) }
    }
    
    func cancelDownload() {
        service.cancelDownload()
    }
    
    func refresh() {
        refreshCategoryData()
    }

    /// Clears the banner and the service flag together. Leaving `errorMessage` set would make
    /// the DownloadManager bridge classify the NEXT download's terminal state as failed.
    func dismissDownloadError() {
        downloadError = nil
        service.errorMessage = nil
    }
}
