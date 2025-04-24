// // /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/MainApplicationView.swift
// //
// //  ContentView.swift (Adapted for MainApplicationView)
// //  AgenticDev
// //
// //  Created by Raj Singh on 19/04/25.
// //

// import SwiftUI
// import AppKit
// import os // Import os for logging

// // Logger for better debugging
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainApplicationView")

// // MARK: - Backend Type Definition
// // Define the possible AI backend types
// enum BackendType: String, CaseIterable, Identifiable {
//     case ollama = "Ollama"
//     case agent = "Agent"

//     var id: String { self.rawValue }
// }


// // MARK: - Data Model
// struct Conversation: Identifiable, Equatable {
//     let id: UUID
//     var messages: [String]
//     var timestamp: Date // To help sort or display

//     // Helper to get a display title (e.g., first user message)
//     var displayTitle: String {
//         // Find the first message starting with "You: "
//         if let firstUserMessage = messages.first(where: { $0.starts(with: "You:") }) {
//             let content = firstUserMessage.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
//             // Limit title length for display
//             let maxLength = 30
//             return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
//         }
//         // Fallback if no user message yet or only agent messages
//         if let firstMessage = messages.first {
//             let content = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
//             // Limit title length for display
//             let maxLength = 30
//             // Include "Agent:" prefix if it's the first message
//             if content.starts(with: "Agent:") {
//                  return String(content.prefix(maxLength + 7)) + (content.count > (maxLength + 7) ? "..." : "") // Account for "Agent: "
//             } else {
//                  return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
//             }
//         }
//         return "New Chat"
//     }
// }

// // MARK: - Visual Effect View
// struct VisualEffectBlur: NSViewRepresentable {
//     func makeNSView(context: Context) -> NSVisualEffectView {
//         let view = NSVisualEffectView()
//         view.material = .hudWindow
//         view.blendingMode = .behindWindow
//         view.state = .active
//         return view
//     }

//     func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
// }

// // MARK: - Settings Section Definition
// enum SettingsSection: String, CaseIterable, Identifiable {
//     case general = "General"
//     case localAI = "Local AI"
//     case agents = "Agents"
//     case license = "License & Access"

//     var id: String { self.rawValue }

//     // SF Symbols for icons
//     var iconName: String {
//         switch self {
//         case .general: return "gearshape"
//         case .localAI: return "cpu"
//         case .agents: return "person.3.sequence"
//         case .license: return "key"
//         }
//     }
// }

// // MARK: - UserDefaults Keys (for @AppStorage)
// struct SettingsKeys {
//     static let selectedBackend = "selectedBackend" // Keep for now, might refactor later
//     static let windowOpacity = "windowOpacity"
//     static let llmModelName = "llmModelName"
//     static let agentBaseURL = "agentBaseURL"
//     static let agentDelegationStrategy = "agentDelegationStrategy"
// }

// // MARK: - Previews (Optional)
// struct FloatingWindowView_Previews: PreviewProvider {
//     static var previews: some View {
//         // Example with some preview data
//         MainApplicationView(
//             conversations: [
//                 Conversation(id: UUID(), messages: ["You: Hello there!", "Agent: Hi! How can I help?"], timestamp: Date()), // Today
//                 Conversation(id: UUID(), messages: ["You: What is Swift?"], timestamp: Date().addingTimeInterval(-86400)), // Yesterday
//                 Conversation(id: UUID(), messages: ["You: Old question"], timestamp: Date().addingTimeInterval(-86400 * 3)) // Older
//             ],
//             selectedConversationID: nil // Start with none selected in preview
//         )
//         .frame(width: 800, height: 600)
//         .previewDisplayName("With Grouped Conversations")

//         // Example with no conversations
//         MainApplicationView(conversations: [])
//             .frame(width: 800, height: 600)
//             .previewDisplayName("No Conversations")

//         // Example showing settings panel initially
//         MainApplicationView(conversations: [], showSettingsInitial: true)
//              .frame(width: 800, height: 600)
//              .previewDisplayName("Settings Open")

//         // Example showing context area initially with a file
//         MainApplicationView(conversations: [], showContextAreaInitial: true, activeFilePathInitial: "/Users/alice/Documents/project/main.swift")
//              .frame(width: 800, height: 600)
//              .previewDisplayName("Context Area Open (File)")

//         // Example showing context area initially with nothing
//         MainApplicationView(conversations: [], showContextAreaInitial: true, activeFilePathInitial: nil)
//              .frame(width: 800, height: 600)
//              .previewDisplayName("Context Area Open (Nothing)")
//     }
// }


// // MARK: - Main View
// struct MainApplicationView: View {
//     // --- Focus State ---
//     @FocusState private var isInputFocused: Bool

//     // --- State Variables (UI State) ---
//     @State private var isSidebarCollapsed: Bool = true
//     @State private var userInput = ""
//     @State var conversations: [Conversation] // Keep as @State if loaded externally/dynamically
//     @State var selectedConversationID: UUID?
//     @State private var showSettings: Bool
//     @State private var isSending: Bool = false
//     @State private var selectedSettingsSection: SettingsSection = .general // State for master-detail
//     // --- UPDATED Context State ---
//     @State private var showContextArea: Bool
//     @State private var activeContextFilePath: String? = nil // Keep this to know *if* context is active
//     // -------------------------

