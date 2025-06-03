//
//  AgentStore.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI

class AgentStore: ObservableObject {
    @Published var agents: [Agent] {
        didSet {
            saveAgents()
        }
    }

    private let storageFileName = "agents.json"
    private var agentsDirectory: URL?

    init() {
        self.agents = []
        if let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let devgenticDir = appSupportDirectory.appendingPathComponent("Devgentic", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: devgenticDir, withIntermediateDirectories: true, attributes: nil)
                self.agentsDirectory = devgenticDir
            } catch {
                print("Failed to create agents directory: \(error.localizedDescription)")
                self.agentsDirectory = nil
            }
        }

        let loadedAgents = loadAgentsFromDisk()
        if !loadedAgents.isEmpty {
            self.agents = loadedAgents
        }

        if self.agents.isEmpty {
            let defaultAgent = Agent.defaultAgent()
            self.agents.append(defaultAgent)
            print("No agents found or loaded, created a default DevAgent.")
        }
    }

    func addAgent(agent: Agent) {
        if !agents.contains(where: { $0.id == agent.id }) {
            agents.append(agent)
            // Debug print to confirm agent is added and @Published is triggered
            print("AgentStore: Added new agent: \(agent.name). Total agents: \(agents.count)")
        } else {
            print("AgentStore: Agent with ID \(agent.id) already exists, not adding.")
        }
    }

    func updateAgent(agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
        }
    }

    func deleteAgent(id: UUID) {
        agents.removeAll { $0.id == id }
    }

    private func loadAgentsFromDisk() -> [Agent] {
        guard let directory = agentsDirectory else { return [] }
        let fileURL = directory.appendingPathComponent(storageFileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let loadedAgents = try decoder.decode([Agent].self, from: data)
            return loadedAgents
        } catch {
            print("Failed to load agents from disk: \(error.localizedDescription)")
            // Attempt to delete corrupted file
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("Corrupted agents file deleted.")
            } catch {
                print("Failed to delete corrupted agents file: \(error.localizedDescription)")
            }
            return []
        }
    }

    private func saveAgents() {
        guard let directory = agentsDirectory else { return }
        let fileURL = directory.appendingPathComponent(storageFileName)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(agents)
            try data.write(to: fileURL, options: [.atomicWrite])
        } catch {
            print("Failed to save agents to disk: \(error.localizedDescription)")
        }
    }
}
