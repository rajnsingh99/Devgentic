// Views/Sidebar/ActivityBarButton.swift (Updated)
import SwiftUI
import os

// Logger (Optional) - Assuming logger is defined elsewhere or remove if not used here
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ActivityBarButton")

// MARK: - Activity Bar Button View
/// A reusable button component for the Activity Bar icons.
struct ActivityBarButton: View {
    let tab: SidebarTab // The specific tab this button represents
    // Binding to the selected tab state
    @Binding var selectedTab: SidebarTab?
    // Binding to the sidebar visibility state
    @Binding var isSidebarVisible: Bool

    // Access the ViewModel from the environment to modify selection state
    @EnvironmentObject var viewModel: MainApplicationViewModel

    var body: some View {
        Button {
            // --- Action performed when the button is clicked ---

            // ** Special handling for the New Chat tab (Clear View / Hide Sidebar) **
            if tab == .newChat {
                if viewModel.selectedConversationID != nil {
                     viewModel.selectedConversationID = nil
                     logger.debug("Cleared selected conversation ID via New Chat button.")
                 }
                 if isSidebarVisible {
                      isSidebarVisible = false
                      logger.debug("Hid sidebar pane via New Chat button.")
                 }

            // *** Special handling for the Settings tab ***
            } else if tab == .settings {
                // 1. Toggle the main settings panel overlay directly
                viewModel.toggleSettings() // Use the existing ViewModel function
                logger.debug("Toggled settings panel overlay via Settings button. Show: \(viewModel.showSettings)")

                // 2. Hide the sidebar pane if it's open when settings are shown
                if viewModel.showSettings && isSidebarVisible {
                    isSidebarVisible = false
                    logger.debug("Hid sidebar pane because settings panel was opened.")
                }
                // 3. Do NOT change the selectedTab state.

            // ** Handling for all other tabs **
            } else {
                if selectedTab == tab {
                    // If clicking the already selected tab (and it's not .settings or .newChat),
                    // toggle the sidebar pane's visibility
                    isSidebarVisible.toggle()
                    logger.debug("Toggled sidebar visibility via \(tab.title) button. Visible: \(isSidebarVisible)")
                } else {
                    // If clicking a different tab (not .settings or .newChat), select it
                    // and ensure the sidebar pane is visible
                    selectedTab = tab
                    isSidebarVisible = true
                    logger.debug("Selected tab \(tab.title) via button. Sidebar forced visible.")

                    // Ensure settings panel is hidden if a main sidebar tab is selected
                    if viewModel.showSettings {
                        viewModel.showSettings = false
                        logger.debug("Hid settings panel because another sidebar tab was selected.")
                    }
                }
            }
        } label: {
            // Button label content (the icon)
            Image(systemName: tab.iconName)
                .font(.title2) // Control icon size
                .frame(width: 40, height: 40) // Define tappable area size
                // Icon color is secondary unless its tab is selected AND sidebar is visible
                // For settings, it should only be highlighted if the *panel* is open (which we don't track here directly)
                // Let's keep it simple: highlight only if its tab is selected and pane is visible. Settings won't highlight this way.
                .foregroundColor(selectedTab == tab && isSidebarVisible ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle()) // Make the entire frame tappable
        }
        .buttonStyle(.plain) // Use plain button style to remove default background/border
        .help(tab.title) // Add a tooltip showing the tab's title on hover
        .padding(.vertical, 5) // Add some vertical padding around each button
    }
}

// Note: The PreviewProvider for ActivityBarButton might need adjustment
// as it now requires a MainApplicationViewModel in the environment.
// You might need to wrap it in a container that provides the environment object.

/* Example Preview Update:
 #Preview {
     // Create a container that provides the necessary environment object
     struct ButtonPreviewContainer: View {
         @State var selectedTab: SidebarTab? = .conversations
         @State var isSidebarVisible: Bool = true
         @StateObject var viewModel = MainApplicationViewModel() // Create a dummy VM

         var body: some View {
             VStack {
                 ActivityBarButton(tab: .newChat, selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)
                 ActivityBarButton(tab: .conversations, selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)
                 Spacer()
                 ActivityBarButton(tab: .settings, selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible) // Add settings button
             }
             .environmentObject(viewModel) // Provide the VM
             .padding()
             .background(Color.gray.opacity(0.2))
             .frame(width: 80, height: 300) // Simulate Activity Bar size
         }
     }
     return ButtonPreviewContainer()
 }
 */
