//
//  ChatHistoryView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import os
import Highlightr
import AppKit
import Down

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatHistoryView")

private let CODE_BLOCK_LINE_LIMIT = 50

// MARK: - New ChatHistoryView (Based on MarkdownParserApp's ContentView)
struct ChatHistoryView: View {

    @EnvironmentObject private var viewModel: MainApplicationViewModel
    @State private var streamingText: String = ""
    @State private var streamingError: Error? = nil
    
    // State to control the visibility of the "scroll to bottom" button
    @State private var showScrollToBottomButton = false

    private var dividerColor: Color {
        #if os(macOS)
        return Color(NSColor.separatorColor)
        #else
        return Color(UIColor.separator)
        #endif
    }

    // Computed property to represent the message currently being streamed
    private var inProgressMessage: ChatMessage? {
        guard let conversationID = viewModel.selectedConversationID, viewModel.isSending else {
            return nil
        }

        let content: MessageContent = if let error = streamingError {
            .error(title: "Streaming Error", details: error.localizedDescription)
        } else {
            .markdownText(streamingText)
        }

        return ChatMessage(
            conversationId: conversationID,
            sender: .agent, // Assuming streaming is always from the agent
            content: content
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                chatScrollView(proxy: proxy)
                    .task(id: viewModel.streamingTriggerID) {
                        // This task runs when streamingTriggerID changes (i.e., new user message sent)
                        if let triggerID = viewModel.streamingTriggerID {
                            // Scroll to the trigger message (user's last message)
                            scrollTo(proxy: proxy, anchor: triggerID, position: .bottom)
                        }
                        // Start consuming the response stream
                        await consumeStream()
                    }
                    // Scroll to bottom when new messages are added (unless pagination is active)
                    .onChange(of: viewModel.currentChatMessages.count) { newCount in
                        if !viewModel.isLoadingPage && !viewModel.isSending {
                            // Only scroll to bottom if not loading older pages or actively sending
                            DispatchQueue.main.async {
                                if let lastMessageId = viewModel.currentChatMessages.first?.id {
                                    scrollTo(proxy: proxy, anchor: lastMessageId, position: .bottom)
                                }
                            }
                        }
                    }
                
                // Floating "Scroll to Bottom" Button
                if showScrollToBottomButton {
                    Button(action: {
                        if let lastMessageId = viewModel.currentChatMessages.first?.id {
                            scrollTo(proxy: proxy, anchor: lastMessageId, position: .bottom)
                        }
                    }) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private func chatScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Display messages if a conversation is selected
                if viewModel.selectedConversationID != nil {
                    // Iterate with index to determine divider placement
                    ForEach(Array(viewModel.currentChatMessages.enumerated()), id: \.element.id) { index, message in
                        ChatBubbleView(message: message) // Render the message bubble first
                            .id(message.id) // Assign ID for ScrollViewReader
                            .rotationEffect(.degrees(180)) // Counter-rotate message
                            .scaleEffect(x: -1, y: 1, anchor: .center) // Counter-scale message
                            .onAppear {
                                // Trigger pagination when the "oldest" message (visually at top) appears
                                if viewModel.currentChatMessages.last?.id == message.id && viewModel.canLoadMorePages {
                                    logger.debug("Reached top of chat, loading more messages.")
                                    Task {
                                        await viewModel.loadMoreMessages()
                                    }
                                }
                            }

                    if index < viewModel.currentChatMessages.count - 1 {
                            // If the current message is from the user, and it's not the very last message,
                            // add a smaller spacer for visual separation between user messages or before an agent message.
                            Spacer().frame(height: 40)
                                .rotationEffect(.degrees(180)) // Counter-rotate
                                .scaleEffect(x: -1, y: 1, anchor: .center) // Counter-scale
                        }
                        // No spacer/divider after the very last message in the list (oldest message)
                    }

                    // Display streaming message or thinking indicator
                    if viewModel.isSending {
                        Spacer().frame(height: 25) // Space before in-progress message

                        if streamingText.isEmpty && streamingError == nil {
                            // Thinking indicator when stream hasn't started
                            ThinkingIndicatorView()
                                .id("inProgressMessage")
                                .frame(minHeight: 700, alignment: .top) // Ensure it takes space
                                .rotationEffect(.degrees(180)) // Counter-rotate
                                .scaleEffect(x: -1, y: 1, anchor: .center) // Counter-scale
                        } else if let inProgress = inProgressMessage {
                            // Display streaming content as it arrives
                            ChatBubbleView(message: inProgress) // Use the new ChatBubbleView
                                .id("inProgressMessage")
                                .frame(minHeight: 700, alignment: .top) // Ensure it takes space
                                .rotationEffect(.degrees(180)) // Counter-rotate
                                .scaleEffect(x: -1, y: 1, anchor: .center) // Counter-scale
                        }
                    }
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 50) // Keep horizontal padding for overall chat content
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading) // Align content to top-leading
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("scroll")).origin)
                }
            )
        }
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            // Heuristic to show the button: if the user has scrolled up more than a certain amount (e.g., half a screen height)
            // The value.y will be negative when scrolling up from the bottom in this reversed scrollview
            let scrollThreshold: CGFloat = -300
            withAnimation(.easeInOut) {
                showScrollToBottomButton = value.y < scrollThreshold
            }
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rotationEffect(.degrees(180)) // Rotate the entire scroll view to make it scroll from bottom-up
        .scaleEffect(x: -1, y: 1, anchor: .center) // Flip horizontally to correct text direction after rotation
    }

    // Handles consuming the response stream from the view model
    private func consumeStream() async {
        guard let triggerID = viewModel.streamingTriggerID,
              let conversationID = viewModel.selectedConversationID,
              let lastUserMessage = viewModel.currentChatMessages.first(where: { $0.sender == .user && $0.id == triggerID }),
              let userQuery = lastUserMessage.content.textContent
        else {
            return
        }

        logger.debug("Task started for trigger ID: \(triggerID.uuidString)")

        // Reset streaming state for new stream
        self.streamingText = ""
        self.streamingError = nil
        var finalFullText = ""
        var finalError: Error?

        do {
            // Get the stream from the view model
            let stream = viewModel.streamResponse(
                conversationID: conversationID,
                userQuery: userQuery,
                files: viewModel.attachedFiles
            )

            // Iterate over the stream tokens
            for try await token in stream {
                self.streamingText += token
                finalFullText = self.streamingText
            }
        } catch {
            logger.error("Stream consumption failed: \(error.localizedDescription)")
            self.streamingError = error
            finalError = error
        }

        // Finalize the streaming process in the view model
        viewModel.finalizeStreaming(
            conversationID: conversationID,
            fullText: finalFullText,
            error: finalError
        )
    }

    // Helper function to scroll to a specific anchor in the ScrollView
    private func scrollTo(proxy: ScrollViewProxy, anchor: any Hashable, position: UnitPoint) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(anchor, anchor: position)
            }
        }
    }
}

