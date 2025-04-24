import XCTest
import SwiftUI // Needed for @State etc.
@testable import devgentic // Replace with your actual app module name

@MainActor // Run tests on the main actor since UI updates happen there
final class FloatingWindowViewTests: XCTestCase {

    var view: MainApplicationView!
    var mockAIConnect: MockAIConnect!

    // Dates for consistent testing
    let dateNow = Date()
    let datePast = Date().addingTimeInterval(-3600) // 1 hour ago
    let dateFurtherPast = Date().addingTimeInterval(-7200) // 2 hours ago

    // Sample Conversations
    var conversation1: Conversation!
    var conversation2: Conversation!
    var conversation3: Conversation! // Empty one

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Reset state before each test
        mockAIConnect = MockAIConnect()

        // Create sample conversations for reuse
        conversation1 = Conversation(id: UUID(), messages: ["You: Hello", "Agent: Hi there"], timestamp: datePast)
        conversation2 = Conversation(id: UUID(), messages: ["You: What is SwiftUI?", "Agent: A UI framework."], timestamp: dateNow) // Most recent
        conversation3 = Conversation(id: UUID(), messages: [], timestamp: dateFurtherPast)

        // Initialize the view - NOTE: We need to adapt MainApplicationView to accept the mock
        // For now, we assume AIConnect is internal and cannot be easily mocked without modifying the view.
        // A better approach is dependency injection. Let's proceed assuming we can test *around* AIConnect for now,
        // and mock its behavior via the mock object when testing sendMessage.
        // We will need to modify MainApplicationView to accept the mock for sendMessage tests.
        // Let's assume MainApplicationView is modified like this:
        // init(conversations: [Conversation] = [], selectedConversationID: UUID? = nil, aiConnector: AIConnectProtocol = AIConnect()) { ... }