//     // --- AppStorage for Persistent Settings ---
//     @AppStorage(SettingsKeys.selectedBackend) private var selectedBackend: BackendType = .ollama
//     @AppStorage(SettingsKeys.windowOpacity) private var windowOpacity: Double = 1.0
//     @AppStorage(SettingsKeys.llmModelName) private var llmModelName: String = "gemma:2b"
//     @AppStorage(SettingsKeys.agentBaseURL) private var agentBaseURL: String = "http://127.0.0.1:8000"
//     @AppStorage(SettingsKeys.agentDelegationStrategy) private var agentDelegationStrategy: String = "send_to_first_available"
//     // --------------------------------------

//     // --- AI Connection ---
//     private let aiConnect = AIConnect() // Ensure AIConnect is defined elsewhere
//     // --------------------

//     // Initializer (Allow setting initial states for previews) - UPDATED
//     init(conversations: [Conversation] = [],
//          selectedConversationID: UUID? = nil,
//          showSettingsInitial: Bool = false,
//          showContextAreaInitial: Bool = false,
//          activeFilePathInitial: String? = nil) { // Added active file path initial state
//         _conversations = State(initialValue: conversations)
//         _selectedConversationID = State(initialValue: selectedConversationID)
//         _showSettings = State(initialValue: showSettingsInitial)
//         _showContextArea = State(initialValue: showContextAreaInitial) // Initialize context state
//         _activeContextFilePath = State(initialValue: activeFilePathInitial) // Initialize active file path
//     }


//     // MARK: - Computed Properties

//     // Computed property to get the messages of the selected conversation
//     private var currentChatHistory: [String] {
//         guard let selectedID = selectedConversationID,
//               let conversation = conversations.first(where: { $0.id == selectedID }) else {
//             return []
//         }
//         return conversation.messages
//     }

//     // Computed property to get the index of the selected conversation
//     private var selectedConversationIndex: Int? {
//         guard let selectedID = selectedConversationID else { return nil }
//         return conversations.firstIndex(where: { $0.id == selectedID })
//     }

//     // --- Grouped Conversations ---
//     private var groupedConversations: [String: [Conversation]] {
//         let calendar = Calendar.current
//         let now = Date()
//         let dateFormatter = DateFormatter()
//         dateFormatter.dateFormat = "MMMM d, yyyy" // Format for older dates

//         // Group conversations using reduce
//         let grouped = conversations.reduce(into: [String: [Conversation]]()) { result, conversation in
//             let timestamp = conversation.timestamp
//             let groupKey: String
//             if calendar.isDateInToday(timestamp) {
//                 groupKey = "Today"
//             } else if calendar.isDateInYesterday(timestamp) {
//                 groupKey = "Yesterday"
//             } else {
//                 groupKey = dateFormatter.string(from: timestamp)
//             }
//             result[groupKey, default: []].append(conversation)
//         }

//         // Sort conversations within each group (most recent first)
//         return grouped.mapValues { $0.sorted { $0.timestamp > $1.timestamp } }
//     }

//     // --- Sorted Group Keys ---
//     private var sortedGroupKeys: [String] {
//         let calendar = Calendar.current
//         let dateFormatter = DateFormatter()
//         dateFormatter.dateFormat = "MMMM d, yyyy"

//         return groupedConversations.keys.sorted { key1, key2 in
//             // Define order: Today > Yesterday > Older Dates (most recent first)
//             if key1 == "Today" { return true }
//             if key2 == "Today" { return false }
//             if key1 == "Yesterday" { return true }
//             if key2 == "Yesterday" { return false }

//             // If both are dates, compare them
//             if let date1 = dateFormatter.date(from: key1), let date2 = dateFormatter.date(from: key2) {
//                 return date1 > date2 // Sort dates descending (most recent first)
//             }

//             // Fallback (shouldn't happen with defined keys)
//             return key1 > key2
//         }
//     }
//     // --------------------------------

//     // Computed property for the title in the header
//     private var currentConversationTitle: String {
//         guard let index = selectedConversationIndex else {
//             return conversations.isEmpty ? "Devgentic" : "Select Chat"
//         }
//         // Use the original conversation array for title lookup based on ID
//         return conversations[index].displayTitle
//     }

//     // MARK: - Body
//     var body: some View {
//         // --- ZStack for Overlay ---
//         ZStack {
//             // --- Main Content HStack (Chat UI) ---
//             HStack(spacing: 0) {
//                 // --- Left Sidebar (Conversations) ---
//                 if !isSidebarCollapsed {
//                     ZStack {
//                         Color.black.opacity(0.25)
//                         VStack(alignment: .leading, spacing: 0) {
//                             // Header with New Chat Button
//                             HStack {
//                                 Text("Conversations")
//                                     .font(.title3)
//                                     .fontWeight(.semibold)
//                                     .foregroundColor(.white)
//                                 Spacer()
//                                 Button(action: startNewConversation) {
//                                     Image(systemName: "plus.circle.fill")
//                                         .foregroundColor(.white.opacity(0.8))
//                                 }
//                                 .buttonStyle(PlainButtonStyle())
//                             }
//                             .padding()