// PreferenceKey to read the scroll view's offset
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {}
}


// MARK: - Thinking Indicator View (retained from old ChatHistoryView)
fileprivate struct ThinkingIndicatorView: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.accentColor)
                .opacity(isAnimating ? 1.0 : 0.5)
                .animation(Animation.easeInOut(duration: 1).repeatForever(), value: isAnimating)

            Text("Thinking...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
        }
        .onAppear {
            self.isAnimating = true
        }
    }
}


// MARK: - ChatBubbleView (Adapted from MarkdownParserApp)
struct ChatBubbleView: View {
    let message: ChatMessage
    @EnvironmentObject private var viewModel: MainApplicationViewModel // Inject ViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.sender == .agent {
                // Agent message is left-aligned
                VStack(alignment: .leading, spacing: 0) {
                    switch message.content {
                    case .plainText(let text):
                        Text(text)
                            .foregroundColor(Color(NSColor.labelColor))
                            .textSelection(.enabled)

                    case .markdownText(let text):
                        ForEach(parseMarkdown(text)) { block in
                            switch block {
                            case .paragraph(let paragraphText):
                                Text(try! AttributedString(markdown: paragraphText))
                                    .font(.body)
                                    .foregroundColor(Color(NSColor.labelColor))
                                    .padding(.vertical, 2)
                                    .textSelection(.enabled)
                            case .code(let lang, let codeContent):
                                // Check if the code block is lengthy
                                if codeContent.components(separatedBy: .newlines).count > CODE_BLOCK_LINE_LIMIT {
                                    CodeBlockCardView(language: lang, lineCount: codeContent.components(separatedBy: .newlines).count) {
                                        viewModel.showCodeInViewer(language: lang, code: codeContent)
                                    }
                                } else {
                                    CodeBlockView(language: lang, content: codeContent)
                                        .padding(.vertical, 4)
                                        .frame(maxWidth: 700, alignment: .leading) // Reduced width by 20% (approx 560 points for 800pt preview)
                                        .padding(.bottom, 20) // Added vertical space
                                }
                            case .heading(let level, let headingText):
                                Text(headingText)
                                    .font(level == 1 ? .title : (level == 2 ? .title2 : .title3))
                                    .fontWeight(.bold)
                                    .padding(.vertical, 8)
                                    .textSelection(.enabled)
                            case .listItem(let itemText):
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .font(.body)
                                        .foregroundColor(Color(NSColor.labelColor))
                                    Text(try! AttributedString(markdown: itemText))
                                        .font(.body)
                                        .foregroundColor(Color(NSColor.labelColor))
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                    case .codeBlock(let language, let code):
                        // Check if the code block is lengthy
                        if code.components(separatedBy: .newlines).count > CODE_BLOCK_LINE_LIMIT {
                            CodeBlockCardView(language: language ?? "code", lineCount: code.components(separatedBy: .newlines).count) {
                                viewModel.showCodeInViewer(language: language, code: code)
                            }
                        } else {
                            CodeBlockView(language: language ?? "code", content: code)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(16)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                .frame(maxWidth: 700, alignment: .leading) // Reduced width by 20% (approx 560 points for 800pt preview)
                                .padding(.bottom, 20) // Added vertical space
                        }

                    case .error(let title, let details):
                        ErrorMessageView(title: title, details: details)
                            .padding(12)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

                    case .image(let url, let alt):
                        VStack {
                            if let imageUrl = url {
                                Text("Image: \(imageUrl.lastPathComponent)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let altText = alt, !altText.isEmpty {
                                Text(altText)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            } else {
                                Text("Image content")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading) // Ensure VStack takes full width and aligns left
                Spacer() // Pushes the agent message to the left
            } else {
                // User message is right-aligned
                Spacer() // Pushes the user message to the right
                VStack(alignment: .trailing, spacing: 0) {
                    switch message.content {
                    case .plainText(let text):
                        Text(text)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.accentColor)
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .textSelection(.enabled)

                    case .markdownText(let text):
                        Text(text) // User markdown is treated as plain text for simplicity in bubble
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.accentColor)
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .textSelection(.enabled)

                    case .codeBlock(let language, let code):
                        // Check if the code block is lengthy for user messages too
                        if code.components(separatedBy: .newlines).count > CODE_BLOCK_LINE_LIMIT {
                            CodeBlockCardView(language: language ?? "code", lineCount: code.components(separatedBy: .newlines).count) {
                                viewModel.showCodeInViewer(language: language, code: code)
                            }
                        } else {
                            CodeBlockView(language: language ?? "code", content: code)
                                .padding(.vertical, 4)
                                .background(Color.accentColor) // Use accent color for user code blocks background
                                .cornerRadius(16)
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                .padding(.bottom, 20) // Added vertical space
                        }

                    case .error(let title, let details):
                        ErrorMessageView(title: title, details: details)
                            .padding(12)
                            .background(Color.accentColor) // Use accent color for user error messages
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

                    case .image(let url, let alt):
                        VStack {
                            if let imageUrl = url {
                                Text("Image: \(imageUrl.lastPathComponent)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let altText = alt, !altText.isEmpty {
                                Text(altText)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            } else {
                                Text("Image content")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding(12)
                        .background(Color.accentColor) // Use accent color for user image messages
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    }
                }
                .frame(maxWidth: 600, alignment: .trailing) // Limit user message width
            }
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .agent ? .leading : .trailing)
    }
}

// MARK: - CodeBlockView (Adapted from MarkdownParserApp)
struct CodeBlockView: View {
    let language: String
    let content: String
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with language title and copy button
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied" : "Copy")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(isCopied ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.textBackgroundColor).opacity(0.5))

            // The highlighted code
            HighlightedCodeView(language: language, code: content)
                .padding(10)
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        withAnimation {
            isCopied = true
        }
        // Reset the button state after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
    }
}

// MARK: - SizingTextView (from MarkdownParserApp)
// Custom NSTextView that correctly calculates and reports its content size.
class SizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        // The width should be unconstrained so SwiftUI can manage it.
        // The height is the calculated height of the text.
        return NSSize(width: NSView.noIntrinsicMetric, height: usedRect.height)
    }
}

// MARK: - HighlightedCodeView (from MarkdownParserApp)
// A view that uses Highlightr to display syntax-highlighted code.
struct HighlightedCodeView: NSViewRepresentable {
    let language: String
    let code: String

