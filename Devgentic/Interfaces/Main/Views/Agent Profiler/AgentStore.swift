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

class AgentStore: ObservableObject {
    
    @Published var agents: [AgentProfileModel] = []
    
    @Published var selectedAgentID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedAgentID?.uuidString, forKey: "selectedAgentID")
            logger.info("Selected agent ID changed to: \(self.selectedAgentID?.uuidString ?? "nil")")
        }
    }

    private let persistenceService: CoreDataServiceProtocol
    private let viewContext: NSManagedObjectContext

    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        self.viewContext = (persistenceService as! CoreDataPersistenceService).viewContext
        
        // FIXED: Explicitly run the task on the @MainActor to guarantee all UI-related
        // @Published properties are updated on the main thread.
        Task { @MainActor in
            await loadAgents()
            
            if let savedIDString = UserDefaults.standard.string(forKey: "selectedAgentID"),
               let savedID = UUID(uuidString: savedIDString),
               agents.contains(where: { $0.id == savedID }) {
                self.selectedAgentID = savedID
            } else {
                self.selectedAgentID = agents.first?.id
            }
        }
    }
    
    var currentAgent: AgentProfileModel? {
        guard let selectedID = selectedAgentID else { return nil }
        return agents.first(where: { $0.id == selectedID })
    }

    @MainActor
    func loadAgents() {
        let agentEntities = persistenceService.fetchAgentProfiles()
        self.agents = agentEntities.map { $0.toAgentProfileModel() }
        logger.info("AgentStore: Loaded \(self.agents.count) agents from Core Data.")
    }

    @MainActor
    func addAgent(agent: AgentProfileModel) {
        agents.append(agent)
        persistenceService.addAgentProfile(from: agent, in: viewContext)
        self.selectedAgentID = agent.id
        logger.info("Added new agent '\(agent.name)' and set it as active.")
    }

    @MainActor
    func updateAgent(agent: AgentProfileModel) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else {
            logger.warning("AgentStore: Could not find agent with ID \(agent.id.uuidString) to update.")
            return
        }
        
        agents[index] = agent
        
        if let entityToUpdate = persistenceService.getAgentProfile(withId: agent.id) {
            persistenceService.updateAgentProfile(entity: entityToUpdate, with: agent)
            logger.info("Updated agent '\(agent.name)' and persisted changes.")
        }
    }

    @MainActor
    func deleteAgent(id: UUID) {
        agents.removeAll { $0.id == id }
        persistenceService.deleteAgentProfile(with: id)
        logger.info("Deleted agent with ID \(id.uuidString).")
        
        if selectedAgentID == id {
            selectedAgentID = agents.first?.id
            logger.info("Deleted agent was active. New active agent is '\(self.currentAgent?.name ?? "none")'.")
        }
    }
}