//                             Divider().background(Color.white.opacity(0.2))

//                             // List of Conversations (Using DisclosureGroup)
//                             ScrollView {
//                                 VStack(alignment: .leading, spacing: 0) {
//                                     ForEach(sortedGroupKeys, id: \.self) { groupKey in
//                                         let isGroupSelected = groupedConversations[groupKey]?.contains(where: { $0.id == selectedConversationID }) ?? false

//                                         DisclosureGroup(
//                                             isExpanded: .constant(isGroupSelected || groupKey == "Today"), // Keep Today expanded by default
//                                             content: {
//                                                 if let conversationsInGroup = groupedConversations[groupKey] {
//                                                     VStack(alignment: .leading, spacing: 5) {
//                                                         ForEach(conversationsInGroup) { conversation in
//                                                             HStack {
//                                                                 Text(conversation.displayTitle)
//                                                                     .foregroundColor(selectedConversationID == conversation.id ? .cyan : .white)
//                                                                     .padding(.horizontal, 8)
//                                                                     .padding(.vertical, 6)
//                                                                     .frame(maxWidth: .infinity, alignment: .leading)
//                                                                     .lineLimit(1)
//                                                                     .truncationMode(.tail)
//                                                             }
//                                                             .background(selectedConversationID == conversation.id ? Color.blue.opacity(0.4) : Color.clear)
//                                                             .cornerRadius(5)
//                                                             .contentShape(Rectangle())
//                                                             .onTapGesture {
//                                                                 selectedConversationID = conversation.id
//                                                             }
//                                                         }
//                                                     }
//                                                     .padding(.leading, 10)
//                                                     .padding(.bottom, 5)
//                                                 }
//                                             },
//                                             label: {
//                                                 Text(groupKey)
//                                                     .font(.footnote)
//                                                     .fontWeight(.semibold)
//                                                     .foregroundColor(isGroupSelected ? .white.opacity(0.9) : .gray)
//                                                     .padding(.vertical, 6)
//                                                     .frame(maxWidth: .infinity, alignment: .leading)
//                                             }
//                                         )
//                                         .accentColor(.white.opacity(0.7))
//                                         .background(isGroupSelected ? Color.white.opacity(0.1) : Color.clear)
//                                         .cornerRadius(4)
//                                         .padding(.horizontal, 5)
//                                         .padding(.leading, 5)
//                                         .padding(.bottom, 3)
//                                     }
//                                 }
//                                 .padding(.top, 10)
//                                 .padding(.bottom, 10)
//                             }
//                             Spacer()
//                         }
//                     }
//                     .frame(width: 240)
//                     .transition(.move(edge: .leading))
//                 }
//                 // --- End Left Sidebar ---

//                 // --- Divider ---
//                 if !isSidebarCollapsed {
//                      Divider()
//                 }
//                 // ------------------------------------------------------

//                 // --- Main Interaction Area (Right Side) ---
//                 VStack(spacing: 0) {
//                     // --- Header ---
//                     HStack {
//                         Button {
//                             withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() }
//                         } label: {
//                             Image(systemName: isSidebarCollapsed ? "sidebar.right" : "sidebar.left")
//                                 .foregroundColor(.white.opacity(0.8))
//                         }
//                         .buttonStyle(PlainButtonStyle())

//                         Text(currentConversationTitle)
//                             .font(.headline)
//                             .foregroundColor(.white.opacity(0.8))
//                             .lineLimit(1)
//                             .truncationMode(.tail)
//                         Spacer()
//                         Button {
//                             withAnimation { showSettings.toggle() }
//                         } label: {
//                             Image(systemName: "gearshape.fill")
//                                 .foregroundColor(.white.opacity(0.8))
//                         }
//                         .buttonStyle(PlainButtonStyle())
//                     }
//                     .padding()
//                     .background(Color.gray.opacity(0.2))

//                     // --- Chat Message Area ---
//                     // Conditional display is now handled by the ZStack overlay
//                     if selectedConversationID != nil || !conversations.isEmpty {
//                         ScrollViewReader { scrollProxy in
//                             ScrollView {
//                                 VStack(alignment: .leading, spacing: 10) {
//                                     if selectedConversationID != nil {
//                                         ForEach(currentChatHistory.indices, id: \.self) { index in
//                                             let message = currentChatHistory[index]
//                                             HStack {
//                                                 if message.starts(with: "Agent:") { Spacer() }
//                                                 MessageView(message: message)
//                                                 if message.starts(with: "You:") { Spacer() }
//                                             }
//                                             .id(index)
//                                             .frame(maxWidth: .infinity, alignment: message.starts(with: "You:") ? .trailing : .leading)
//                                         }
//                                     }
//                                     if isSending && selectedConversationID != nil {
//                                         HStack {
//                                              Text("Agent is thinking...")
//                                                  .font(.caption)
//                                                  .foregroundColor(.gray)
//                                                  .padding(10)
//                                                  .background(Color.white.opacity(0.1))
//                                                  .cornerRadius(10)
//                                              Spacer()
//                                          }
//                                          .padding(.leading)
//                                     }
//                                 }
//                                 .padding()
//                             }
//                             .onChange(of: currentChatHistory) { _ in
//                                 if selectedConversationID != nil {
//                                     scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory)
//                                 }
//                             }
//                             .onChange(of: isSending) { _ in
//                                  if selectedConversationID != nil && !isSending {
//                                      scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory)
//                                  }
//                             }
//                             .onChange(of: selectedConversationID) { newID in
//                                 if newID != nil {
//                                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                                         scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory, animated: false)
//                                         // Only focus if settings are not shown
//                                         if !showSettings {
//                                             isInputFocused = true
//                                         }
//                                     }
//                                 }
//                             }
//                         }
//                         .padding(.bottom, 5)