    func makeNSView(context: Context) -> NSTextView {
        // Use the custom sizing text view
        let textView = SizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        let highlightr = Highlightr()
        // Ensure theme is set. You might want to make this configurable.
        highlightr?.setTheme(to: "atom-one-dark")

        if let highlightedCode = highlightr?.highlight(code, as: language, fastRender: true) {
            nsView.textStorage?.setAttributedString(highlightedCode)
        } else {
            nsView.string = code
        }

        // Tell the view that its size has changed so SwiftUI can update the layout.
        nsView.invalidateIntrinsicContentSize()
    }
}

// MARK: - Preview Provider for ChatHistoryView
struct ChatHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a mock MainApplicationViewModel for preview
        let mockViewModel = MainApplicationViewModel(
            llmIntegrationStore: LLMIntegrationStore(),
            agentStore: AgentStore()
        )
        // Add some mock conversations and messages for preview
        let convId = UUID()
        mockViewModel.conversations = [
            Conversation(id: convId, messages: [
                ChatMessage(conversationId: convId, sender: .user, content: .plainText("Hello, can you help me with a Python script?")),
                ChatMessage(conversationId: convId, sender: .agent, content: .markdownText("Certainly! What kind of Python script are you looking for? Here's an example of a simple `Hello, World!` function:\n```python\ndef hello_world():\n    print(\"Hello, World!\")\n```\n\nI can also provide more complex examples or explain concepts. Just let me know!")),
                ChatMessage(conversationId: convId, sender: .user, content: .plainText("That's great! Can you show me a Java example for a data structure?")),
                ChatMessage(conversationId: convId, sender: .agent, content: .codeBlock(language: "java", code: """
                public class LinkedListNode {
                    int data;
                    LinkedListNode next;

                    public LinkedListNode(int data) {
                        this.data = data;
                        this.next = null;
                    }

                    public void display() {
                        LinkedListNode current = this;
                        while (current != null) {
                            System.out.print(current.data + " -> ");
                            current = current.next;
                        }
                        System.out.println("null");
                    }

                    public static void main(String[] args) {
                        LinkedListNode head = new LinkedListNode(10);
                        head.next = new LinkedListNode(20);
                        head.next.next = new LinkedListNode(30);
                        head.display(); // Output: 10 -> 20 -> 30 -> null
                    }
                }
                """)),
                ChatMessage(conversationId: convId, sender: .agent, content: .error(title: "API Error", details: "Failed to fetch data from external service. Please check your network connection.")),
                ChatMessage(conversationId: convId, sender: .agent, content: .markdownText("""
                ### How to Run and Test

                1.  **Save the files:**
                    * `pom.xml` in your project root.
                    * `SpringSecurityDemoApplication.java` in `src/main/java/com/example/springsecuritydemo/`.
                    * `HelloController.java` in `src/main/java/com/example/springsecuritydemo/controller/`.
                    * `SecurityConfig.java` in `src/main/java/com/example/springsecuritydemo/config/`.

                2.  **Open a terminal** in your project's root directory (where `pom.xml` is located).

                3.  **Build the project:**
                    ```bash
                    mvn clean install
                    ```

                4.  **Run the application:**
                    ```bash
                    mvn spring-boot:run
                    ```
                    The application will start, usually on `http://localhost:8080`.

                5.  **Test in your browser (or Postman/curl):**

                    * **Access Public Endpoints:**
                        * `http://localhost:8080/`
                        * `http://localhost:8080/public`
                        * *Expected:* You should see the welcome messages without needing to log in.

                    * **Access Restricted Endpoints (without authentication):**
                        * `http://localhost:8080/user`
                        * `http://localhost:8080/admin`
                        * `http://localhost:8080/dashboard`
                        * *Expected:* Spring Security will automatically redirect you to a default login page (looks basic, but functional).

                    * **Login as `user`:**
                        * **Username:** `user`
                        * **Password:** `password`
                        * After logging in successfully:
                            * Try `http://localhost:8080/user` -> *Expected:* Access granted.
                            * Try `http://localhost:8080/admin` -> *Expected:* Access Denied (HTTP 403 Forbidden).
                            * Try `http://localhost:8080/dashboard` -> *Expected:* Access granted.

                    * **Login as `admin`:**
                        * **Username:** `admin`
                        * **Password:** `adminpass`
                        * After logging in successfully:
                            * Try `http://localhost:8080/user` -> *Expected:* Access granted.
                            * Try `http://localhost:8080/admin` -> *Expected:* Access granted.
                            * Try `http://localhost:8080/dashboard` -> *Expected:* Access granted.

                    * **HTTP Basic Authentication (e.g., using `curl`):**
                        * **User Endpoint:**
                            ```bash
                            curl -u user:password http://localhost:8080/user
                            ```
                            *Expected:* "Hello, User! You have 'USER' role access."
                        * **Admin Endpoint (as user):
                            ```bash
                            curl -u user:password http://localhost:8080/admin
                            ```
                            *Expected:* HTTP 403 Forbidden.
                        * **Admin Endpoint (as admin):
                            ```bash
                            curl -u admin:adminpass http://localhost:8080/admin
                            ```
                            *Expected:* "Welcome, Admin! You have 'ADMIN' role access."

                ---

                ### Key Concepts Explained:

                * **`@EnableWebSecurity`**: This annotation triggers Spring Security's web security features.
                * **`SecurityFilterChain` Bean**: In modern Spring Security (Spring Boot 2.7+ / Spring 6+), you configure HTTP security rules by defining a `SecurityFilterChain` bean. This replaces the deprecated `WebSecurityConfigurerAdapter`.
                    * **`http.authorizeHttpRequests()`**: This is where you define authorization rules for different URL paths.
                        * `.requestMatchers("/").permitAll()`: Allows access to the root path `/` without authentication.
                        * `.hasRole("ROLE_USER")`: Requires the authenticated user to have the "USER" role. Spring Security automatically prefixes roles with `ROLE_` when checking with `hasRole()`, so in your `User` definition, you provide just `USER`.
                        * `.authenticated()`: Requires the user to be authenticated, but doesn't check for specific roles.
                    * **`http.formLogin()`**: Enables Spring Security's default HTML form-based login page. If an unauthenticated user tries to access a protected resource, they are redirected here.
                    * **`http.httpBasic()`**: Enables HTTP Basic authentication, useful for client applications like Postman or `curl` that send credentials in the HTTP header.
                    * **`http.csrf()`**: Cross-Site Request Forgery protection. It's enabled by default and crucial for web applications. For simple demos or pure API applications, it's sometimes temporarily disabled with `.csrf(csrf -> csrf.disable())`, but **never in production web applications without alternative, robust CSRF protection**.
                * **`UserDetailsService` Bean**: This interface is responsible for loading user-specific data.
                    * **`InMemoryUserDetailsManager`**: Used for demonstration purposes. In a real application, you'd implement your own `UserDetailsService` to fetch user details (username, password, roles) from a database (e.g., using JDBC or JPA).
                * **`PasswordEncoder` Bean**: Essential for securely storing user passwords. Passwords should *never* be stored in plain text. `BCryptPasswordEncoder` is a strong, widely recommended algorithm that automatically handles salting.

                This program provides a solid foundation for understanding and implementing basic Spring Security in your applications. For more advanced scenarios (JWT, OAuth2, custom login pages, method-level security, integration with external identity providers), you would build upon these core concepts.
                """))
            ])
        ]
        mockViewModel.selectedConversationID = convId
        // Simulate loading state for preview
        // mockViewModel.isSending = true
        // mockViewModel.streamingText = "This is a streaming response..."

        return ChatHistoryView()
            .environmentObject(mockViewModel)
            .frame(width: 800, height: 600)
            .preferredColorScheme(.dark)
    }
}
