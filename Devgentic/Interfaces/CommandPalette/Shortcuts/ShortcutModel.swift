// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShortcutModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI

// MARK: - Category

/// A category in the data model and registry of all keyboard shortcuts and commands across Devgentic.
enum ShortcutCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case general = "General"
    case chat = "Chat & Audio"
    case composer = "Composer"
    case codeViewer = "Code Viewer"
    case workflow = "Workflow"
    case promptLibrary = "Prompts"
    case scheduler = "Scheduler"
    case skills = "Skills"
    case settings = "Settings & Profiles"
    case globalHotkeys = "Global Hotkeys"
    case tooling = "Tools & Models"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "command"
        case .general: return "macwindow"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .composer: return "character.cursor.ibeam"
        case .codeViewer: return "chevron.left.forwardslash.chevron.right"
        case .workflow: return "point.3.connected.trianglepath.dotted"
        case .promptLibrary: return "square.stack.3d.up.fill"
        case .scheduler: return "clock.badge"
        case .skills: return "puzzlepiece"
        case .settings: return "gearshape.2"
        case .globalHotkeys: return "globe"
        case .tooling: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Shortcut Item

struct ShortcutItem: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let keys: [String]
    let category: ShortcutCategory
    let contextNote: String?

    init(
        id: String? = nil,
        title: String,
        description: String,
        keys: [String],
        category: ShortcutCategory,
        contextNote: String? = nil
    ) {
        self.id = id ?? "\(category.rawValue)-\(title)"
        self.title = title
        self.description = description
        self.keys = keys
        self.category = category
        self.contextNote = contextNote
    }
}

// MARK: - Registry