//                     } else {
//                         // Placeholder view when no conversations exist
//                         Spacer()
//                         Text("Type a message or press ⌘N to start a new chat.")
//                             .foregroundColor(.gray)
//                         Spacer()
//                     }
//                     // --- End Chat Message Area ---

//                     // --- Input Area ---
//                     VStack(spacing: 6) { // Reduced spacing slightly

//                         // --- Input Editor ---
//                         ZStack(alignment: .topLeading) {
//                             CustomTextEditor(
//                                 text: $userInput,
//                                 onCommit: sendMessage
//                             )
//                             // Placeholder text logic updated for context area
//                             if userInput.isEmpty {
//                                 Text(showContextArea ? "Context active. Type a message..." : "Type a message (Shift+Enter to send)...") // Adjusted placeholder
//                                     .font(Font.system(size: NSFont.systemFontSize))
//                                     .foregroundColor(.gray)
//                                     .padding(.horizontal, 7)
//                                     .padding(.top, 8)
//                                     .allowsHitTesting(false)
//                             }
//                         }
//                         .frame(minHeight: 30, maxHeight: 120)
//                         .focused($isInputFocused)
//                         .disabled(isSending || showSettings) // Disable input when settings are shown


//                         // --- NEW Horizontal Context Area ---
//                         if showContextArea {
//                             ScrollView(.horizontal, showsIndicators: false) { // Allow scrolling if more contexts are added later
//                                 HStack(spacing: 8) {
//                                     // --- VS Code Context Container ---
//                                     HStack(spacing: 4) {
//                                         Image(systemName: "chevron.left.forwardslash.chevron.right") // VS Code-like icon
//                                             .font(.system(size: 12)) // Smaller icon
//                                             .foregroundColor(.blue)
//                                         Text("VsCode")
//                                             .font(.system(size: 11))
//                                             .foregroundColor(.white.opacity(0.9))

//                                         // Optionally display file info or status icon
//                                         if activeContextFilePath != nil {
//                                             Image(systemName: "doc.text.fill") // Indicate file loaded
//                                                 .font(.system(size: 10))
//                                                 .foregroundColor(.green.opacity(0.8))
//                                         } else {
//                                              Image(systemName: "questionmark.circle") // Indicate nothing loaded/error
//                                                  .font(.system(size: 10))
//                                                  .foregroundColor(.gray)
//                                         }
//                                     }
//                                     .padding(.horizontal, 8)
//                                     .padding(.vertical, 4)
//                                     .background(Color.white.opacity(0.15)) // Slightly more prominent background
//                                     .cornerRadius(6)
//                                     // Add tap gesture if needed later (e.g., to show file path)
//                                     // .onTapGesture { logger.info("VS Code context tapped. Path: \(activeContextFilePath ?? "None")") }

//                                     // --- Add containers for other apps here later ---
//                                     // Example:
//                                     // HStack { ... } .padding(...) .background(...) ...

//                                 } // End Horizontal Stack for Contexts
//                                 .padding(.horizontal, 8) // Padding for the scroll view content
//                             } // End ScrollView
//                             .frame(height: 28) // Fixed height for the context row
//                             .padding(.bottom, 4) // Space below context row
//                             .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top))) // Subtle animation
//                         }
//                         // --- End NEW Horizontal Context Area ---


//                         // --- Input Buttons HStack ---
//                         HStack(spacing: 10) {
//                             Button { logger.info("Web icon tapped") } label: {
//                                 Image(systemName: "globe")
//                                     .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
//                                     .foregroundColor(.white.opacity(0.7))
//                             }
//                             .buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings)

//                             Button { logger.info("Plus icon tapped") } label: {
//                                 Image(systemName: "plus")
//                                     .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
//                                     .foregroundColor(.white.opacity(0.7))
//                             }
//                             .buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings)