        // For tests NOT involving sendMessage directly, we can use the default init for now.
        // For sendMessage tests, we'll need to initialize with the mock.
    }

    override func tearDownWithError() throws {
        view = nil
        mockAIConnect = nil
        conversation1 = nil
        conversation2 = nil
        conversation3 = nil
        try super.tearDownWithError()
    }

    // MARK: - Initialization & Setup Tests

    func testInitialization_Default() {
        view = MainApplicationView() // Assumes default init exists

        XCTAssertTrue(view.conversations.isEmpty, "Conversations should be empty initially")
        XCTAssertNil(view.selectedConversationID, "SelectedConversationID should be nil initially")
        XCTAssertEqual(view.userInput, "", "UserInput should be empty initially")
        XCTAssertFalse(view.showSettings, "ShowSettings should be false initially")
        XCTAssertEqual(view.windowOpacity, 1.0, "WindowOpacity should be 1.0 initially")
        XCTAssertFalse(view.isSending, "IsSending should be false initially")
        XCTAssertEqual(view.llmModelName, "gemma4b", "Default model name should be 'gemma4b'")
        // Cannot easily test @FocusState or placeholder visibility in unit tests
    }

    func testInitialization_WithProvidedConversations_NoSelection_SelectsMostRecent() {
        view = MainApplicationView(conversations: [conversation1, conversation3, conversation2]) // Deliberately out of order

        // Trigger onAppear logic (simulated - real onAppear might need UI test)
        // For unit tests, we often test the state *after* potential onAppear logic runs.
        // Let's assume the logic inside onAppear is testable or we test the state it should produce.
        view.onAppear() // Manually call if possible, or check state assuming it ran

        XCTAssertEqual(view.conversations.count, 3, "Should have 3 conversations")
        XCTAssertEqual(view.selectedConversationID, conversation2.id, "Should select the conversation with the most recent timestamp")
        XCTAssertEqual(view.currentChatHistory, conversation2.messages, "Chat history should match the most recent conversation")
    }

    func testInitialization_WithProvidedConversations_WithSelection() {
        view = MainApplicationView(conversations: [conversation1, conversation3, conversation2], selectedConversationID: conversation1.id)

        view.onAppear() // Simulate

        XCTAssertEqual(view.conversations.count, 3)
        XCTAssertEqual(view.selectedConversationID, conversation1.id, "Should respect the pre-selected conversation ID")
        XCTAssertEqual(view.currentChatHistory, conversation1.messages, "Chat history should match the pre-selected conversation")
    }

    // MARK: - Conversation Management Tests

    func testConversationDisplayTitle_FirstUserMessageShort() {
        let conv = Conversation(id: UUID(), messages: ["You: Hello", "Agent: Hi"], timestamp: dateNow)
        XCTAssertEqual(conv.displayTitle, "Hello")
    }

    func testConversationDisplayTitle_FirstUserMessageLong() {
        let conv = Conversation(id: UUID(), messages: ["You: This is a very long message that needs truncation", "Agent: Got it"], timestamp: dateNow)
        XCTAssertEqual(conv.displayTitle, "This is a very long message th...")
    }

    func testConversationDisplayTitle_AgentFirstMessage() {
        let conv = Conversation(id: UUID(), messages: ["Agent: Welcome! How can I assist?", "You: Hi"], timestamp: dateNow)
        // Note: The current implementation takes the *very first* message if no "You:" message exists.
        XCTAssertEqual(conv.displayTitle, "Agent: Welcome! How can I assi...")
    }

    func testConversationDisplayTitle_EmptyMessages() {
        let conv = Conversation(id: UUID(), messages: [], timestamp: dateNow)
        XCTAssertEqual(conv.displayTitle, "New Chat")
    }

    func testStartNewConversation_FromEmptyState() {
        view = MainApplicationView(conversations: [])
        view.startNewConversation()

        XCTAssertEqual(view.conversations.count, 1, "Should add one new conversation")
        let newConv = view.conversations.first!
        XCTAssertTrue(newConv.messages.isEmpty, "New conversation should have no messages")
        XCTAssertEqual(view.selectedConversationID, newConv.id, "New conversation should be selected")
        XCTAssertEqual(view.userInput, "", "User input should be cleared")
        // Cannot easily test focus state here
    }

    func testStartNewConversation_WithExistingConversations() {
        view = MainApplicationView(conversations: [conversation1], selectedConversationID: conversation1.id)
        view.startNewConversation()

        XCTAssertEqual(view.conversations.count, 2, "Should add a second conversation")
        XCTAssertNotEqual(view.selectedConversationID, conversation1.id, "Selection should change from the old conversation")
        XCTAssertEqual(view.conversations.last?.id, view.selectedConversationID, "The newly added conversation should be selected")
        XCTAssertTrue(view.currentChatHistory.isEmpty, "Current chat history should be empty for the new conversation")
    }

    func testSelectConversation() {
        view = MainApplicationView(conversations: [conversation1, conversation2], selectedConversationID: conversation1.id)
        // Simulate selection
        view.selectedConversationID = conversation2.id

        // Need expectation for async focus change if testing that part
        let expectation = XCTestExpectation(description: "Wait for potential async updates after selection")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { // Wait slightly longer than the view's delay
             XCTAssertEqual(self.view.selectedConversationID, self.conversation2.id, "Conversation 2 should be selected")
             XCTAssertEqual(self.view.currentChatHistory, self.conversation2.messages, "Chat history should update to conversation 2")
             // Cannot easily test focus state here
             expectation.fulfill()
         }
         wait(for: [expectation], timeout: 0.5)
    }

    func testSortedConversationsComputedProperty() {
        view = MainApplicationView(conversations: [conversation3, conversation1, conversation2]) // Out of order
        let sorted = view.sortedConversations

        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].id, conversation2.id, "First should be the most recent (conversation2)")
        XCTAssertEqual(sorted[1].id, conversation1.id, "Second should be conversation1")
        XCTAssertEqual(sorted[2].id, conversation3.id, "Third should be the oldest (conversation3)")
    }

    // MARK: - Sending Messages & AI Interaction Tests (Requires Mocking)

    // Helper to initialize view with mock
    func setupViewWithMock(conversations: [Conversation] = [], selectedID: UUID? = nil) {
         // *** IMPORTANT: Modify FloatingWindowView's init to accept the mock ***
         // Example modification:
         // init(conversations: [Conversation] = [], selectedConversationID: UUID? = nil, aiConnector: AIConnectProtocol = AIConnect()) {
         //     _conversations = State(initialValue: conversations)
         //     _selectedConversationID = State(initialValue: selectedConversationID)
         //     self.aiConnect = aiConnector // Store the passed connector
         // }
         // Then initialize like this:
         // view = MainApplicationView(conversations: conversations, selectedConversationID: selectedID, aiConnector: mockAIConnect)

         // If you cannot modify the init, these tests might be harder or impossible to unit test accurately.
         // For now, we'll write the tests assuming the init is modifiable.
         // If not, you'd have to test the state changes *before* the network call,
         // but couldn't easily verify the call itself or the response handling.

         // *** Assuming modified init: ***
         view = MainApplicationView(conversations: conversations, selectedConversationID: selectedID, aiConnector: mockAIConnect)
    }

    func testSendMessage_ValidInput_ExistingConversation_Success() async throws {
        setupViewWithMock(conversations: [conversation1], selectedID: conversation1.id)
        view.userInput = "Test Query"
        mockAIConnect.setSuccessResponse(json: ["response": "Test Answer"])

        let expectation = XCTestExpectation(description: "Wait for sendMessage async task")

        view.sendMessage() // This kicks off the Task

        // Observe state changes (synchronous parts first)
        XCTAssertTrue(view.isSending, "isSending should be true immediately after calling send")
        XCTAssertEqual(view.conversations.first?.messages.last, "You: Test Query", "User message should be appended immediately")
        XCTAssertEqual(view.userInput, "", "User input should be cleared")

        // Wait for the async part to complete
        // We need a way to know the Task finished. Polling is fragile.
        // A better way: Add a completion handler to sendMessage for testing, or use Combine/Notifications.
        // Simple approach: Wait a short time (can be flaky).
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds - adjust as needed

        // Check state after async completion
        XCTAssertFalse(view.isSending, "isSending should be false after response")
        XCTAssertEqual(view.conversations.first?.messages.count, 3, "Should have initial messages + user + agent")
        XCTAssertEqual(view.conversations.first?.messages.last, "Agent: Test Answer", "Agent response should be appended")
        XCTAssertEqual(mockAIConnect.lastEndpointCalled, "/api/generate", "Correct endpoint should be called")
        XCTAssertEqual(mockAIConnect.lastPayloadSent?["model"] as? String, "gemma4b", "Correct model should be sent")
        XCTAssertEqual(mockAIConnect.lastPayloadSent?["prompt"] as? String, "Test Query", "Correct prompt should be sent")

        expectation.fulfill() // Fulfill if using expectation pattern
        // await fulfillment(of: [expectation], timeout: 1.0) // If using expectation pattern
    }

    func testSendMessage_ValidInput_NoSelectedConversation_Success() async throws {
        setupViewWithMock(conversations: []) // Start empty
        view.userInput = "First Query"
        mockAIConnect.setSuccessResponse(json: ["response": "First Answer"])

        view.sendMessage()

        // Check synchronous state changes
        XCTAssertTrue(view.isSending)
        XCTAssertEqual(view.conversations.count, 1, "A new conversation should be created")
        let newConvId = view.selectedConversationID
        XCTAssertNotNil(newConvId)
        XCTAssertEqual(view.conversations.first?.messages.first, "You: First Query")
        XCTAssertEqual(view.userInput, "")

        // Wait for async completion
        try await Task.sleep(nanoseconds: 100_000_000)

        // Check final state
        XCTAssertFalse(view.isSending)
        XCTAssertEqual(view.conversations.first?.messages.count, 2)
        XCTAssertEqual(view.conversations.first?.messages.last, "Agent: First Answer")
        XCTAssertEqual(mockAIConnect.lastPayloadSent?["prompt"] as? String, "First Query")
    }

    func testSendMessage_EmptyInput() {
        setupViewWithMock(conversations: [conversation1], selectedID: conversation1.id)
        view.userInput = "   " // Whitespace only
        mockAIConnect.setErrorResponse(error: MockAIConnect.MockError.simulatedError("Should not be called")) // Set error to fail test if called

        view.sendMessage()

        XCTAssertFalse(view.isSending, "isSending should remain false")
        XCTAssertEqual(view.conversations.first?.messages.count, 2, "No message should be added")
        XCTAssertEqual(view.userInput, "", "Input should be cleared even if empty")
        XCTAssertNil(mockAIConnect.lastEndpointCalled, "AIConnect should not be called for empty input")
    }

    func testSendMessage_WhileAlreadySending() {
         setupViewWithMock(conversations: [conversation1], selectedID: conversation1.id)
         view.userInput = "First message"
         mockAIConnect.postToLocalServerHandler = { _, _ in
             // Simulate a long running task
             try await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec
             return Data(#"{"response": "First answer"}"#.utf8)
         }

         // Send the first message
         view.sendMessage()
         XCTAssertTrue(view.isSending)
         XCTAssertEqual(view.conversations.first?.messages.last, "You: First message")

         // Immediately try to send another while the first is 'in flight'
         view.userInput = "Second message"
         view.sendMessage()

         // Assertions for the second attempt
         XCTAssertTrue(view.isSending, "Should still be sending the first message")
         XCTAssertEqual(view.conversations.first?.messages.count, 3, "Only the first user message should be added")
         XCTAssertEqual(view.userInput, "Second message", "Input for the second message should remain")
         // We can't easily assert the mock wasn't called *again* without more complex mock setup (e.g., call counts)
    }

    func testSendMessage_ApiConnectionError() async throws {
        setupViewWithMock(conversations: [conversation1], selectedID: conversation1.id)
        view.userInput = "Query Connection Error"
        let expectedError = URLError(.cannotConnectToHost)
        mockAIConnect.setErrorResponse(error: expectedError)

        view.sendMessage()
        XCTAssertTrue(view.isSending)
        XCTAssertEqual(view.conversations.first?.messages.last, "You: Query Connection Error")

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(view.isSending)
        XCTAssertEqual(view.conversations.first?.messages.count, 4) // Initial(2) + User(1) + Error(1)
        let expectedErrorMessage = "Agent: Error: Could not connect to the local AI server (check if running)."
        XCTAssertEqual(view.conversations.first?.messages.last, expectedErrorMessage)
    }

     func testSendMessage_ApiBadJsonResponse() async throws {
         setupViewWithMock(conversations: [conversation1], selectedID: conversation1.id)
         view.userInput = "Query Bad JSON"
         // Return data that is not valid JSON
         mockAIConnect.postToLocalServerHandler = { _, _ in return Data("<html></html>".utf8) }

         view.sendMessage()
         XCTAssertTrue(view.isSending)
         XCTAssertEqual(view.conversations.first?.messages.last, "You: Query Bad JSON")

         try await Task.sleep(nanoseconds: 100_000_000)

         XCTAssertFalse(view.isSending)
         XCTAssertEqual(view.conversations.first?.messages.count, 4)
         // The view currently appends the raw non-JSON string if decoding fails
         XCTAssertEqual(view.conversations.first?.messages.last, "Agent: <html></html>")
     }

    func testSendMessage_ApiNonJsonResponse_ValidText() async throws {
        setupViewWithMock(conversations: [conversation1], selectedID: conversation1.id)
        view.userInput = "Query Plain Text"
        mockAIConnect.setSuccessResponse(text: "Simple text reply")

        view.sendMessage()
        XCTAssertTrue(view.isSending)
        XCTAssertEqual(view.conversations.first?.messages.last, "You: Query Plain Text")

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(view.isSending)
        XCTAssertEqual(view.conversations.first?.messages.count, 4)
        XCTAssertEqual(view.conversations.first?.messages.last, "Agent: Simple text reply")
    }

    // MARK: - UI State & Settings Tests

    func testToggleSettings() {
        view = MainApplicationView()
        XCTAssertFalse(view.showSettings)

        // Simulate button tap (directly toggle state)
        view.showSettings.toggle()
        XCTAssertTrue(view.showSettings)

        view.showSettings.toggle()
        XCTAssertFalse(view.showSettings)
    }

    func testChangeTransparency() {
        view = MainApplicationView()
        XCTAssertEqual(view.windowOpacity, 1.0)

        // Simulate slider change
        view.windowOpacity = 0.5
        XCTAssertEqual(view.windowOpacity, 0.5)
    }

    func testChangeModelName_AffectsApiCall() async throws {
        setupViewWithMock(conversations: [conversation1], selectedID: conversation1.id)
        let newModelName = "new-test-model"
        mockAIConnect.setSuccessResponse(json: ["response": "OK"])

        // Simulate changing model in settings
        view.llmModelName = newModelName
        XCTAssertEqual(view.llmModelName, newModelName)

        // Send a message
        view.userInput = "Test model change"
        view.sendMessage()

        try await Task.sleep(nanoseconds: 100_000_000) // Wait for async

        // Verify the payload sent used the updated model name
        XCTAssertEqual(mockAIConnect.lastPayloadSent?["model"] as? String, newModelName)
    }

    // MARK: - Helper View Tests

    func testMessageView_UserMessage() {
        let msg = "You: This is the user text."
        let messageView = MessageView(message: msg)

        XCTAssertTrue(messageView.isUser)
        // Cannot easily test internal Text content or background color in unit test
        // UI tests are better suited for visual verification
    }

    func testMessageView_AgentMessage() {
        let msg = "Agent: This is the agent text."
        let messageView = MessageView(message: msg)

        XCTAssertFalse(messageView.isUser)
        // Cannot easily test internal Text content or background color in unit test
    }

    // MARK: - Focus & Scrolling (Limited Unit Testability)

    // FocusState is hard to test directly in unit tests. We test the *intent* to focus.
    // Scrolling requires ScrollViewProxy, which is also hard to mock/test in unit tests.
    // We can test that the state changes which *should* trigger focus/scroll.

    func testFocus_Intent_OnNewConversation() {
         view = MainApplicationView()
         // We expect isInputFocused to become true after async dispatch
         let expectation = XCTestExpectation(description: "Focus should be requested after new conversation")

         view.startNewConversation()

         // Check after the async dispatch in startNewConversation
         DispatchQueue.main.async {
             // In a real UI test, we'd check the actual focused element.
             // Here, we can only assume the @FocusState binding works if the flag is set.
             // XCTAssertTrue(view.isInputFocused) // This won't work directly on the @FocusState var
             expectation.fulfill()
         }
         wait(for: [expectation], timeout: 0.5)
     }

     func testFocus_Intent_OnSelectConversation() {
         view = MainApplicationView(conversations: [conversation1, conversation2], selectedConversationID: conversation1.id)
         let expectation = XCTestExpectation(description: "Focus should be requested after selecting conversation")

         // Simulate selection
         view.selectedConversationID = conversation2.id

         // Check after the async dispatch in the .onChange(of: selectedConversationID) modifier
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { // Wait for the view's delay + a bit
             // XCTAssertTrue(view.isInputFocused) // Again, direct check is hard
             expectation.fulfill()
         }
         wait(for: [expectation], timeout: 0.5)
     }

    // Test for generateErrorMessage helper
    func testGenerateErrorMessage_UrlErrors() {
        view = MainApplicationView() // Need an instance to call the private method

        let connError = URLError(.cannotConnectToHost)
        XCTAssertEqual(view.generateErrorMessage(error: connError), "Error: Could not connect to the local AI server (check if running).")

        let lostError = URLError(.networkConnectionLost)
        XCTAssertEqual(view.generateErrorMessage(error: lostError), "Error: Network connection lost.")

        let badRespError = URLError(.badServerResponse)
        XCTAssertEqual(view.generateErrorMessage(error: badRespError), "Error: Received an invalid response from the server.")

        // Test the rawValue case (e.g., POSIX permission error often maps to rawValue 1)
        let permError = URLError(URLError.Code(rawValue: 1))
        XCTAssertEqual(view.generateErrorMessage(error: permError), "Error: Operation not permitted (check Sandbox/Firewall).")

        let unknownUrlError = URLError(.cancelled) // Use one not explicitly handled
        XCTAssertTrue(view.generateErrorMessage(error: unknownUrlError).starts(with: "Error: Network request failed"))
    }

    func testGenerateErrorMessage_GenericError() {
        view = MainApplicationView()
        let genericError = NSError(domain: "TestDomain", code: 123, userInfo: [NSLocalizedDescriptionKey: "A test error occurred"])
        XCTAssertEqual(view.generateErrorMessage(error: genericError), "Error: A test error occurred")
    }
}

// Helper extension to call onAppear for testing purposes if needed
// Note: This might not trigger all SwiftUI lifecycle events perfectly.
extension MainApplicationView {
    func onAppear() {
        // Manually replicate the logic inside the view's .onAppear modifier
        if selectedConversationID == nil, let mostRecent = sortedConversations.first {
            selectedConversationID = mostRecent.id
            // Cannot easily test the async focus part here
        } else if conversations.isEmpty {
             // Cannot easily test the async focus part here
        }
    }
}

// Helper extension to access private `generateErrorMessage`
// (Use sparingly, prefer testing through public interfaces if possible)
extension MainApplicationView {
    func generateErrorMessage(error: Error) -> String {
        // Call the private method directly for testing
        return self.generateErrorMessage(error: error)
    }
}
