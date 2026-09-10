// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
////
////  SecurityTools.swift
////  Devgentic
////
////  Created by Raj Singh on 08/02/26.
////
//
//import Foundation
//import OpenFoundationModels
//import OpenFoundationModelsCore
//
//// MARK: - Risk Engine Models
//
//struct RiskRule: Codable {
//    let id: String
//    let severity: String // "BLOCKED", "CONFIRM_REQUIRED", "WARN"
//    let trigger_type: String
//    let pattern: String
//    let risk_summary: String
//    let agent_guidance: String
//}
//
//struct SafetyPolicy: Codable {
//    let rules: [RiskRule]
//}
//
//struct RiskAssessmentResult: Codable {
//    let status: String
//    let violation_id: String?
//    let risk_summary: String
//    let agent_guidance: String
//}
//
//// MARK: - The Judge Engine
//
//class RiskPolicyEngine {
//    static let shared = RiskPolicyEngine()
//    private var rules: [RiskRule] = []
//    
//    init() {
//        loadRules()
//    }
//    
//    private func loadRules() {
//        if let url = Bundle.main.url(forResource: "SafetyPolicy", withExtension: "json"),
//           let data = try? Data(contentsOf: url) {
//            let policy = try? JSONDecoder().decode(SafetyPolicy.self, from: data)
//            self.rules = policy?.rules ?? []
//        } else {
//            print("CRITICAL: SafetyPolicy.json not found.")
//        }
//    }
//    
//    func evaluate(command: String) -> RiskAssessmentResult {
//        // 1. Discovery Phase Check: Reject relative paths for destructive commands
//        if command.contains("rm ") && !command.hasPrefix("/") && !command.contains(" /") {
//             // Heuristic: If it looks like a relative path delete
//             return RiskAssessmentResult(
//                status: "BLOCKED",
//                violation_id: "PATH_AMBIGUITY",
//                risk_summary: "Relative Path Detection",
//                agent_guidance: "You are attempting to delete a file using a relative path. You MUST resolve the Absolute Path (using `ls` or `find`) before assessing risk."
//             )
//        }
//
//        // 2. Rule Check
//        for rule in rules {
//            if rule.trigger_type == "regex" {
//                if command.range(of: rule.pattern, options: .regularExpression) != nil {
//                    return RiskAssessmentResult(
//                        status: rule.severity,
//                        violation_id: rule.id,
//                        risk_summary: rule.risk_summary,
//                        agent_guidance: rule.agent_guidance
//                    )
//                }
//            }
//        }
//        
//        return RiskAssessmentResult(
//            status: "SAFE",
//            violation_id: nil,
//            risk_summary: "No heuristic violations found.",
//            agent_guidance: "Proceed with execution."
//        )
//    }
//}
//
//// MARK: - The Tool Wrapper
//
//struct RiskAssessmentTool: OpenFoundationModels.Tool {
//    let name = "assess_risk"
//    let description = "MANDATORY PRE-FLIGHT CHECK. Call this before running ANY command that modifies files, deletes data, or executes scripts. Returns a JSON verdict."
//    
//    struct Arguments: Codable, ConvertibleFromGeneratedContent {
//        let command_to_run: String
//        init(_ content: GeneratedContent) throws {
//            let props = try content.properties()
//            guard let val = props["command_to_run"] else { throw GeneratedContentError.missingProperty("command_to_run") }
//            self.command_to_run = try String(val)
//        }
//    }
//    
//    var parameters: GenerationSchema {
//        let root = DynamicGenerationSchema(
//            name: "Arguments",
//            properties: [
//                DynamicGenerationSchema.Property(
//                    name: "command_to_run",
//                    description: "The exact shell command string you intend to execute.",
//                    schema: DynamicGenerationSchema(type: String.self)
//                )
//            ]
//        )
//        return try! GenerationSchema(root: root, dependencies: [])
//    }
//    
//    typealias Output = String
//    
//    func call(arguments: Arguments) async throws -> String {
//        let result = RiskPolicyEngine.shared.evaluate(command: arguments.command_to_run)
//        
//        // Return JSON String for the Agent to parse
//        let encoder = JSONEncoder()
//        if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
//            return json
//        }
//        return "{\"status\": \"ERROR\", \"message\": \"Failed to encode risk result\"}"
//    }
//}