struct ShortcutRegistry {
    static let allShortcuts: [ShortcutItem] = [
        // MARK: - General & Navigation
        ShortcutItem(
            title: "Universal Command Palette",
            description: "Open the Spotlight-style command palette to search actions, switch modes, navigate sidebar tabs, and jump to recent conversations.",
            keys: ["⌘", "K"],
            category: .general
        ),
        ShortcutItem(
            title: "New Chat / Session",
            description: "Start a new conversation in Chat mode, or return to the Welcome screen in Workflow and Code modes.",
            keys: ["⌘", "N"],
            category: .general
        ),
        ShortcutItem(
            title: "Attach Files / Context",
            description: "Open the file picker to attach documents or code context to the chat.",
            keys: ["⌘", "O"],
            category: .general
        ),
        ShortcutItem(
            title: "Toggle Sidebar",
            description: "Show or hide the left navigation and sidebar pane.",
            keys: ["⌘", "B"],
            category: .general
        ),
        ShortcutItem(
            title: "Navigate Back",
            description: "Return to the previous screen (e.g. Back to Chat from Settings, Profiles, or Models).",
            keys: ["⌘", "["],
            category: .general
        ),
        ShortcutItem(
            title: "Navigate Home",
            description: "Return to the Welcome screen and deselect the active conversation.",
            keys: ["⇧", "⌘", "H"],
            category: .general
        ),
        ShortcutItem(
            title: "Explorer Sidebar",
            description: "Quickly open the file Explorer in the sidebar pane.",
            keys: ["⇧", "⌘", "E"],
            category: .general
        ),
        ShortcutItem(
            title: "Switch to Chat Mode",
            description: "Switch the active workspace to direct AI conversational mode.",
            keys: ["⌃", "1"],
            category: .general
        ),
        ShortcutItem(
            title: "Switch to Workflow Canvas",
            description: "Switch to the multi-agent node orchestration visual canvas.",
            keys: ["⌃", "2"],
            category: .general
        ),
        ShortcutItem(
            title: "Switch to Code Workspace",
            description: "Switch to developer workspace and terminal code sessions.",
            keys: ["⌃", "3"],
            category: .general
        ),
        ShortcutItem(
            title: "Cycle Interface Mode",
            description: "Quickly cycle through Chat, Workflow, and Code modes.",
            keys: ["⌃", "`"],
            category: .general
        ),
        ShortcutItem(
            title: "Go to Chats Tab",
            description: "Open the Chats history sidebar tab.",
            keys: ["⌥", "⌘", "1"],
            category: .general
        ),
        ShortcutItem(
            title: "Go to Explorer Tab",
            description: "Open the file Explorer sidebar tab.",
            keys: ["⌥", "⌘", "2"],
            category: .general
        ),
        ShortcutItem(
            title: "Go to Prompts Tab",
            description: "Open the Prompt Library sidebar tab.",
            keys: ["⌥", "⌘", "3"],
            category: .general
        ),
        ShortcutItem(
            title: "Go to Scheduler Tab",
            description: "Open the Scheduled Tasks & Triggers sidebar tab.",
            keys: ["⌥", "⌘", "4"],
            category: .general
        ),
        ShortcutItem(
            title: "Go to Profiles Tab",
            description: "Open the Backend AI Profiles sidebar tab.",
            keys: ["⌥", "⌘", "5"],
            category: .general
        ),
        ShortcutItem(
            title: "Go to Tools Tab",
            description: "Open the MCP Tools & Integrations sidebar tab.",
            keys: ["⌥", "⌘", "6"],
            category: .general
        ),
        ShortcutItem(
            title: "Go to Skills Tab",
            description: "Open the Agentic Skills catalog sidebar tab.",
            keys: ["⌥", "⌘", "7"],
            category: .general
        ),
        ShortcutItem(
            title: "Go to Downloads Tab",
            description: "Open the Model Downloads & Cache sidebar tab.",
            keys: ["⌥", "⌘", "8"],
            category: .general
        ),
        ShortcutItem(
            title: "Settings",
            description: "Open the application settings window.",
            keys: ["⌘", ","],
            category: .general
        ),
        ShortcutItem(
            title: "Backend Profiles",
            description: "Navigate to Backend Profiles to manage AI configurations.",
            keys: ["⇧", "⌘", "P"],
            category: .general
        ),
        ShortcutItem(
            title: "Observability Trends",
            description: "Open the Observability Trends window for reliability and telemetry inspection.",
            keys: ["⌥", "⇧", "⌘", "T"],
            category: .general,
            contextNote: "Developer Mode"
        ),
        ShortcutItem(
            title: "Focus Chat Composer",
            description: "Jump cursor directly to the chat prompt input from anywhere in the window.",
            keys: ["⌘", "L"],
            category: .general
        ),
        ShortcutItem(
            title: "Next Conversation",
            description: "Select the next conversation downward in the sidebar list.",
            keys: ["⌥", "⌘", "↓"],
            category: .general
        ),
        ShortcutItem(
            title: "Previous Conversation",
            description: "Select the previous conversation upward in the sidebar list.",
            keys: ["⌥", "⌘", "↑"],
            category: .general
        ),
        ShortcutItem(
            title: "Rename Active Conversation",
            description: "Edit the title of the active conversation in the sidebar.",
            keys: ["⇧", "⌘", "R"],
            category: .general
        ),
        ShortcutItem(
            title: "Pin / Unpin Active Conversation",
            description: "Toggle pinned status of the active conversation.",
            keys: ["⌘", "P"],
            category: .general
        ),
        ShortcutItem(
            title: "Export Conversation as Markdown",
            description: "Export the active conversation transcript to a Markdown file.",
            keys: ["⇧", "⌘", "S"],
            category: .general
        ),
        ShortcutItem(
            title: "Delete Active Conversation",
            description: "Permanently delete the active conversation (prompts confirmation).",
            keys: ["⌘", "⌫"],
            category: .general
        ),
        ShortcutItem(
            title: "Close Window / Tab",
            description: "Close the active window, or close the selected tab if Code Viewer is active.",
            keys: ["⌘", "W"],
            category: .general
        ),
        ShortcutItem(
            title: "Keyboard Shortcuts",
            description: "Open this keyboard shortcuts reference window.",
            keys: ["⌘", "/"],
            category: .general
        ),

        // MARK: - Chat & Audio
        ShortcutItem(
            title: "Toggle Voice Input",
            description: "Start or stop voice dictation in the chat composer.",
            keys: ["⇧", "⌘", "V"],
            category: .chat
        ),
        ShortcutItem(
            title: "Stop & Transcribe Voice",
            description: "Finalize live microphone dictation and transcribe to prompt.",
            keys: ["↩"],
            category: .chat,
            contextNote: "During voice recording"
        ),
        ShortcutItem(
            title: "Cancel Voice Recording",
            description: "Discard current voice recording without transcribing.",
            keys: ["Esc"],
            category: .chat,
            contextNote: "During voice recording"
        ),
        ShortcutItem(
            title: "Search Chat Messages",
            description: "Toggle the in-chat message search overlay.",
            keys: ["⌘", "F"],
            category: .chat
        ),
        ShortcutItem(
            title: "Find Next Match",
            description: "Jump to the next search match in the conversation.",
            keys: ["⌘", "G"],
            category: .chat,
            contextNote: "When search is open"
        ),
        ShortcutItem(
            title: "Find Previous Match",
            description: "Jump to the previous search match in the conversation.",
            keys: ["⇧", "⌘", "G"],
            category: .chat,
            contextNote: "When search is open"
        ),
        ShortcutItem(
            title: "Dismiss Search",
            description: "Close the search bar overlay and clear highlights.",
            keys: ["Esc"],
            category: .chat,
            contextNote: "When search is open"
        ),
        ShortcutItem(
            title: "Pause / Resume Speech",
            description: "Pause or resume spoken Text-To-Speech audio playback.",
            keys: ["⌥", "Space"],
            category: .chat,
            contextNote: "During speech playback"
        ),
        ShortcutItem(
            title: "Skip Forward 10s",
            description: "Fast-forward the current spoken audio playback by 10 seconds.",
            keys: ["⌥", "→"],
            category: .chat,
            contextNote: "During speech playback"
        ),
        ShortcutItem(
            title: "Skip Backward 10s",
            description: "Rewind the current spoken audio playback by 10 seconds.",
            keys: ["⌥", "←"],
            category: .chat,
            contextNote: "During speech playback"
        ),

        // MARK: - Composer & Text Editor
        ShortcutItem(
            title: "Skill Command Suggestions",
            description: "Open the slash-command picker to link and run available skills.",
            keys: ["/"],
            category: .composer,
            contextNote: "At word start"
        ),
        ShortcutItem(
            title: "File Context Suggestions",
            description: "Open the file reference picker to attach code files to your message.",
            keys: ["@"],
            category: .composer,
            contextNote: "At word start"
        ),
        ShortcutItem(
            title: "Prompt Suggestions",
            description: "Open the prompt library picker to insert saved prompt templates.",
            keys: ["#"],
            category: .composer,
            contextNote: "At word start"
        ),
        ShortcutItem(
            title: "Navigate Suggestions",
            description: "Move selection up or down in the suggestion popup list.",
            keys: ["↑", "↓"],
            category: .composer,
            contextNote: "In suggestion picker"
        ),
        ShortcutItem(
            title: "Confirm Suggestion",
            description: "Insert the highlighted suggestion into the composer.",
            keys: ["↩"],
            category: .composer,
            contextNote: "In suggestion picker"
        ),
        ShortcutItem(
            title: "Recall Previous Query",
            description: "Load the previous prompt from sent message history.",
            keys: ["↑"],
            category: .composer,
            contextNote: "At start of composer"
        ),
        ShortcutItem(
            title: "Recall Newer Query",
            description: "Load the next prompt from sent message history.",
            keys: ["↓"],
            category: .composer,
            contextNote: "At end of composer"
        ),
        ShortcutItem(
            title: "Send Message",
            description: "Submit the prompt to the assistant. If inside a list, continues list.",
            keys: ["↩"],
            category: .composer
        ),
        ShortcutItem(
            title: "Insert Newline",
            description: "Insert a line break without sending the message.",
            keys: ["⇧", "↩"],
            category: .composer
        ),
        ShortcutItem(
            title: "Deny Tool / Skip Question",
            description: "Deny permission for tool execution or skip an interactive question banner.",
            keys: ["Esc"],
            category: .composer,
            contextNote: "On confirmation banner"
        ),

        // MARK: - Code Viewer
        ShortcutItem(
            title: "Previous Tab",
            description: "Switch to the previous code snippet tab.",
            keys: ["⇧", "⌘", "["],
            category: .codeViewer
        ),
        ShortcutItem(
            title: "Next Tab",
            description: "Switch to the next code snippet tab.",
            keys: ["⇧", "⌘", "]"],
            category: .codeViewer
        ),
        ShortcutItem(
            title: "Select Tab 1–9",
            description: "Jump directly to the tab at position 1 through 9.",
            keys: ["⌘", "1–9"],
            category: .codeViewer
        ),
        ShortcutItem(
            title: "Increase Font Size",
            description: "Enlarge editor code font size by 1 point.",
            keys: ["⌘", "+"],
            category: .codeViewer
        ),
        ShortcutItem(
            title: "Decrease Font Size",
            description: "Shrink editor code font size by 1 point.",
            keys: ["⌘", "-"],
            category: .codeViewer
        ),
        ShortcutItem(
            title: "Reset Font Size",
            description: "Reset code font size back to the 12 pt default.",
            keys: ["⌘", "0"],
            category: .codeViewer
        ),
        ShortcutItem(
            title: "Smart Save",
            description: "Save active tab directly to its source file, or prompt for Save As.",
            keys: ["⌘", "S"],
            category: .codeViewer
        ),
        ShortcutItem(
            title: "Close Active Tab",
            description: "Close the currently selected code tab.",
            keys: ["⌘", "W"],
            category: .codeViewer
        ),

        // MARK: - Workflow Canvas
        ShortcutItem(
            title: "Undo Canvas Change",
            description: "Step backward through the last 25 canvas edits (add, delete, rewire, or reposition).",
            keys: ["⌘", "Z"],
            category: .workflow
        ),
        ShortcutItem(
            title: "Delete Node or Edge",
            description: "Remove the currently selected workflow node or connection line.",
            keys: ["⌫"],
            category: .workflow,
            contextNote: "When item is selected"
        ),

        // MARK: - Prompt Library
        ShortcutItem(
            title: "New Prompt",
            description: "Open the modal dialog to create a new custom prompt.",
            keys: ["⌘", "N"],
            category: .promptLibrary,
            contextNote: "In Prompts sidebar"
        ),
        ShortcutItem(
            title: "Browse Prompts",
            description: "Move keyboard focus up or down through the prompt library list.",
            keys: ["↑", "↓"],
            category: .promptLibrary,
            contextNote: "In Prompts sidebar"
        ),
        ShortcutItem(
            title: "Open Focused Prompt",
            description: "Open the highlighted prompt in the full editor.",
            keys: ["↩"],
            category: .promptLibrary,
            contextNote: "In Prompts sidebar"
        ),
        ShortcutItem(
            title: "Toggle Pin Status",
            description: "Pin or unpin the focused prompt to the top of the library.",
            keys: ["P"],
            category: .promptLibrary,
            contextNote: "In Prompts sidebar"
        ),
        ShortcutItem(
            title: "Use Prompt in Chat",
            description: "Immediately copy the focused prompt into the active chat composer.",
            keys: ["U"],
            category: .promptLibrary,
            contextNote: "In Prompts sidebar"
        ),
        ShortcutItem(
            title: "Delete Focused Prompt",
            description: "Delete the focused user prompt.",
            keys: ["⌫"],
            category: .promptLibrary,
            contextNote: "User prompts only"
        ),
        ShortcutItem(
            title: "Save Prompt Changes",
            description: "Commit modifications to the current prompt.",
            keys: ["⌘", "S"],
            category: .promptLibrary,
            contextNote: "In Prompt Detail"
        ),
        ShortcutItem(
            title: "Use in Chat",
            description: "Send the edited prompt directly into the active conversation.",
            keys: ["⇧", "⌘", "↩"],
            category: .promptLibrary,
            contextNote: "In Prompt Detail"
        ),
        ShortcutItem(
            title: "Copy Prompt Text",
            description: "Copy full prompt template content to the clipboard.",
            keys: ["⇧", "⌘", "C"],
            category: .promptLibrary,
            contextNote: "In Prompt Detail"
        ),
        ShortcutItem(
            title: "Duplicate Prompt",
            description: "Create a copy of the current prompt.",
            keys: ["⌘", "D"],
            category: .promptLibrary,
            contextNote: "In Prompt Detail"
        ),
        ShortcutItem(
            title: "Toggle Pin in Editor",
            description: "Pin or unpin the currently edited prompt.",
            keys: ["⌘", "P"],
            category: .promptLibrary,
            contextNote: "In Prompt Detail"
        ),
        ShortcutItem(
            title: "Delete Prompt",
            description: "Prompt to delete the currently viewed prompt.",
            keys: ["⌘", "⌫"],
            category: .promptLibrary,
            contextNote: "In Prompt Detail"
        ),
        ShortcutItem(
            title: "Cancel Batch Selection",
            description: "Exit multi-item batch selection mode.",
            keys: ["Esc"],
            category: .promptLibrary,
            contextNote: "In batch selection"
        ),
        ShortcutItem(
            title: "Delete Selected Prompts",
            description: "Delete all prompts selected in batch mode.",
            keys: ["⌘", "⌫"],
            category: .promptLibrary,
            contextNote: "In batch selection"
        ),
        ShortcutItem(
            title: "Find in Prompts",
            description: "Focus search bar to filter prompt templates.",
            keys: ["⌘", "F"],
            category: .promptLibrary,
            contextNote: "In Prompts sidebar"
        ),

        // MARK: - Task Scheduler
        ShortcutItem(
            title: "New Scheduled Task",
            description: "Open the editor to create a new scheduled or autonomous task.",
            keys: ["⌘", "N"],
            category: .scheduler,
            contextNote: "In Scheduler sidebar"
        ),
        ShortcutItem(
            title: "Browse Tasks",
            description: "Move keyboard focus up or down through the scheduled tasks.",
            keys: ["↑", "↓"],
            category: .scheduler,
            contextNote: "In Scheduler sidebar"
        ),
        ShortcutItem(
            title: "Open / Inspect Task",
            description: "Open the selected task details or jump to linked conversation.",
            keys: ["↩"],
            category: .scheduler,
            contextNote: "In Scheduler sidebar"
        ),
        ShortcutItem(
            title: "Run Task Now",
            description: "Immediately trigger execution of the focused scheduled task.",
            keys: ["R"],
            category: .scheduler,
            contextNote: "In Scheduler sidebar"
        ),
        ShortcutItem(
            title: "Pause / Resume Task",
            description: "Toggle pause status on the focused scheduled task.",
            keys: ["P"],
            category: .scheduler,
            contextNote: "In Scheduler sidebar"
        ),
        ShortcutItem(
            title: "Delete Task",
            description: "Prompt to permanently delete the focused task.",
            keys: ["⌘", "⌫"],
            category: .scheduler,
            contextNote: "In Scheduler sidebar"
        ),
        ShortcutItem(
            title: "Search Tasks",
            description: "Focus search bar to filter scheduled tasks.",
            keys: ["⌘", "F"],
            category: .scheduler,
            contextNote: "In Scheduler sidebar"
        ),

        // MARK: - Skills
        ShortcutItem(
            title: "Write New Skill",
            description: "Open the editor sheet to author a new skill from scratch.",
            keys: ["⌘", "N"],
            category: .skills,
            contextNote: "In Skills sidebar"
        ),
        ShortcutItem(
            title: "Import Skills",
            description: "Import skills from a directory, archive, or markdown document.",
            keys: ["⌘", "I"],
            category: .skills,
            contextNote: "In Skills sidebar"
        ),
        ShortcutItem(
            title: "Browse Skills",
            description: "Move keyboard focus through installed agent skills.",
            keys: ["↑", "↓"],
            category: .skills,
            contextNote: "In Skills sidebar"
        ),
        ShortcutItem(
            title: "Open Skill Detail",
            description: "Open full code, instructions, and version history for the focused skill.",
            keys: ["↩"],
            category: .skills,
            contextNote: "In Skills sidebar"
        ),
        ShortcutItem(
            title: "Delete Skill",
            description: "Prompt to delete the focused custom skill.",
            keys: ["⌘", "⌫"],
            category: .skills,
            contextNote: "In Skills sidebar"
        ),
        ShortcutItem(
            title: "Search Skills",
            description: "Focus search bar to filter agent skills.",
            keys: ["⌘", "F"],
            category: .skills,
            contextNote: "In Skills sidebar"
        ),

        // MARK: - Global Hotkeys
        ShortcutItem(
            title: "Quick Access Panel",
            description: "Summon or dismiss the floating Spotlight-style Quick Access bar anywhere in macOS.",
            keys: ["⌥", "Space"],
            category: .globalHotkeys,
            contextNote: "System-wide hotkey"
        ),
        ShortcutItem(
            title: "Orb Voice Assistant",
            description: "Hold to speak with Orb using the full-duplex voice interface.",
            keys: ["⌥", "J"],
            category: .globalHotkeys,
            contextNote: "System-wide hold-to-talk"
        ),

        // MARK: - Tools & Models
        ShortcutItem(
            title: "Add Custom MCP Server",
            description: "Open the form to configure a custom external MCP tool server.",
            keys: ["⌘", "N"],
            category: .tooling,
            contextNote: "In Tools sidebar"
        ),
        ShortcutItem(
            title: "Browse Tool Categories",
            description: "Move keyboard focus through tool categories and installed MCP servers.",
            keys: ["↑", "↓"],
            category: .tooling,
            contextNote: "In Tools sidebar"
        ),
        ShortcutItem(
            title: "Select Category / Server",
            description: "View tools belonging to the selected category or server.",
            keys: ["↩"],
            category: .tooling,
            contextNote: "In Tools sidebar"
        ),
        ShortcutItem(
            title: "Remove MCP Server",
            description: "Remove the selected external MCP server configuration.",
            keys: ["⌘", "⌫"],
            category: .tooling,
            contextNote: "In Tools sidebar"
        ),
        ShortcutItem(
            title: "Browse Downloads",
            description: "Move keyboard focus through active and historical downloads.",
            keys: ["↑", "↓"],
            category: .tooling,
            contextNote: "In Downloads sidebar"
        ),
        ShortcutItem(
            title: "Re-download Model",
            description: "Trigger re-download for the focused completed or failed download.",
            keys: ["R"],
            category: .tooling,
            contextNote: "In Downloads sidebar"
        ),
        ShortcutItem(
            title: "Cancel Download",
            description: "Cancel the focused in-progress model download.",
            keys: ["C"],
            category: .tooling,
            contextNote: "In Downloads sidebar"
        ),
        ShortcutItem(
            title: "Remove Download Record",
            description: "Remove the focused record from download history.",
            keys: ["⌘", "⌫"],
            category: .tooling,
            contextNote: "In Downloads sidebar"
        ),
        ShortcutItem(
            title: "Refresh Model Store",
            description: "Reload the model catalogue in MLX or Ollama model stores.",
            keys: ["⌘", "R"],
            category: .tooling
        ),
        ShortcutItem(
            title: "Download HuggingFace Model",
            description: "Download the model repository name typed in the search bar.",
            keys: ["⌘", "↩"],
            category: .tooling,
            contextNote: "In MLX Model Store"
        ),
        ShortcutItem(
            title: "Pull Ollama Model",
            description: "Pull the model name entered into the search field.",
            keys: ["⌘", "↩"],
            category: .tooling,
            contextNote: "In Ollama Model Store"
        ),
        ShortcutItem(
            title: "Test MCP Connection",
            description: "Test communication with the configured MCP server command or URL.",
            keys: ["⌘", "↩"],
            category: .tooling,
            contextNote: "In Add MCP Server"
        ),
        ShortcutItem(
            title: "Export Diagnostics Bundle",
            description: "Confirm export or save diagnostic support bundle.",
            keys: ["⌘", "↩"],
            category: .tooling,
            contextNote: "In Bundle Export Sheet"
        ),

        // MARK: - Settings & Profiles
        ShortcutItem(
            title: "Open Settings",
            description: "Open the application settings sidebar and general preferences.",
            keys: ["⌘", ","],
            category: .settings
        ),
        ShortcutItem(
            title: "Navigate Settings Categories",
            description: "Move keyboard selection up or down through the settings categories.",
            keys: ["↑", "↓"],
            category: .settings,
            contextNote: "In Settings sidebar"
        ),
        ShortcutItem(
            title: "Jump to Settings Category 1–7",
            description: "Directly select settings category by its number position (General through About).",
            keys: ["1–7"],
            category: .settings,
            contextNote: "In Settings sidebar"
        ),
        ShortcutItem(
            title: "Open Backend Profiles",
            description: "Switch to the Backend Profiles tab to manage AI models and configurations.",
            keys: ["⇧", "⌘", "P"],
            category: .settings
        ),
        ShortcutItem(
            title: "New Backend Profile",
            description: "Open the profile creation modal to set up a new agent, bot, or image gen profile.",
            keys: ["⌘", "N"],
            category: .settings,
            contextNote: "In Profiles sidebar"
        ),
        ShortcutItem(
            title: "Search Profiles",
            description: "Focus the profile search input field.",
            keys: ["⌘", "F"],
            category: .settings,
            contextNote: "In Profiles sidebar"
        ),
        ShortcutItem(
            title: "Browse Profiles",
            description: "Navigate keyboard focus through the list of backend profiles.",
            keys: ["↑", "↓"],
            category: .settings,
            contextNote: "In Profiles sidebar"
        ),
        ShortcutItem(
            title: "Select Profile",
            description: "Open the focused backend profile in the detail editor.",
            keys: ["↩"],
            category: .settings,
            contextNote: "In Profiles sidebar"
        ),
        ShortcutItem(
            title: "Duplicate Profile",
            description: "Open the duplicate profile sheet for the selected profile.",
            keys: ["⌘", "D"],
            category: .settings,
            contextNote: "In Profiles sidebar"
        ),
        ShortcutItem(
            title: "Delete Profile",
            description: "Prompt deletion confirmation for the selected profile.",
            keys: ["⌘", "⌫"],
            category: .settings,
            contextNote: "In Profiles sidebar"
        ),
        ShortcutItem(
            title: "Save Profile Changes",
            description: "Commit and save changes made to the active profile configuration.",
            keys: ["⌘", "S"],
            category: .settings,
            contextNote: "In Profile editor"
        ),
        ShortcutItem(
            title: "Observability Trends",
            description: "Open the Observability Trends window for reliability and telemetry inspection.",
            keys: ["⌥", "⇧", "⌘", "T"],
            category: .settings,
            contextNote: "Developer Mode"
        )
    ]
}
