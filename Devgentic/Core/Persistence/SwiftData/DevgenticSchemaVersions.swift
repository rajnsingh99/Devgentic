// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DevgenticSchemaVersions.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData

// MARK: - V1 (current)

// Why: once a V2 evolves a class, V1 needs frozen nested copies or it silently renders V2's shape and stores stop opening.
/// The first declared schema version.
/// Models are listed by their live top-level class, which is correct only while V1 is the sole version.
enum DevgenticSchemaV1: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// The 15 entities of this schema version.
    static var models: [any PersistentModel.Type] {
        [
            BackendProfile.self,
            MCPToolItem.self,
            MCPToolDefinitionModel.self,
            PromptModel.self,
            ScheduledTaskModel.self,
            ConversationSD.self,
            ChatMessageSD.self,
            AttachedTextFileSD.self,
            AttachedImageFileSD.self,
            DownloadRecord.self,
            WorkflowLayoutSD.self,
            WorkflowRunRecordSD.self,
            SkillSD.self,
            SkillVersionSD.self,
            SkillFileSD.self,
        ]
    }
}

// MARK: - Migration plan

// Why: versions are only added; a stage needs real FROM and TO versions, and a fictitious one fails with 134504.
/// The store's migration plan: one version, zero stages.
/// With zero stages SwiftData skips staged migration and relies on lightweight inference.
enum DevgenticMigrationPlan: SchemaMigrationPlan {

    /// Versions are listed in ascending order; the order is load-bearing.
    static var schemas: [any VersionedSchema.Type] {
        [DevgenticSchemaV1.self]
    }

    /// No stages are declared; `willMigrate`/`didMigrate` do not run for `.lightweight` stages.
    static var stages: [MigrationStage] {
        []
    }
}
