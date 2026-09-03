//
//  SchemaBaselineV3.swift
//  DevgenticTests
//
//  Created on 29/08/26.
//
//  The recorded persisted shape of schema version 3.0.0 — supersedes SchemaBaselineV2
//  as the drift target (`testSchemaStructureMatchesCheckedInBaseline`). V1's and V2's
//  files stay untouched as the historical record of what each shipped, per their headers.
//
//  V3 delta over V2: exactly TWO lines, both on BackendProfile —
//    BackendProfile  + ATTR ownerNodeID: Optional<UUID> [optional]
//    BackendProfile  + ATTR ownerWorkflowID: Optional<UUID> [optional]
//  (Workflow nodes own their configuration: these mark a row as a node's private config
//  rather than a shared profile. See DevgenticSchemaVersions.swift's V3 note.)
//
//  Regenerate with the same recipe as V1 (see that file's header), pasting the
//  descriptor printed under TEST_RUNNER_DEVGENTIC_WRITE_SCHEMA_BASELINE=1 here.
//

import Foundation

/// Recorded shape of schema version 3.0.0.
enum SchemaBaselineV3 {

    /// Canonical structural descriptor of all 12 registered entities.
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
  ATTR lifecycleStateRaw: Optional<String> [optional]
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
ENTITY ConversationSD
  ATTR backendEntityId: Optional<UUID> [optional]
  ATTR backendType: Optional<String> [optional]
  ATTR id: UUID [required,unique] options=unique
  ATTR isPinned: Bool [required]
  ATTR openAIThreadID: Optional<String> [optional]
  ATTR profileTypeRaw: Optional<String> [optional]
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
  ATTR scheduledAt: Optional<Date> [optional]
  ATTR status: String [required]
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
"""
}
