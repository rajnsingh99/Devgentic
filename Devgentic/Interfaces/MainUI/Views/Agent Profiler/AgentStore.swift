//
//  AgentStore.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentStore")

class AgentStore: ObservableObject {
    @Published var agents: [AgentProfileModel] {
        didSet {
            // Only save if the agents array is not empty.
            // This prevents writing an empty array to disk, which would
            // trigger the default agent creation on next launch.
            if !agents.isEmpty {
                saveAgents()
            }
        }
    }

    private let storageFileName = "agents.json"
    private var agentsDirectory: URL?
    private var storageFileURL: URL?

    init() {
        self.agents = []
        if let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let devgenticDir = appSupportDirectory.appendingPathComponent("Devgentic", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: devgenticDir, withIntermediateDirectories: true, attributes: nil)
                self.agentsDirectory = devgenticDir
                self.storageFileURL = devgenticDir.appendingPathComponent(storageFileName)
            } catch {
                logger.error("Failed to create agents directory: \(error.localizedDescription)")
            }
        }

        let loadedAgents = loadAgentsFromDisk()
        
        // Check if the storage file exists. If it doesn't, it's a true first launch.
        if !FileManager.default.fileExists(atPath: storageFileURL?.path ?? "") {
             logger.info("Agents file does not exist. Creating default agent for first launch.")
             let defaultAgent = AgentProfileModel.defaultAgent()
             self.agents.append(defaultAgent)
             // The didSet will handle saving.
        } else {
             self.agents = loadedAgents
             logger.info("Loaded \(self.agents.count) agents from disk.")
        }

        // This logic remains to ensure an active agent if needed, but it won't run on an intentionally empty list.
        if !self.agents.isEmpty && !self.agents.contains(where: { $0.isActive }) {
            self.agents[0].isActive = true
            logger.info("No active agent found on load. Set the first agent '\(self.agents[0].name)' to active.")
        }
    }

    func addAgent(agent: AgentProfileModel) {
        if !agents.contains(where: { $0.id == agent.id }) {
            var newAgent = agent
            // If the new agent is marked as active, deactivate all others.
            if newAgent.isActive {
                self.agents = self.agents.map {
                    var mutableAgent = $0
                    mutableAgent.isActive = false
                    return mutableAgent
                }
            }
            agents.append(newAgent)
            logger.info("AgentStore: Added new agent: \(newAgent.name). Total agents: \(self.agents.count)")
        } else {
            logger.warning("AgentStore: Agent with ID \(agent.id) already exists, not adding.")
        }
    }

    func updateAgent(agent: AgentProfileModel) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            var updatedAgent = agent
            // If the updated agent is being set to active, ensure all others are not.
            if updatedAgent.isActive {
                setActiveAgent(withId: updatedAgent.id)
            } else {
                agents[index] = updatedAgent
                // If we just deactivated the only active agent, make the first agent active
                if !agents.contains(where: { $0.isActive }), !agents.isEmpty {
                    agents[0].isActive = true
                }
            }
        }
    }

    func deleteAgent(id: UUID) {
        let wasActive = agents.first(where: { $0.id == id })?.isActive ?? false
        agents.removeAll { $0.id == id }

        // If the deleted agent was active, and there are agents remaining, make the first one active.
        if wasActive, !agents.isEmpty {
            agents[0].isActive = true
            logger.info("Deleted agent was active. Setting first agent '\(self.agents[0].name)' as new active agent.")
        }

        // If all agents are deleted, we need to remove the file from disk.
        if agents.isEmpty {
            deleteStorageFile()
        }
    }

    /// **[NEW]** Sets a specific agent as active and deactivates all others.
    /// - Parameter agentId: The ID of the agent to make active. If `nil`, all agents will be inactive.
    func setActiveAgent(withId agentId: UUID?) {
        logger.info("Setting active agent to ID: \(agentId?.uuidString ?? "nil")")
        // Use map to create a new array with updated `isActive` states.
        // This is efficient and ensures the @Published property updates correctly.
        self.agents = self.agents.map { agent in
            var mutableAgent = agent
            mutableAgent.isActive = (agent.id == agentId)
            return mutableAgent
        }
    }

    private func loadAgentsFromDisk() -> [AgentProfileModel] {
        guard let fileURL = storageFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            // If data is empty, it means user deleted all agents. Return an empty array.
            guard !data.isEmpty else {
                logger.info("Agents file is empty, returning no agents.")
                return []
            }
            let decoder = JSONDecoder()
            let loadedAgents = try decoder.decode([AgentProfileModel].self, from: data)
            return loadedAgents
        } catch {
            logger.error("Failed to load agents from disk: \(error.localizedDescription)")
            // Attempt to delete corrupted file
            deleteStorageFile()
            return []
        }
    }

    private func saveAgents() {
        guard let fileURL = storageFileURL else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(agents)
            try data.write(to: fileURL, options: [.atomicWrite])
            logger.trace("Successfully saved agents to disk.")
        } catch {
            logger.error("Failed to save agents to disk: \(error.localizedDescription)")
        }
    }
    
    private func deleteStorageFile() {
        guard let fileURL = storageFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Successfully deleted empty/corrupted agents storage file.")
        } catch {
            logger.error("Failed to delete agents storage file: \(error.localizedDescription)")
        }
    }
}
