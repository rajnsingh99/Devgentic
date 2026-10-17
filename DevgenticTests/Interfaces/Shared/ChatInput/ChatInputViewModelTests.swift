// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatInputViewModelTests.swift
//  DevgenticTests
//
//  Tests for ChatInputViewModel — state management, suggestion navigation,
//  API key validation, voice input state machine, and delegate mediation.
//  All external services are mocked; no UI or view-layer testing.
//

import XCTest
import Combine
import AppKit
@testable import devgentic

// MARK: - Mock Recognition Service

final class MockRecognitionService: RecognitionServiceProtocol {
    var loadingState: ModelLoadingState = .loaded
    private let loadingStateSubject = CurrentValueSubject<ModelLoadingState, Never>(.loaded)

    var loadingStatePublisher: AnyPublisher<ModelLoadingState, Never> {
        loadingStateSubject.eraseToAnyPublisher()
    }

    var transcribeCallCount = 0
    var transcribeResult: String? = "test transcription"
    func transcribe(audioArray: [Float]) async throws -> String? {
        transcribeCallCount += 1
        return transcribeResult
    }

    var startStreamingCallCount = 0
    var startStreamingError: Error?
    var lastStartOwner: VoiceSurface?
    var onStateChangeCallback: ((StreamingTranscriptionState) -> Void)?
    func startStreaming(owner: VoiceSurface, onStateChange: @escaping (StreamingTranscriptionState) -> Void) async throws {
        startStreamingCallCount += 1
        lastStartOwner = owner
        onStateChangeCallback = onStateChange
        if let error = startStreamingError { throw error }
    }

    var stopStreamingCallCount = 0
    var stopStreamingResult: String? = "final transcript"
    func stopStreaming() async -> String? {
        stopStreamingCallCount += 1
        return stopStreamingResult
    }

    var switchModelCallCount = 0
    func switchModel(to modelName: String) async throws {
        switchModelCallCount += 1
    }

    var currentLanguage: String? = nil
    func setLanguage(_ language: String?) { currentLanguage = language }

    var isAutoStopEnabled: Bool = false
    func setAutoStopEnabled(_ enabled: Bool) { isAutoStopEnabled = enabled }

    func simulateLoadingState(_ state: ModelLoadingState) {
        loadingState = state
        loadingStateSubject.send(state)
    }
}

// MARK: - Mock Prompt Service

final class MockPromptService: PromptServiceProtocol {
    var prompts: [DevPrompt] = []
    var usageRecords: [UUID] = []

    func getAllPrompts() -> [DevPrompt] {
        return prompts
    }

    func recordUsage(of prompt: DevPrompt) {
        usageRecords.append(prompt.id)
    }
}

// MARK: - Mock Main Delegate

@Observable @MainActor
final class MockChatInputMainDelegate: ChatInputMainDelegate {
    var attachedFiles: [FileSystemItem] = []
    var streamingMessageID: UUID? = nil

    @ObservationIgnored var addFileCallCount = 0
    func addAttachedFile(fileItem: FileSystemItem) { addFileCallCount += 1 }

    @ObservationIgnored var addFilesCallCount = 0
    @ObservationIgnored var lastAddedFiles: [FileSystemItem] = []
    func addAttachedFiles(fileItems: [FileSystemItem]) { addFilesCallCount += 1; lastAddedFiles = fileItems }

    @ObservationIgnored var removeFileCallCount = 0
    func removeAttachedFile(fileItem: FileSystemItem) { removeFileCallCount += 1 }

    @ObservationIgnored var cancelStreamingCallCount = 0
    func cancelStreamingResponse() { cancelStreamingCallCount += 1 }

    @ObservationIgnored var historyResponses: [String] = []
    @ObservationIgnored private var historyIndex = 0
    func getQueryFromHistory(direction: MainApplicationViewModel.QueryNavigationDirection) -> String? {
        guard historyIndex < historyResponses.count else { return nil }
        let result = historyResponses[historyIndex]
        historyIndex += 1
        return result
    }

    @ObservationIgnored var resetHistoryCallCount = 0
    func resetQueryHistoryIndex() { resetHistoryCallCount += 1 }

    func simulateStreamingStart() {
        streamingMessageID = UUID()
    }