//                             // --- Context Button (Action remains similar) ---
//                             Button {
//                                 // Action: Toggle context area and simulate fetching file
//                                 withAnimation {
//                                     showContextArea.toggle()
//                                     if showContextArea {
//                                         // --- SIMULATION ---
//                                         // Replace this block with your actual VS Code interaction logic
//                                         let shouldSimulateSuccess = Bool.random() // Randomly simulate success/failure
//                                         if shouldSimulateSuccess {
//                                             activeContextFilePath = "/Users/Shared/DemoProject/Sources/App/Controllers/UserController.swift" // Example path
//                                             logger.info("Context button tapped: Showing active file (Simulated).")
//                                         } else {
//                                             activeContextFilePath = nil // Simulate failure (VS Code not running or no file open)
//                                             logger.info("Context button tapped: Showing context area (Nothing active - Simulated).")
//                                         }
//                                         // --- END SIMULATION ---
//                                     } else {
//                                         activeContextFilePath = nil // Clear path when hiding
//                                         logger.info("Context button tapped: Hiding context area.")
//                                     }
//                                 }
//                             } label: {
//                                 Image(systemName: "paperclip")
//                                     .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
//                                     .foregroundColor(showContextArea ? .blue : .white.opacity(0.7)) // Indicate active state
//                             }
//                             .buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings)
//                             // --- End Context Button ---

//                             Spacer() // Keep spacer

//                             Button { logger.info("Mic icon tapped") } label: {
//                                 Image(systemName: "mic.fill")
//                                     .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
//                                     .foregroundColor(.white.opacity(0.7))
//                             }
//                             .buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings)

//                             Button(action: sendMessage) {
//                                 if isSending {
//                                     ProgressView().controlSize(.small).frame(width: 28, height: 28)
//                                 } else {
//                                     Image(systemName: "arrow.up.circle.fill")
//                                         .resizable().frame(width: 28, height: 28)
//                                         .foregroundColor(userInput.isEmpty || showSettings ? .gray : .blue) // Dim send if settings open
//                                 }
//                             }
//                             .buttonStyle(PlainButtonStyle())
//                             .disabled(userInput.isEmpty || isSending || showSettings)
//                         }
//                         .padding(.horizontal, 8)
//                         .padding(.bottom, 8)

//                     } // End Input Area VStack
//                     .background(Color.white.opacity(0.1))
//                     .cornerRadius(10)
//                     .padding(.horizontal)
//                     .padding(.bottom, 10)
//                     // --- End Input Area ---

//                     // Hidden Button for Keyboard Shortcut (Cmd+N)
//                     Button(action: startNewConversation) { EmptyView() }
//                         .hidden()
//                         .keyboardShortcut("n", modifiers: .command)

//                 } // End Main Interaction VStack
//                 .background(VisualEffectBlur())
//                 // --- End Main Interaction Area ---
//             } // End Main Content HStack
//             .allowsHitTesting(!showSettings) // Disable interaction with chat UI when settings are open

//             // --- Settings Panel Overlay ---
//             if showSettings {
//                 // Background layer to dim and catch taps
//                 Color.black.opacity(0.4)
//                     .edgesIgnoringSafeArea(.all)
//                     // Add tap gesture to dismiss settings
//                     .onTapGesture {
//                         withAnimation { showSettings = false }
//                     }

//                 // The Settings Panel itself
//                 HStack(alignment: .top, spacing: 0) {
//                     // Master View (Sidebar)
//                     VStack(alignment: .leading, spacing: 5) {
//                         ForEach(SettingsSection.allCases) { section in
//                             HStack {
//                                 Image(systemName: section.iconName)
//                                     .frame(width: 20)
//                                 Text(section.rawValue)
//                                 Spacer()
//                             }
//                             .padding(.horizontal, 10)
//                             .padding(.vertical, 8)
//                             .background(selectedSettingsSection == section ? Color.white.opacity(0.2) : Color.clear)
//                             .foregroundColor(selectedSettingsSection == section ? .white : .white.opacity(0.7))
//                             .cornerRadius(6)
//                             .contentShape(Rectangle())
//                             .onTapGesture {
//                                 selectedSettingsSection = section
//                             }
//                         }
//                         Spacer()
//                     }
//                     .padding(10)
//                     .frame(width: 250) // Keep width consistent
//                     .background(Color.black.opacity(0.2))

//                     Divider().background(Color.white.opacity(0.2))

//                     // Detail View
//                     ScrollView {
//                         VStack(alignment: .leading, spacing: 15) {
//                             switch selectedSettingsSection {
//                             case .general:
//                                 GeneralSettingsView(windowOpacity: $windowOpacity)
//                             case .localAI:
//                                 LocalAISettingsView(llmModelName: $llmModelName)
//                             case .agents:
//                                 AgentSettingsView(agentBaseURL: $agentBaseURL, agentDelegationStrategy: $agentDelegationStrategy)
//                             case .license:
//                                 LicenseSettingsView()
//                             }
//                             Spacer()
//                         }
//                         .padding(20)
//                     }
//                     .frame(maxWidth: .infinity)

