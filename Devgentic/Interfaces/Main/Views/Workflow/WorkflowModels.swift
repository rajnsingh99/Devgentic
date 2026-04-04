//
//  WorkflowModels.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Data models for the visual workflow canvas: nodes, edges, ports, and DAG definition.
//

import Foundation

// MARK: - Port Type

enum PortType: String, Codable, Hashable {
    case input
    case output
}

// MARK: - Workflow Node

/// A single node on the canvas, wrapping a reference to a `BackendProfileModel`.
struct WorkflowNode: Identifiable, Codable, Hashable {
    let id: UUID
    let profileID: UUID
    var position: CGPoint

    /// Cached profile metadata for display (populated at load time, not persisted via coding).
    var displayName: String
    var profileType: ProfileType

    init(id: UUID = UUID(), profileID: UUID, position: CGPoint, displayName: String, profileType: ProfileType) {
        self.id = id
        self.profileID = profileID
        self.position = position
        self.displayName = displayName
        self.profileType = profileType
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, profileID, positionX, positionY, displayName, profileType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        let x = try container.decode(CGFloat.self, forKey: .positionX)
        let y = try container.decode(CGFloat.self, forKey: .positionY)
        position = CGPoint(x: x, y: y)
        displayName = try container.decode(String.self, forKey: .displayName)
        profileType = try container.decode(ProfileType.self, forKey: .profileType)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(position.x, forKey: .positionX)
        try container.encode(position.y, forKey: .positionY)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(profileType, forKey: .profileType)
    }
}

// MARK: - Workflow Edge

/// A directed connection between two nodes (source output → target input).
struct WorkflowEdge: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceNodeID: UUID
    let targetNodeID: UUID

    init(id: UUID = UUID(), sourceNodeID: UUID, targetNodeID: UUID) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
    }

    /// Validates the connection against communication constraints.
    /// All profile type combinations are now allowed (Bot→Agent unblocked for capability-based agents).
    static func isValid(sourceType: ProfileType, targetType: ProfileType) -> Bool {
        true
    }
}

// MARK: - Workflow Layout

/// Persistable canvas layout — stored as a sidecar alongside the profile.
/// Keeps node positions and edge connections without modifying `ProfileDetails.workflow`.
struct WorkflowLayout: Codable {
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]

    static let empty = WorkflowLayout(nodes: [], edges: [])

    // MARK: - Cycle Detection (DFS)

    /// Returns `true` if adding an edge from `source` to `target` would create a cycle.
    func wouldCreateCycle(source: UUID, target: UUID) -> Bool {
        // Build adjacency list including the proposed new edge
        var adjacency: [UUID: [UUID]] = [:]
        for edge in edges {
            adjacency[edge.sourceNodeID, default: []].append(edge.targetNodeID)
        }
        adjacency[source, default: []].append(target)

        // DFS from target to see if we can reach source (cycle)
        var visited: Set<UUID> = []
        var stack: [UUID] = [target]

        while let current = stack.popLast() {
            if current == source { return true }
            if visited.contains(current) { continue }
            visited.insert(current)

            if let neighbors = adjacency[current] {
                stack.append(contentsOf: neighbors)
            }
        }
        return false
    }

    /// Returns nodes in topological order, or nil if the graph has a cycle.
    func topologicalSort() -> [UUID]? {
        var inDegree: [UUID: Int] = [:]
        var adjacency: [UUID: [UUID]] = [:]

        for node in nodes {
            inDegree[node.id] = 0
            adjacency[node.id] = []
        }

        for edge in edges {
            adjacency[edge.sourceNodeID, default: []].append(edge.targetNodeID)
            inDegree[edge.targetNodeID, default: 0] += 1
        }

        var queue = nodes.map(\.id).filter { (inDegree[$0] ?? 0) == 0 }
        var result: [UUID] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            result.append(current)

            for neighbor in adjacency[current] ?? [] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        return result.count == nodes.count ? result : nil
    }
}

// MARK: - Drag State

/// Tracks an in-progress edge being drawn from an output port.
struct EdgeDragState {
    let sourceNodeID: UUID
    var currentPoint: CGPoint
}