    func simulateStreamingEnd() {
        streamingMessageID = nil
    }

    func simulateAttachedFiles(_ files: [FileSystemItem]) {
        attachedFiles = files
    }
}

// MARK: - Test Helpers

private func makePrompt(title: String, text: String = "body") -> DevPrompt {
    DevPrompt(title: title, text: text, category: "Test", isUserDefined: true)
}

private func makeFileItem(name: String) -> FileSystemItem {
    let url = URL(fileURLWithPath: "/tmp/\(name)")
    return FileSystemItem(id: url, name: name, url: url, isDirectory: false)
}

// MARK: - Tests

@MainActor
final class ChatInputViewModelTests: XCTestCase {

    private var mockRecognition: MockRecognitionService!
    private var mockPromptService: MockPromptService!
    private var mockDelegate: MockChatInputMainDelegate!
    private var sut: ChatInputViewModel!

    @MainActor
    override func setUp() {
        super.setUp()
        mockRecognition = MockRecognitionService()
        mockPromptService = MockPromptService()
        mockDelegate = MockChatInputMainDelegate()

        sut = ChatInputViewModel(
            recognitionService: mockRecognition,
            promptService: mockPromptService
        )
        sut.mainDelegate = mockDelegate
        sut.setupMainDelegateObservers()
    }

    @MainActor
    override func tearDown() {
        sut = nil
        mockDelegate = nil
        mockPromptService = nil
        mockRecognition = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(sut.userInput, "")
        XCTAssertFalse(sut.isStreaming)
        XCTAssertTrue(sut.attachedFiles.isEmpty)
        XCTAssertFalse(sut.showModelSelectorPopover)
    }

    func testInitialSuggestionStates() {
        XCTAssertFalse(sut.promptSuggestionState.isShowing)
        XCTAssertTrue(sut.promptSuggestionState.filteredItems.isEmpty)
        XCTAssertFalse(sut.fileSuggestionState.isShowing)
        XCTAssertTrue(sut.fileSuggestionState.filteredItems.isEmpty)
    }

    // MARK: - Delegate Mediation

    func testAddAttachedFileDelegatesToMain() {
        let file = makeFileItem(name: "test.swift")
        sut.addAttachedFile(fileItem: file)
        XCTAssertEqual(mockDelegate.addFileCallCount, 1)
    }

    func testAddMultipleFilesDelegatesToMain() {
        let files = [makeFileItem(name: "a.swift"), makeFileItem(name: "b.swift")]
        sut.addAttachedFiles(fileItems: files)
        XCTAssertEqual(mockDelegate.addFilesCallCount, 1)
    }

    // MARK: - Binary attachment gate
    //
    // Regression: `@Ja` auto-focused `January2026.class` (sorts before `.java`), it was
    // attached, and the send path's UTF-8 read dropped it — the model got the prompt alone.

    private func writeTempFile(_ name: String, _ bytes: [UInt8]) throws -> FileSystemItem {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return FileSystemItem(id: url, name: name, url: url, isDirectory: false)
    }