//                 } // End Settings HStack
//                 .background(
//                     // Use VisualEffectBlur or a solid color for the settings background
//                      VisualEffectBlur().edgesIgnoringSafeArea(.all)
//                     // Color.black.opacity(0.6).edgesIgnoringSafeArea(.all) // Alternative solid background
//                 )
//                 .clipShape(RoundedRectangle(cornerRadius: 12)) // Rounded corners for the panel
//                 .shadow(radius: 10) // Add shadow for depth
//                 .frame(width: 1000, height: 650) // Fixed size for the centered panel
//                 // --- Add Close Button Overlay ---
//                 .overlay(alignment: .topTrailing) {
//                     Button {
//                         withAnimation { showSettings = false }
//                     } label: {
//                         Image(systemName: "xmark.circle.fill")
//                             .resizable()
//                             .frame(width: 20, height: 20)
//                             .foregroundColor(.gray.opacity(0.8))
//                             .padding(5) // Add padding inside the button's hit area
//                     }
//                     .buttonStyle(PlainButtonStyle())
//                     .padding(5) // Add padding outside the button
//                 }
//                 // --- End Close Button Overlay ---
//                 .transition(.scale.combined(with: .opacity)) // Nice transition
//             }
//             // --- End Settings Panel Overlay ---

//         } // End ZStack
//         .opacity(windowOpacity) // Apply overall opacity
//         .frame(minWidth: 800, minHeight: 500) // Keep overall window size constraints
//         .onAppear {
//              // Select the first conversation in the first group if none is selected
//              if selectedConversationID == nil,
//                 let firstKey = sortedGroupKeys.first,
//                 let firstConv = groupedConversations[firstKey]?.first {
//                  selectedConversationID = firstConv.id
//              } else if conversations.isEmpty && !showSettings { // Only focus input if settings aren't shown initially
//                  // Focus input if there are no conversations at all
//                  DispatchQueue.main.async { isInputFocused = true }
//              }
//          }
//     }

//     // MARK: - Actions

//     func startNewConversation() {
//         // If settings are open, close them first
//         if showSettings {
//             withAnimation { showSettings = false }
//         }
//         // If context area is open, optionally close it or leave it open
//         // if showContextArea {
//         //     withAnimation { showContextArea = false; activeContextFilePath = nil } // Clear path if closing context
//         // }

//         userInput = ""
//         let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
//         conversations.append(newConversation)
//         selectedConversationID = newConversation.id
//         logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
//         // Focus is handled by onChange(of: selectedConversationID)
//     }

//     // --- sendMessage Function ---
//     func sendMessage() {
//         let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
//         logger.debug("sendMessage called. Backend: \(selectedBackend.rawValue), isSending: \(isSending), trimmedInput: '\(trimmedInput)'")

//         guard !isSending else {
//             logger.warning("sendMessage aborted: Already sending.")
//             return
//         }
//         guard !trimmedInput.isEmpty else {
//             logger.info("sendMessage aborted: Input is empty after trimming.")
//             userInput = ""
//             return
//         }
//         // Prevent sending if settings are open
//         guard !showSettings else {
//              logger.warning("sendMessage aborted: Settings panel is open.")
//              return
//         }

//         // --- TODO: Integrate Context ---
//         // Here you would potentially read data from your context state
//         // (e.g., the activeContextFilePath) and prepend it or format it
//         // with the user's message. You might also need to read the file content.
//         // Example:
//         var contextPrefix = ""
//         if showContextArea, let filePath = activeContextFilePath {
//             // In a real scenario, you'd read the file content here
//             // let fileContent = readFileContent(at: filePath) ?? "Error reading file"
//             // contextPrefix = "Context File: \(filePath)\nContent:\n\(fileContent)\n\nUser Message:\n"
//             contextPrefix = "Context File: \(filePath)\n\nUser Message:\n" // Simplified for now
//         }
//         let messageToSend = contextPrefix + trimmedInput
//         // -----------------------------

//         if selectedConversationID == nil {
//             logger.info("No conversation selected. Starting a new one before sending.")
//             startNewConversation()
//         }

//         guard let currentID = selectedConversationID,
//               let conversationIndex = conversations.firstIndex(where: { $0.id == currentID }) else {
//             logger.error("CRITICAL: Could not find or create conversation (ID: \(String(describing: selectedConversationID))).")
//             return
//         }

//         // Append user message locally (use the original input for display)
//         let userMessage = "You: \(trimmedInput)"
//         conversations[conversationIndex].messages.append(userMessage)
//         conversations[conversationIndex].timestamp = Date()
//         let messageLog = messageToSend // Capture the full message (with context) for logging/sending
//         userInput = "" // Clear input field
//         isSending = true

//         Task {
//             var agentResponse = "Error: Agent response not received."
//             var taskError: Error? = nil

//             // Determine Backend Configuration
//             let targetURL: String
//             let targetEndpoint: String
//             let payload: [String: Any]

//             // Use the @AppStorage variables directly here
//             switch selectedBackend {
//             case .ollama:
//                 targetURL = "http://127.0.0.1:11434" // Consider making this configurable too
//                 targetEndpoint = "/api/generate"
//                 payload = [
//                     "model": llmModelName,
//                     "prompt": messageToSend, // Send the full message with context
//                     "stream": false
//                 ]
//                 logger.debug("Configured for Ollama. Model: \(llmModelName)")

