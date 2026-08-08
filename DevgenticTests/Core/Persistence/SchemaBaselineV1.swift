//
//  SchemaBaselineV1.swift
//  DevgenticTests
//
//  Created on 04/08/26.
//
//  The recorded persisted shape of the production SwiftData schema.
//
//  This is a GIT-DIFFABLE RECORD, not configuration. `SchemaMigrationTests
//  .testSchemaStructureMatchesCheckedInBaseline` renders the live schema into the same format and
//  fails on any difference, so a hash-perturbing edit shows up as a reviewable diff in this file
//  instead of as a launch failure on a user's machine (SWIFTDATA_GAP_REGISTER.md G1).
//
//  ⚠️ Only the fields that feed Core Data's model version hash are recorded: entity name, and per
//  property its name, original name, value type, optionality, and the transient/unique flags —
//  plus uniqueness constraints and indices. Swift default VALUES are deliberately absent: they do
//  not participate in the hash, so adding one is safe and must not require touching this file.
//
//  Attribute `options=` are recorded for REVIEW value, not because they perturb the hash.
//  Two are load-bearing:
//    - `binaryData: Data options=externalStorage` — the payload lives in the hidden
//      `.DevgenticSD_SUPPORT/_EXTERNAL_DATA` sidecar, not in the store file. Any copy/move/export
//      that ignores that directory is silently incomplete.
//    - `tags: Optional<Array<String>> options=transformable with Optional("NSSecureUnarchiveFromData")`
//      — this marking is chosen by the OS, not by us. It CHANGED between macOS 26.0 and 26.1
//      (Binary Data -> Transformable) and bricked shipped apps with no developer change. Recording
//      it here turns a future OS-side change into a loud test failure instead of a launch failure.
//
//  ⚠️ TO UPDATE: do not paste a new value in to make the build green. First decide whether the
//  change is lightweight-migratable (safety table in SWIFTDATA_MIGRATION_PLAN.md). If it is not,
//  it needs a migration stage, and this baseline should be superseded by a V2 rather than edited.
//
//  Regenerate with:
//    TEST_RUNNER_DEVGENTIC_WRITE_SCHEMA_BASELINE=1 \
//    TEST_RUNNER_DEVGENTIC_SKIP_LAUNCH_SWEEP=1 \
//    TEST_RUNNER_DEVGENTIC_STORE_URL="$TMPDIR/devgentic-testhost.store" \
//    xcodebuild test-without-building -scheme devgentic -destination 'platform=macOS' \
//      -only-testing:devgenticTests/SchemaMigrationTests/testSchemaStructureMatchesCheckedInBaseline
//
//  ⚠️ The TEST_RUNNER_ prefix is REQUIRED: xcodebuild does not forward the shell environment to
//  the test host, so a bare DEVGENTIC_* variable is silently ignored and the app host opens the
//  developer's REAL store instead of a temporary one.
//

import Foundation

/// Recorded shape of schema version 1.0.0 — the shape the first shipped build will carry.
///
/// ⚠️ 2026-08-04: `CodeViewerSessionSD` and `ConversationSD.codeViewerSessions` were RETIRED
/// before this shape was frozen, deliberately. Freezing V1 with the entity still present would
/// have canonized a tombstone and made the very next release an entity-deletion migration. The
/// drop was verified against a real store containing a linked row — see
/// `SchemaMigrationTests.testRetiredCodeViewerEntityDropsWithoutLosingConversations`.
enum SchemaBaselineV1 {

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
  ATTR userInput: String [required]
  ATTR variablesData: Data [required]
  ATTR workflowName: String [required]
  ATTR workflowProfileID: UUID [required]
  REL  conversation: Optional<ConversationSD> [optional] -> ConversationSD delete=nullify inverse=workflowRuns
  UNIQUE (id)
"""
}
