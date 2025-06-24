//
//  AgentStore.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI
import CoreData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentStore")

// REMOVED: @MainActor from the class declaration to fix initializer access issue.
class AgentStore: ObservableObject {
    @Published var agents: [AgentProfileModel] = []
    
    private let persistenceService: CoreDataServiceProtocol
    private let viewContext: NSManagedObjectContext

    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        self.viewContext = (persistenceService as! CoreDataPersistenceService).viewContext
        
        // MODIFIED: Call to an actor-isolated function must be in an async context.
        Task {
            await loadAgents()
        }
    }

    /// Fetches agent profiles from Core Data and updates the published `agents` array.
    @MainActor // ADDED: Ensures this function, which modifies a @Published property, runs on the main thread.
    func loadAgents() {
        let agentEntities = persistenceService.fetchAgentProfiles()
        self.agents = agentEntities.map { $0.toAgentProfileModel() }
        logger.info("AgentStore: Loaded \(self.agents.count) agents from Core Data.")
        
        if !self.agents.isEmpty && !self.agents.contains(where: { $0.isActive }) {
            self.agents[0].isActive = true
            self.updateAgent(agent: self.agents[0])
        }
    }

    /// Adds a new agent to the local store and persists it to Core Data.
    @MainActor // ADDED: Ensures UI-related changes run on the main thread.
    func addAgent(agent: AgentProfileModel) {
        var newAgent = agent
        
        if newAgent.isActive {
            for i in 0..<agents.count {
                agents[i].isActive = false
            }
        }
        
        agents.append(newAgent)
        
        persistenceService.addAgentProfile(from: newAgent, in: viewContext)
        logger.info("Added new agent '\(newAgent.name)' and updated the store.")
    }

    /// Updates an existing agent in the local store and persists the change to Core Data.
    @MainActor // ADDED: Ensures UI-related changes run on the main thread.
    func updateAgent(agent: AgentProfileModel) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else {
            logger.warning("AgentStore: Could not find agent with ID \(agent.id.uuidString) to update.")
            return
        }
        
        var agentToUpdate = agent
        
        if agentToUpdate.isActive {
            for i in 0..<agents.count where agents[i].id != agentToUpdate.id {
                if agents[i].isActive {
                    agents[i].isActive = false
                    if let entityToDeactivate = persistenceService.getAgentProfile(withId: agents[i].id) {
                        persistenceService.updateAgentProfile(entity: entityToDeactivate, with: agents[i])
                    }
                }
            }
        }
        
        agents[index] = agentToUpdate
        
        if let entityToUpdate = persistenceService.getAgentProfile(withId: agentToUpdate.id) {
            persistenceService.updateAgentProfile(entity: entityToUpdate, with: agentToUpdate)
            logger.info("Updated agent '\(agentToUpdate.name)' and persisted changes.")
        }
    }

    /// Deletes an agent from the local store and Core Data.
    @MainActor // ADDED: Ensures UI-related changes run on the main thread.
    func deleteAgent(id: UUID) {
        guard let indexToDelete = agents.firstIndex(where: { $0.id == id }) else {
            logger.warning("AgentStore: Could not find agent with ID \(id.uuidString) to delete.")
            return
        }
        
        let wasActive = agents[indexToDelete].isActive
        
        agents.remove(at: indexToDelete)
        
        persistenceService.deleteAgentProfile(with: id)
        logger.info("Deleted agent with ID \(id.uuidString).")
        
        if wasActive && !agents.isEmpty {
            agents[0].isActive = true
            if let entityToActivate = persistenceService.getAgentProfile(withId: agents[0].id) {
                persistenceService.updateAgentProfile(entity: entityToActivate, with: agents[0])
                logger.info("Made agent '\(self.agents[0].name)' active after deletion.")
            }
        }
    }

    /// Sets a specific agent as active, deactivates others, and persists the change.
    @MainActor // ADDED: Ensures UI-related changes run on the main thread.
    func setActiveAgent(withId agentId: UUID?) {
        guard let id = agentId, let agentToActivate = agents.first(where: { $0.id == id }) else {
            logger.warning("AgentStore: Tried to set active agent with nil or invalid ID.")
            return
        }

        var mutableAgent = agentToActivate
        if !mutableAgent.isActive {
            mutableAgent.isActive = true
            updateAgent(agent: mutableAgent)
        }
    }
}