    /// Java class-file header: CAFEBABE magic, then a NUL-bearing version field.
    private let classFileBytes: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41, 0x00, 0x1F]

    func testBinaryAttachmentIsRefusedAndNeverReachesTheDelegate() throws {
        let binary = try writeTempFile("January2026.class", classFileBytes)

        let refused = sut.addAttachedFile(fileItem: binary)

        XCTAssertEqual(refused.map(\.item.name), ["January2026.class"])
        XCTAssertEqual(mockDelegate.addFileCallCount, 0, "a refused binary must not be attached")
        XCTAssertEqual(mockDelegate.addFilesCallCount, 0)
    }

    func testMixedSelectionAttachesOnlyTheTextFiles() throws {
        let binary = try writeTempFile("January2026.class", classFileBytes)
        let source = try writeTempFile("January2026.java", Array("class January2026 {}".utf8))

        let refused = sut.addAttachedFiles(fileItems: [binary, source])

        XCTAssertEqual(refused.map(\.item.name), ["January2026.class"])
        XCTAssertEqual(mockDelegate.lastAddedFiles.map(\.name), ["January2026.java"])
    }

    /// Wiring: the composer's mode reaches intake — a folder is refused for an injecting
    /// profile and attached for a stateless one.
    func testFolderIsRefusedOnlyWhenTheProfileInjects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let folder = FileSystemItem(id: dir, name: "java", url: dir, isDirectory: true)

        XCTAssertEqual(sut.addAttachedFile(fileItem: folder, deliveryMode: .inject(includeAbsolutePaths: false)).map(\.item.name), ["java"])
        XCTAssertEqual(mockDelegate.addFileCallCount, 0)

        XCTAssertTrue(sut.addAttachedFile(fileItem: folder, deliveryMode: .pathManifest).isEmpty)
        XCTAssertEqual(mockDelegate.addFileCallCount, 1)
    }

    /// A folder attached under a stateless profile is REMOVED when the active profile becomes
    /// one that injects contents — not left to fail at send. Text files stay.
    func testRecheckRemovesWhatTheNewProfileCannotCarry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let folder = FileSystemItem(id: dir, name: "java", url: dir, isDirectory: true)
        let source = try writeTempFile("Main.java", Array("class Main {}".utf8))
        mockDelegate.attachedFiles = [folder, source]
        sut.setupMainDelegateObservers()   // refresh the mirrored snapshot

        XCTAssertTrue(sut.recheckAttachments(deliveryMode: .pathManifest).isEmpty, "a stateless agent can list the folder")
        XCTAssertEqual(mockDelegate.removeFileCallCount, 0)

        let removed = sut.recheckAttachments(deliveryMode: .inject(includeAbsolutePaths: false))
        XCTAssertEqual(removed.map(\.item.name), ["java"])
        XCTAssertEqual(mockDelegate.removeFileCallCount, 1, "only the folder leaves; the text file stays")
    }

    // MARK: - @ picker re-sync

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A fresh `@` has the empty query — the same as last time — so no search ran: the popup
    /// showed the PREVIOUS folder's files (screenshots, 2026-10-04) or "Type to search". Opening
    /// must search at once, closing must forget, and reopening must list what is there NOW.
    func testOpeningThePickerSearchesTheCurrentFolderEveryTime() async throws {
        var folderFiles = [makeFileItem(name: "adk.py")]
        var searches = 0
        sut.onFileSearchRequest = { _ in
            searches += 1
            return (folderFiles, [], .ready)
        }

        sut.fileSuggestionState.isShowing = true
        try await waitFor { self.sut.fileSuggestionState.hasResults }
        XCTAssertEqual(sut.fileSuggestionState.filteredItems.map(\.name), ["adk.py"])

        sut.fileSuggestionState.isShowing = false
        try await waitFor { !self.sut.fileSuggestionState.hasResults }
        XCTAssertTrue(sut.fileSuggestionState.filteredItems.isEmpty, "closing forgets the old folder's list")

        folderFiles = [makeFileItem(name: "app.py")]   // the user switched folders
        sut.fileSuggestionState.isShowing = true       // same empty query as before
        try await waitFor { self.sut.fileSuggestionState.hasResults }
        XCTAssertEqual(sut.fileSuggestionState.filteredItems.map(\.name), ["app.py"])
        XCTAssertEqual(searches, 2, "every open searches, even with an unchanged query")
    }

    func testThePickerKnowsWhyItIsEmpty() async throws {
        sut.onFileSearchRequest = { _ in ([], [], .noFolder) }
        sut.fileSuggestionState.isShowing = true
        try await waitFor { self.sut.fileSuggestionState.hasResults }
        XCTAssertEqual(sut.fileSuggestionState.source, .noFolder)
    }

    func testEmptyStateMessages() {
        typealias V = FileSuggestionView
        XCTAssertTrue(V.emptyMessage(source: .noFolder, hasResults: true, query: "").contains("No folder open"))
        XCTAssertEqual(V.emptyMessage(source: .indexing, hasResults: false, query: ""), "Indexing files…")
        XCTAssertEqual(V.emptyMessage(source: .ready, hasResults: false, query: ""), "Searching…",
                       "not-yet-searched is not 'no files'")
        XCTAssertEqual(V.emptyMessage(source: .ready, hasResults: true, query: ""), "No files in this folder.")
        XCTAssertEqual(V.emptyMessage(source: .ready, hasResults: true, query: "zz"), "No matching files found.")
    }

    func testTextAttachmentIsAccepted() throws {
        let source = try writeTempFile("January2026.java", Array("class January2026 {}".utf8))

        XCTAssertTrue(sut.addAttachedFile(fileItem: source).isEmpty)
        XCTAssertEqual(mockDelegate.addFileCallCount, 1)
    }

    func testRemoveAttachedFileDelegatesToMain() {
        let file = makeFileItem(name: "test.swift")
        sut.removeAttachedFile(fileItem: file)
        XCTAssertEqual(mockDelegate.removeFileCallCount, 1)
    }

    func testCancelStreamingDelegatesToMain() {
        sut.cancelStreamingResponse()
        XCTAssertEqual(mockDelegate.cancelStreamingCallCount, 1)
    }

    func testResetQueryHistoryDelegatesToMain() {
        sut.resetQueryHistoryIndex()
        XCTAssertEqual(mockDelegate.resetHistoryCallCount, 1)
    }

    // MARK: - Streaming State Mirroring

    func testStreamingStateMirrorsDelegate() {
        let expectation = XCTestExpectation(description: "isStreaming becomes true")

        withObservationTracking {
            _ = sut.isStreaming
        } onChange: {
            Task { @MainActor in expectation.fulfill() }
        }

        mockDelegate.simulateStreamingStart()

        wait(for: [expectation], timeout: 2.0)
    }

    func testAttachedFilesMirrorDelegate() {
        let expectation = XCTestExpectation(description: "attachedFiles updated")
        let file = makeFileItem(name: "mirrored.swift")

        withObservationTracking {
            _ = sut.attachedFiles
        } onChange: {
            Task { @MainActor in expectation.fulfill() }
        }

        mockDelegate.simulateAttachedFiles([file])

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Suggestion Navigation

    func testNavigatePromptSuggestionsDown() {
        let p1 = makePrompt(title: "A")
        let p2 = makePrompt(title: "B")
        let p3 = makePrompt(title: "C")
        sut.promptSuggestionState.filteredItems = [p1, p2, p3]
        sut.promptSuggestionState.selectedID = p1.id

        sut.navigateSuggestions(direction: .down, type: .prompt)
        XCTAssertEqual(sut.promptSuggestionState.selectedID, p2.id)

        sut.navigateSuggestions(direction: .down, type: .prompt)
        XCTAssertEqual(sut.promptSuggestionState.selectedID, p3.id)
    }

    func testNavigatePromptSuggestionsUp() {
        let p1 = makePrompt(title: "A")
        let p2 = makePrompt(title: "B")
        sut.promptSuggestionState.filteredItems = [p1, p2]
        sut.promptSuggestionState.selectedID = p1.id

        sut.navigateSuggestions(direction: .up, type: .prompt)
        // Wraps to last item
        XCTAssertEqual(sut.promptSuggestionState.selectedID, p2.id)
    }

    func testNavigateDownWrapsAround() {
        let p1 = makePrompt(title: "A")
        let p2 = makePrompt(title: "B")
        sut.promptSuggestionState.filteredItems = [p1, p2]
        sut.promptSuggestionState.selectedID = p2.id

        sut.navigateSuggestions(direction: .down, type: .prompt)
        XCTAssertEqual(sut.promptSuggestionState.selectedID, p1.id, "Should wrap to first item")
    }

    func testNavigateWithNoItemsIsNoop() {
        sut.promptSuggestionState.filteredItems = []
        sut.promptSuggestionState.selectedID = nil

        sut.navigateSuggestions(direction: .down, type: .prompt)
        XCTAssertNil(sut.promptSuggestionState.selectedID)
    }

    func testNavigateWithNoSelectionSelectsFirst() {
        let p1 = makePrompt(title: "A")
        sut.promptSuggestionState.filteredItems = [p1]
        sut.promptSuggestionState.selectedID = nil

        sut.navigateSuggestions(direction: .down, type: .prompt)
        XCTAssertEqual(sut.promptSuggestionState.selectedID, p1.id)
    }

    func testNavigateFileSuggestions() {
        let f1 = makeFileItem(name: "a.swift")
        let f2 = makeFileItem(name: "b.swift")
        sut.fileSuggestionState.filteredItems = [f1, f2]
        sut.fileSuggestionState.selectedID = f1.id

        sut.navigateSuggestions(direction: .down, type: .file)
        XCTAssertEqual(sut.fileSuggestionState.selectedID, f2.id)
    }

    // MARK: - Select Prompt

    func testSelectPromptCreatesInsertionRequest() {
        let prompt = makePrompt(title: "Test", text: "Hello World")
        sut.promptSuggestionState.triggerRange = NSRange(location: 5, length: 3)
        sut.promptSuggestionState.isShowing = true

        sut.selectPrompt(prompt)

        XCTAssertNotNil(sut.attributedTextInsertionRequest)
        XCTAssertEqual(sut.attributedTextInsertionRequest?.range.location, 5)
        let insertedString = sut.attributedTextInsertionRequest?.attributedString.string
        XCTAssertEqual(insertedString, "Hello World ", "Should append space after prompt text")
    }

    func testSelectPromptResetsState() {
        let prompt = makePrompt(title: "Test")
        sut.promptSuggestionState.triggerRange = NSRange(location: 0, length: 1)
        sut.promptSuggestionState.isShowing = true
        sut.promptSuggestionState.query = "tes"

        sut.selectPrompt(prompt)

        XCTAssertFalse(sut.promptSuggestionState.isShowing)
        XCTAssertEqual(sut.promptSuggestionState.query, "")
        XCTAssertNil(sut.promptSuggestionState.triggerRange)
    }

    func testSelectPromptWithNoTriggerRangeIsNoop() {
        let prompt = makePrompt(title: "Test")
        sut.promptSuggestionState.triggerRange = nil

        sut.selectPrompt(prompt)

        XCTAssertNil(sut.attributedTextInsertionRequest)
    }

    // MARK: - Select File

    func testSelectFileReturnsFile() {
        let file = makeFileItem(name: "main.swift")
        sut.fileSuggestionState.triggerRange = NSRange(location: 0, length: 5)

        let returned = sut.selectFile(file)
        XCTAssertEqual(returned.name, "main.swift")
    }

    func testSelectFileResetsState() {
        let file = makeFileItem(name: "main.swift")
        sut.fileSuggestionState.triggerRange = NSRange(location: 0, length: 5)
        sut.fileSuggestionState.isShowing = true
        sut.fileSuggestionState.query = "mai"

        _ = sut.selectFile(file)

        XCTAssertFalse(sut.fileSuggestionState.isShowing)
        XCTAssertEqual(sut.fileSuggestionState.query, "")
    }

    func testSelectMultipleFilesResetsState() {
        let files = [makeFileItem(name: "a.swift"), makeFileItem(name: "b.swift")]
        sut.fileSuggestionState.triggerRange = NSRange(location: 0, length: 1)
        sut.fileSuggestionState.isShowing = true

        sut.selectMultipleFiles(files)

        XCTAssertFalse(sut.fileSuggestionState.isShowing)
    }

    // MARK: - Process File Candidates (Filtering)

    func testProcessFileCandidatesExcludesAlreadyAttached() {
        let expectation = XCTestExpectation(description: "file filtering complete")

        let fileA = makeFileItem(name: "a.swift")
        let fileB = makeFileItem(name: "b.swift")
        let fileC = makeFileItem(name: "c.swift")

        withObservationTracking {
            _ = sut.fileSuggestionState
        } onChange: {
            Task { @MainActor in expectation.fulfill() }
        }

        sut.processFileCandidates([fileA, fileB, fileC], attachedFiles: [fileB])

        wait(for: [expectation], timeout: 2.0)

        // fileB was attached, so should be excluded
        let ids = sut.fileSuggestionState.filteredItems.map(\.name)
        XCTAssertFalse(ids.contains("b.swift"))
        XCTAssertTrue(ids.contains("a.swift"))
        XCTAssertTrue(ids.contains("c.swift"))
    }

    // MARK: - Voice Input Toggle State Machine

    func testToggleVoiceInputFromIdleShowsPopover() {
        sut.voiceInputState = .idle
        sut.toggleVoiceInput()
        XCTAssertTrue(sut.showModelSelectorPopover, "Should show model selector when idle")
    }

    func testToggleVoiceInputFromErrorShowsPopover() {
        sut.voiceInputState = .error("load failed")
        sut.toggleVoiceInput()
        XCTAssertTrue(sut.showModelSelectorPopover, "Should show model selector on error")
    }

    // MARK: - Cancel Recording

    func testCancelRecordingResetsState() {
        sut.voiceInputState = .recording
        sut.userInput = "partial text"
        sut.recordingDisplay.liveTranscriptionText = "live text"
        sut.recordingDisplay.powerLevels = [0.5, 0.8]
        sut.recordingDisplay.recordingTime = 15.0

        sut.cancelRecording()

        XCTAssertEqual(sut.voiceInputState, .available)
        XCTAssertEqual(sut.userInput, "")
        XCTAssertEqual(sut.recordingDisplay.liveTranscriptionText, "")
        XCTAssertTrue(sut.recordingDisplay.powerLevels.isEmpty)
        XCTAssertEqual(sut.recordingDisplay.recordingTime, 0.0)
    }

    func testCancelRecordingCallsStopStreaming() {
        sut.voiceInputState = .recording
        sut.cancelRecording()

        // Give async task time to execute
        let expectation = XCTestExpectation(description: "stopStreaming called")
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if self.mockRecognition.stopStreamingCallCount > 0 {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Select Downloaded Model

    func testSelectDownloadedModelPersistsAndDismissesPopover() {
        sut.showModelSelectorPopover = true

        sut.selectDownloadedModel("small.en")

        XCTAssertFalse(sut.showModelSelectorPopover)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppSettings.speechModelKey), "small.en")
    }

    // MARK: - currentSpeechModelName

    func testCurrentSpeechModelNameReadsUserDefaults() {
        UserDefaults.standard.set("medium.en", forKey: AppSettings.speechModelKey)
        XCTAssertEqual(sut.currentSpeechModelName, "medium.en")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppSettings.speechModelKey)
    }

    func testCurrentSpeechModelNameDefaultsToBaseEn() {
        UserDefaults.standard.removeObject(forKey: AppSettings.speechModelKey)
        XCTAssertEqual(sut.currentSpeechModelName, "base.en")
    }

    // MARK: - Recording Display Store Isolation

    func testRecordingDisplayStoreIsIsolated() {
        // Verify the display store is a separate object, not triggering ViewModel objectWillChange
        let store = sut.recordingDisplay
        XCTAssertNotNil(store)
        store.powerLevels = [1.0, 2.0, 3.0]
        XCTAssertEqual(store.powerLevels.count, 3)
        store.recordingTime = 42.0
        XCTAssertEqual(store.recordingTime, 42.0)
    }

    // MARK: - PromptSuggestionState / FileSuggestionState

    func testPromptSuggestionStateDefaults() {
        let state = PromptSuggestionState()
        XCTAssertFalse(state.isShowing)
        XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.filteredItems.isEmpty)
        XCTAssertNil(state.triggerRange)
        XCTAssertNil(state.selectedID)
    }

    func testFileSuggestionStateDefaults() {
        let state = FileSuggestionState()
        XCTAssertFalse(state.isShowing)
        XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.filteredItems.isEmpty)
        XCTAssertNil(state.triggerRange)
        XCTAssertNil(state.selectedID)
        XCTAssertTrue(state.multiSelectedIDs.isEmpty)
    }

    // MARK: - No Delegate Wired

    func testDelegateMethodsAreNilSafe() {
        let orphanVM = ChatInputViewModel(
            recognitionService: mockRecognition,
            promptService: mockPromptService
        )
        // mainDelegate is nil — these should not crash
        orphanVM.addAttachedFile(fileItem: makeFileItem(name: "x"))
        orphanVM.addAttachedFiles(fileItems: [])
        orphanVM.removeAttachedFile(fileItem: makeFileItem(name: "x"))
        orphanVM.cancelStreamingResponse()
        orphanVM.resetQueryHistoryIndex()
        XCTAssertNil(orphanVM.getQueryFromHistory(direction: .up))
    }
}
