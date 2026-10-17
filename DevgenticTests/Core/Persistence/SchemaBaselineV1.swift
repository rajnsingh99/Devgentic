// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SchemaBaselineV1.swift
//  DevgenticTests
//
//  The recorded persisted shape of schema version 1.0.0 — the shape the first shipped build will
//  carry. Drift target of `testSchemaStructureMatchesCheckedInBaseline` and of
//  `testV1RendersExactlyTheV1Baseline`.
//
//  ⚠️ RECORDED 2026-09-23 AT THE HISTORY RESET. The development history (baselines V1, V2, V3 and V6)
//  was collapsed into this one before any build reached anyone; see `DevgenticSchemaVersions.swift`.
//  15 entities. Amended once more before any build shipped, at the 2026-10-03 fresh start:
//  `ConversationSD.backendType` and `ConversationSD.openAIThreadID` removed (both unread).
//  Amended again 2026-10-11, still pre-ship (owner decision, RAG-10 / CR-66): composite indexes
//  `ChatMessageSD (conversationId, timestamp)` and `WorkflowRunRecordSD (conversationID, timestamp)`.
//  Index-only — attributes unchanged. Indexes are outside Core Data's version hash, so stores
//  created before this amendment open unchanged and simply lack the two indexes.
//
//  ⚠️ ONCE A BUILD SHIPS, THIS FILE IS A HISTORICAL RECORD AND IS NEVER EDITED. A schema change
//  then gets a NEW `SchemaBaselineV2`, and the drift test is pointed at it; this file keeps saying
//  what V1 shipped, which is exactly what `testV1RendersExactlyTheV1Baseline` checks the frozen V1
//  against. Editing it to turn a build green erases the record the guard exists to keep.
//
//  ⚠️ NOTE WHAT IS *NOT* HERE: `SkillVersionSD.allowedToolsJSON` is `Optional<String>`, NOT
//  `Optional<Array<String>>`. Below macOS 26.1 SwiftData persists a native `[String]?` as Binary
//  Data and a store written there fails to open on 26.1+ with NSCocoaErrorDomain 134140.
//  `PromptModel.tags` is the only attribute of that shape, which
//  `testTagsRemainsTheOnlyNonRelationshipCollectionAttribute` exists to preserve.
//
//  ⚠️ Regenerate with the TEST_RUNNER_-PREFIXED variable; without the prefix xcodebuild forwards
//  nothing to the test host and the hatch prints nothing at all:
//
//    TEST_RUNNER_DEVGENTIC_WRITE_SCHEMA_BASELINE=1 \
//    TEST_RUNNER_DEVGENTIC_SKIP_LAUNCH_SWEEP=1 \
//    TEST_RUNNER_DEVGENTIC_STORE_URL="$TMPDIR/devgentic-testhost.store" \
//    xcodebuild test-without-building -scheme devgentic -destination 'platform=macOS' \
//      -only-testing:devgenticTests/SchemaMigrationTests/testSchemaStructureMatchesCheckedInBaseline
//

import Foundation

/// Recorded shape of schema version 1.0.0.
enum SchemaBaselineV1 {