//             case .agent:
//                 targetURL = agentBaseURL
//                 targetEndpoint = "/execute_task"
//                 payload = [
//                     "main_task": messageToSend, // Send the full message with context
//                     "strategy": agentDelegationStrategy
//                 ]
//                 logger.debug("Configured for Agent. URL: \(targetURL), Strategy: \(agentDelegationStrategy)")
//             }

//             do {
//                 logger.debug("Sending task '\(messageLog.prefix(200))...' to \(targetURL)\(targetEndpoint) for conversation \(currentID.uuidString)")

//                 let responseData = try await aiConnect.postToLocalServer(baseURL: targetURL, endpoint: targetEndpoint, payload: payload)

//                 // --- Response Handling (Unchanged) ---
//                 if selectedBackend == .agent {
//                     if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
//                        let resultsArray = json["results"] as? [[String: Any]] {
//                         if let completedResultDict = resultsArray.first(where: { ($0["status"] as? String) == "completed" }),
//                            let resultString = completedResultDict["result"] as? String {
//                             agentResponse = resultString.trimmingCharacters(in: .whitespacesAndNewlines)
//                             let slaveId = completedResultDict["slave_id"] as? String ?? "unknown"
//                             logger.debug("Extracted result from first completed agent (\(slaveId)): \(agentResponse)")
//                         } else {
//                             let failedCount = resultsArray.filter { ($0["status"] as? String) != "completed" }.count
//                             if failedCount > 0 && failedCount == resultsArray.count {
//                                 if let firstFailure = resultsArray.first, let errorMsg = firstFailure["result"] as? String {
//                                      agentResponse = "Agent Error: \(errorMsg)"
//                                      logger.warning("All agents failed. First error: \(errorMsg)")
//                                 } else {
//                                      agentResponse = "Error: All agents failed to complete the task."
//                                      logger.warning("All agents failed, but couldn't extract specific error message.")
//                                 }
//                             } else if resultsArray.isEmpty {
//                                  agentResponse = "Error: Received empty results array from agent."
//                                  logger.warning("Agent returned an empty results array.")
//                             } else {
//                                  agentResponse = "Error: No agent completed the task successfully."
//                                  logger.warning("No agent found with 'completed' status in results: \(resultsArray)")
//                             }
//                         }
//                     } else if let textResponse = String(data: responseData, encoding: .utf8) {
//                         agentResponse = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
//                         logger.warning("Received non-standard JSON or plain text from Agent backend: \(agentResponse)")
//                     } else {
//                         logger.error("Failed to decode Agent response data (neither expected JSON nor UTF-8 text).")
//                         agentResponse = "Error: Could not decode server response."
//                     }
//                 } else if selectedBackend == .ollama {
//                     if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] {
//                         let replyKey = "response"
//                         if let reply = json[replyKey] as? String {
//                             agentResponse = reply.trimmingCharacters(in: .whitespacesAndNewlines)
//                             logger.debug("Received Ollama JSON response using key '\(replyKey)': \(agentResponse)")
//                         } else {
//                             logger.warning("Received Ollama JSON, but key '\(replyKey)' not found or not a string. Keys: \(json.keys)")
//                             if let fallbackText = String(data: responseData, encoding: .utf8) {
//                                  agentResponse = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
//                                  logger.warning("Using raw JSON as text fallback for Ollama.")
//                             } else {
//                                  agentResponse = "Error: Received unreadable JSON from Ollama."
//                             }
//                         }
//                     } else if let textResponse = String(data: responseData, encoding: .utf8) {
//                          agentResponse = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
//                          logger.warning("Expected JSON from Ollama, received text: \(textResponse.prefix(100))...")
//                     } else {
//                         logger.error("Failed to decode Ollama response data (neither JSON nor UTF-8 text).")
//                         agentResponse = "Error: Could not decode server response."
//                     }
//                 }
//                 // --- End Response Handling ---

//             } catch {
//                 logger.error("Error during API call or decoding: \(error.localizedDescription)")
//                 taskError = error
//                 agentResponse = generateErrorMessage(error: error)
//             }

//             // Update UI on Main Actor
//             await MainActor.run {
//                 if let updatedIndex = conversations.firstIndex(where: { $0.id == currentID }) {
//                     conversations[updatedIndex].messages.append("Agent: \(agentResponse)")
//                     conversations[updatedIndex].timestamp = Date()
//                 } else {
//                     logger.error("Error: Conversation \(currentID.uuidString) disappeared before agent response could be added.")
//                 }
//                 isSending = false
//                 // Re-focus input only if settings are not open
//                 if !showSettings {
//                     isInputFocused = true
//                 }
//             }
//         }
//     }
//     // --- End sendMessage ---

//     // MARK: - Helper Functions

//     private func scrollToBottom(scrollProxy: ScrollViewProxy, history: [String], animated: Bool = true) {
//          guard !history.isEmpty else { return }
//          let lastIndex = history.count - 1
//          logger.trace("Scrolling to index \(lastIndex)")
//          if animated {
//              withAnimation(.easeOut(duration: 0.2)) {
//                  scrollProxy.scrollTo(lastIndex, anchor: .bottom)
//              }
//          } else {
//              scrollProxy.scrollTo(lastIndex, anchor: .bottom)
//          }
//      }