    /// Canonical structural descriptor of all 15 registered entities.
    static let descriptor = """
ENTITY AttachedImageFileSD
  ATTR binaryData: Data [required] options=externalStorage
  ATTR fileExtension: String [required]
  ATTR id: UUID [required,unique] options=unique
  ATTR name: String [required]
  ATTR size: Int64 [required]
  ATTR url: String [required]
  UNIQUE (id)
ENTITY AttachedTextFileSD
  ATTR content: String [required]
  ATTR deliveryKind: Optional<String> [optional]
  ATTR deliverySentChars: Optional<Int> [optional]
  ATTR deliveryTotalChars: Optional<Int> [optional]
  ATTR fileExtension: String [required]
  ATTR id: UUID [required,unique] options=unique
  ATTR name: String [required]
  ATTR size: Int64 [required]
  ATTR url: String [required]
  UNIQUE (id)
ENTITY BackendProfile
  ATTR configData: Data [required]
  ATTR displayName: String [required]
  ATTR fileContextStrategyRaw: Optional<String> [optional]
  ATTR id: UUID [required,unique] options=unique
  ATTR lastSelected: Optional<Date> [optional]
  ATTR modelNameRaw: String [required]
  ATTR ownerNodeID: Optional<UUID> [optional]
  ATTR ownerWorkflowID: Optional<UUID> [optional]
  ATTR profileTypeRaw: String [required]
  ATTR providerRaw: String [required]
  UNIQUE (id)
ENTITY ChatMessageSD
  ATTR agentResponseData: Optional<Data> [optional]
  ATTR apiProvider: Optional<String> [optional]
  ATTR contentData: Data [required]
  ATTR conversationId: UUID [required]
  ATTR id: UUID [required,unique] options=unique
  ATTR isSyntheticPrompt: Optional<Bool> [optional]
  ATTR lifecycleStateRaw: Optional<String> [optional]
  ATTR messageSourceRaw: Optional<String> [optional]
  ATTR modelDialect: Optional<String> [optional]
  ATTR modelName: Optional<String> [optional]
  ATTR parkedOperationID: Optional<String> [optional]
  ATTR profileTypeRaw: Optional<String> [optional]
  ATTR senderType: String [required]
  ATTR terminalOutcomeRaw: Optional<String> [optional]
  ATTR terminalReason: Optional<String> [optional]
  ATTR timelineEventsData: Optional<Data> [optional]
  ATTR timestamp: Date [required]
  ATTR tokenUsageData: Optional<Data> [optional]
  ATTR traceID: Optional<String> [optional]
  REL  attachedImageFiles: Array<AttachedImageFileSD> [required] -> AttachedImageFileSD delete=cascade inverse=none
  REL  attachedTextFiles: Array<AttachedTextFileSD> [required] -> AttachedTextFileSD delete=cascade inverse=none
  REL  conversation: Optional<ConversationSD> [optional] -> ConversationSD delete=nullify inverse=messages
  UNIQUE (id)
  INDEX (binary+conversationId+timestamp)
ENTITY ConversationSD
  ATTR backendEntityId: Optional<UUID> [optional]
  ATTR id: UUID [required,unique] options=unique
  ATTR isPinned: Bool [required]
  ATTR profileTypeRaw: Optional<String> [optional]
  ATTR projectPath: Optional<String> [optional]
  ATTR timestamp: Date [required]
  ATTR userDefinedTitle: Optional<String> [optional]
  REL  messages: Array<ChatMessageSD> [required] -> ChatMessageSD delete=cascade inverse=conversation
  REL  workflowRuns: Array<WorkflowRunRecordSD> [required] -> WorkflowRunRecordSD delete=cascade inverse=conversation
  UNIQUE (id)
ENTITY DownloadRecord
  ATTR backendRaw: String [required]
  ATTR cancelReason: Optional<String> [optional]
  ATTR completedAt: Optional<Date> [optional]
  ATTR displayName: String [required]
  ATTR errorMessage: Optional<String> [optional]
  ATTR fileSizeBytes: Optional<Int64> [optional]
  ATTR id: UUID [required,unique] options=unique
  ATTR modelIdentifier: String [required]
  ATTR profileID: Optional<UUID> [optional]
  ATTR progress: Double [required]
  ATTR revisionCommitHash: Optional<String> [optional]
  ATTR sourceURL: Optional<String> [optional]
  ATTR startedAt: Date [required]
  ATTR statusRaw: String [required]
  ATTR updatedAt: Date [required]
  UNIQUE (id)
  INDEX (binary+backendRaw)
  INDEX (binary+modelIdentifier)
  INDEX (binary+statusRaw)
  INDEX (binary+updatedAt)
ENTITY MCPToolDefinitionModel
  ATTR annotationsData: Optional<Data> [optional]
  ATTR iconsData: Optional<Data> [optional]
  ATTR name: String [required]
  ATTR parametersData: Optional<Data> [optional]
  ATTR requiresConfirmation: Bool [required]
  ATTR title: Optional<String> [optional]
  ATTR toolDescription: String [required]
  REL  toolItem: Optional<MCPToolItem> [optional] -> MCPToolItem delete=nullify inverse=tools
ENTITY MCPToolItem
  ATTR id: UUID [required,unique] options=unique
  ATTR isEnabled: Bool [required]
  ATTR mcpConfigData: Optional<Data> [optional]
  ATTR serverName: String [required]
  REL  tools: Array<MCPToolDefinitionModel> [required] -> MCPToolDefinitionModel delete=cascade inverse=toolItem
  UNIQUE (id)
ENTITY PromptModel
  ATTR category: String [required]
  ATTR createdAt: Date [required]
  ATTR id: UUID [required,unique] options=unique
  ATTR isPinned: Bool [required]
  ATTR isUserDefined: Bool [required]
  ATTR lastUsedAt: Optional<Date> [optional]
  ATTR tags: Optional<Array<String>> [optional] options=transformable with Optional("NSSecureUnarchiveFromData")
  ATTR text: String [required]
  ATTR title: String [required]
  UNIQUE (id)
ENTITY ScheduledTaskModel
  ATTR attachedFileURLsJSON: Optional<String> [optional]
  ATTR contextWindowMode: String [required]
  ATTR createdAt: Date [required]
  ATTR cronExpression: Optional<String> [optional]
  ATTR displayName: String [required]
  ATTR id: UUID [required,unique] options=unique
  ATTR isEnabled: Bool [required]
  ATTR isPaused: Bool [required]
  ATTR lastRunAt: Optional<Date> [optional]
  ATTR lastRunSummary: Optional<String> [optional]
  ATTR linkedConversationID: Optional<UUID> [optional]
  ATTR mode: String [required]
  ATTR nextRunAt: Optional<Date> [optional]
  ATTR profileID: Optional<UUID> [optional]
  ATTR promptTemplate: String [required]
  ATTR runCount: Int [required]
  ATTR runLimitSeconds: Optional<Double> [optional]
  ATTR scheduledAt: Optional<Date> [optional]
  ATTR status: String [required]
  UNIQUE (id)
ENTITY SkillFileSD
  ATTR content: Data [required] options=externalStorage
  ATTR isExecutable: Bool [required]
  ATTR relativePath: String [required]
  REL  version: Optional<SkillVersionSD> [optional] -> SkillVersionSD delete=nullify inverse=files
ENTITY SkillSD
  ATTR createdAt: Date [required]
  ATTR displayName: String [required]
  ATTR id: String [required,unique] options=unique
  ATTR isAgentWritable: Bool [required]
  ATTR isDraft: Bool [required]
  ATTR latestVersionID: Optional<String> [optional]
  ATTR name: String [required]
  ATTR originRaw: String [required]
  REL  versions: Array<SkillVersionSD> [required] -> SkillVersionSD delete=cascade inverse=skill
  UNIQUE (id)
ENTITY SkillVersionSD
  ATTR allowedToolsJSON: Optional<String> [optional]
  ATTR body: String [required]
  ATTR createdAt: Date [required]
  ATTR id: String [required,unique] options=unique
  ATTR note: String [required]
  ATTR skillDescription: String [required]
  REL  files: Array<SkillFileSD> [required] -> SkillFileSD delete=cascade inverse=version
  REL  skill: Optional<SkillSD> [optional] -> SkillSD delete=nullify inverse=versions
  UNIQUE (id)
ENTITY WorkflowLayoutSD
  ATTR annotationCount: Int [required]
  ATTR edgeCount: Int [required]
  ATTR layoutData: Data [required]
  ATTR nodeCount: Int [required]
  ATTR updatedAt: Date [required]
  ATTR workflowProfileID: UUID [required,unique] options=unique
  UNIQUE (workflowProfileID)
ENTITY WorkflowRunRecordSD
  ATTR conversationID: UUID [required]
  ATTR duration: Double [required]
  ATTR errorMessage: Optional<String> [optional]
  ATTR finalOutput: String [required]
  ATTR id: UUID [required,unique] options=unique
  ATTR nodeResultsData: Data [required]
  ATTR statusRaw: String [required]
  ATTR timestamp: Date [required]
  ATTR traceID: Optional<String> [optional]
  ATTR userInput: String [required]
  ATTR variablesData: Data [required]
  ATTR workflowName: String [required]
  ATTR workflowProfileID: UUID [required]
  REL  conversation: Optional<ConversationSD> [optional] -> ConversationSD delete=nullify inverse=workflowRuns
  UNIQUE (id)
  INDEX (binary+conversationID+timestamp)
"""
}