//     private func generateErrorMessage(error: Error) -> String {
//         if let urlError = error as? URLError {
//             switch urlError.code {
//             case .cannotConnectToHost: return "Error: Could not connect to the server (\(selectedBackend.rawValue)). Check if it's running and the URL/Port is correct."
//             case .networkConnectionLost: return "Error: Network connection lost."
//             case .notConnectedToInternet: return "Error: Not connected to the internet."
//             case .badServerResponse:
//                 if let responseData = urlError.userInfo["ResponseData"] as? Data,
//                    let responseString = String(data: responseData, encoding: .utf8) {
//                     return "Error: Bad server response. Server said: \(responseString.prefix(150))"
//                 }
//                 return "Error: Received an invalid response from the server."
//             case .cannotFindHost: return "Error: Cannot find the server host (\(selectedBackend.rawValue)). Check address/DNS."
//             case URLError.Code(rawValue: 1): return "Error: Operation not permitted (check Sandbox/Firewall)." // POSIX EPERM
//             default:
//                 logger.warning("Unhandled URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
//                 return "Error: Network request failed (\(urlError.localizedDescription))."
//             }
//         }
//         logger.warning("Unhandled error type: \(type(of: error)) - \(error.localizedDescription)")
//         return "Error: \(error.localizedDescription)" // General error
//     }

//     // --- TODO: Add file reading function if needed by sendMessage ---
//     // func readFileContent(at path: String) -> String? { ... }

// }

// // MARK: - Settings Detail Views (Unchanged Helper Structs)

// struct GeneralSettingsView: View {
//     @Binding var windowOpacity: Double

//     var body: some View {
//         VStack(alignment: .leading, spacing: 10) {
//             Text("General Settings")
//                 .font(.title2)
//                 .padding(.bottom, 5)

//             Divider()

//             HStack {
//                 Text("Window Transparency:")
//                     .frame(width: 150, alignment: .leading)
//                 Slider(value: $windowOpacity, in: 0.2...1.0)
//             }
//             .controlSize(.regular)

//             // Add more general settings here later if needed
//         }
//     }
// }

// struct LocalAISettingsView: View {
//     @Binding var llmModelName: String
//     // You might add other Local AI related settings here (e.g., Ollama URL if needed)

//     var body: some View {
//         VStack(alignment: .leading, spacing: 10) {
//             Text("Local AI (Ollama)")
//                 .font(.title2)
//                 .padding(.bottom, 5)

//             Divider()

//             HStack {
//                 Text("Ollama Model:")
//                     .frame(width: 150, alignment: .leading)
//                 TextField("e.g., gemma:2b", text: $llmModelName)
//                     .textFieldStyle(RoundedBorderTextFieldStyle())
//             }
//             .controlSize(.regular)

//             // Note: The BackendType picker might be removed or repurposed
//             // if Ollama is always configured here and Agents elsewhere.
//             // For now, it's still controlled by the @AppStorage variable.
//         }
//     }
// }

// struct AgentSettingsView: View {
//     @Binding var agentBaseURL: String
//     @Binding var agentDelegationStrategy: String

//     var body: some View {
//         VStack(alignment: .leading, spacing: 10) {
//             Text("Agent Configuration")
//                 .font(.title2)
//                 .padding(.bottom, 5)

//             Divider()

//             HStack {
//                 Text("Agent Base URL:")
//                     .frame(width: 150, alignment: .leading)
//                 TextField("http://...", text: $agentBaseURL)
//                     .textFieldStyle(RoundedBorderTextFieldStyle())
//             }
//             .controlSize(.regular)

//             HStack {
//                 Text("Delegation Strategy:")
//                     .frame(width: 150, alignment: .leading)
//                 TextField("e.g., send_to_first_available", text: $agentDelegationStrategy)
//                     .textFieldStyle(RoundedBorderTextFieldStyle())
//             }
//             .controlSize(.regular)

//             // Note: The BackendType picker might be removed or repurposed.
//         }
//     }
// }

// struct LicenseSettingsView: View {
//     var body: some View {
//         VStack(alignment: .leading, spacing: 10) {
//             Text("License & Access")
//                 .font(.title2)
//                 .padding(.bottom, 5)

//             Divider()

//             Text("License information and access key management will go here.")
//                 .foregroundColor(.gray)

//             // Add fields for license key, activation status, etc. later
//         }
//     }
// }


// // MARK: - Message View (Unchanged Helper)
// struct MessageView: View {
//     let message: String
//     let isUser: Bool

//     init(message: String) {
//         self.message = message
//         self.isUser = message.starts(with: "You:")
//     }

//     var body: some View {
//         let prefixLength = isUser ? 4 : (message.starts(with: "Agent:") ? 6 : 0)
//         let displayText = message.dropFirst(prefixLength)
//                             .trimmingCharacters(in: .whitespacesAndNewlines)
//         Text(displayText)
//             .padding(10)
//             .background(isUser ? Color.blue.opacity(0.4) : Color.white.opacity(0.1))
//             .foregroundColor(.white)
//             .cornerRadius(10)
//             .textSelection(.enabled) // Allow text selection
//     }
// }
