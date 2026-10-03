// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TraceStoreBaselineSchemaTests.swift
//  DevgenticTests
//
//  ⚠️ PINS THE SQUASHED BASELINE (2026-10-03). The trace database's eight incremental migrations
//  were collapsed into one `v1_create_tables`. A database that already ran the old ladder keeps its
//  tables and skips the baseline, so the baseline MUST produce exactly the schema the ladder did —
//  otherwise a new install and an old one disagree about columns and one of them breaks at the first
//  query that touches the difference.
//
//  `expected` was captured from a real database that had run all eight retired migrations, by the
//  same column / foreign-key / index query `TraceStore.schemaFingerprint()` runs. Any future schema
//  change goes in a NEW migration — update this fixture with it, never edit the baseline.
//

import XCTest
@testable import devgentic

final class TraceStoreBaselineSchemaTests: XCTestCase {

    private let expected: [String] = [
        "col hitl_audit.conversationID|TEXT|1||0",
        "col hitl_audit.interface|TEXT|1||0",
        "col hitl_audit.nodeName|TEXT|0||0",
        "col hitl_audit.operationID|TEXT|1||1",
        "col hitl_audit.outcome|TEXT|0||0",
        "col hitl_audit.raisedAt|DOUBLE|1||0",
        "col hitl_audit.resolvedAt|DOUBLE|0||0",
        "col hitl_audit.spanID|TEXT|0||0",
        "col hitl_audit.title|TEXT|1||0",
        "col hitl_audit.toolName|TEXT|0||0",
        "col hitl_audit.traceID|TEXT|0||0",
        "col hitl_audit.type|TEXT|1||0",
        "col log_entries.category|TEXT|0||0",
        "col log_entries.id|INTEGER|0||1",
        "col log_entries.level|TEXT|1||0",
        "col log_entries.message|TEXT|0||0",
        "col log_entries.metadataJSON|TEXT|0||0",
        "col log_entries.phase|TEXT|0||0",
        "col log_entries.spanID|TEXT|0||0",
        "col log_entries.subsystem|TEXT|0||0",
        "col log_entries.timestamp|DOUBLE|1||0",
        "col log_entries.traceID|TEXT|0||0",
        "col span_events.causedByEventID|INTEGER|0||0",
        "col span_events.content|TEXT|0||0",
        "col span_events.detailJSON|TEXT|0||0",
        "col span_events.durationMs|INTEGER|0||0",
        "col span_events.errorCategory|TEXT|0||0",
        "col span_events.errorChainID|TEXT|0||0",
        "col span_events.eventType|TEXT|1||0",
        "col span_events.id|INTEGER|0||1",
        "col span_events.iterationNumber|INTEGER|0||0",
        "col span_events.phase|TEXT|0||0",
        "col span_events.severity|TEXT|0|'info'|0",
        "col span_events.spanID|TEXT|1||0",
        "col span_events.timestamp|DOUBLE|1||0",
        "col span_events.traceID|TEXT|1||0",
        "col spans.endedAt|DOUBLE|0||0",
        "col spans.kind|TEXT|1||0",
        "col spans.metadataJSON|TEXT|0||0",
        "col spans.name|TEXT|1||0",
        "col spans.parentSpanID|TEXT|0||0",
        "col spans.spanID|TEXT|1||1",
        "col spans.startedAt|DOUBLE|1||0",
        "col spans.status|TEXT|1|'running'|0",
        "col spans.traceID|TEXT|1||0",
        "col trace_configs.appVersion|TEXT|1||0",
        "col trace_configs.capabilitiesCount|INTEGER|1|0|0",
        "col trace_configs.historyStrategy|TEXT|0||0",
        "col trace_configs.instructionsHash|TEXT|0||0",
        "col trace_configs.memoryBudgetBytes|INTEGER|0||0",
        "col trace_configs.modelName|TEXT|1||0",
        "col trace_configs.osVersion|TEXT|1||0",
        "col trace_configs.profileType|TEXT|1||0",
        "col trace_configs.provider|TEXT|1||0",
        "col trace_configs.snapshotJSON|TEXT|1||0",
        "col trace_configs.thinkingEnabled|BOOLEAN|1|0|0",
        "col trace_configs.toolsCount|INTEGER|1|0|0",
        "col trace_configs.traceID|TEXT|1||1",
        "col traces.appVersion|TEXT|0||0",
        "col traces.buildNumber|TEXT|0||0",
        "col traces.conversationID|TEXT|1||0",
        "col traces.endedAt|DOUBLE|0||0",
        "col traces.errorSummary|TEXT|0||0",
        "col traces.estimatedCostUSD|DOUBLE|0||0",
        "col traces.inputTokens|INTEGER|0||0",
        "col traces.messageID|TEXT|1||0",
        "col traces.metadataJSON|TEXT|0||0",
        "col traces.modelName|TEXT|0||0",
        "col traces.outputTokens|INTEGER|0||0",
        "col traces.profileID|TEXT|1||0",
        "col traces.profileName|TEXT|1||0",
        "col traces.profileType|TEXT|1||0",
        "col traces.provider|TEXT|0||0",
        "col traces.startedAt|DOUBLE|1||0",
        "col traces.status|TEXT|1|'running'|0",
        "col traces.tokensEstimated|BOOLEAN|0||0",
        "col traces.traceID|TEXT|1||1",
        "fk span_events.spanID>spans.spanID|CASCADE",
        "fk spans.traceID>traces.traceID|CASCADE",
        "fk trace_configs.traceID>traces.traceID|CASCADE",
        "idx CREATE INDEX \"idx_events_category\" ON \"span_events\"(\"errorCategory\") WHERE \"errorCategory\" IS NOT NULL",
        "idx CREATE INDEX \"idx_events_chain\" ON \"span_events\"(\"errorChainID\") WHERE \"errorChainID\" IS NOT NULL",
        "idx CREATE INDEX \"idx_events_phase\" ON \"span_events\"(\"phase\") WHERE \"phase\" IS NOT NULL",
        "idx CREATE INDEX \"idx_events_span\" ON \"span_events\"(\"spanID\")",
        "idx CREATE INDEX \"idx_events_timestamp\" ON \"span_events\"(\"timestamp\")",
        "idx CREATE INDEX \"idx_events_trace\" ON \"span_events\"(\"traceID\")",
        "idx CREATE INDEX \"idx_hitl_audit_conversation\" ON \"hitl_audit\"(\"conversationID\")",
        "idx CREATE INDEX \"idx_hitl_audit_raisedAt\" ON \"hitl_audit\"(\"raisedAt\")",
        "idx CREATE INDEX \"idx_hitl_audit_trace\" ON \"hitl_audit\"(\"traceID\") WHERE \"traceID\" IS NOT NULL",
        "idx CREATE INDEX \"idx_logs_level\" ON \"log_entries\"(\"level\")",
        "idx CREATE INDEX \"idx_logs_timestamp\" ON \"log_entries\"(\"timestamp\")",
        "idx CREATE INDEX \"idx_logs_trace\" ON \"log_entries\"(\"traceID\") WHERE \"traceID\" IS NOT NULL",
        "idx CREATE INDEX \"idx_spans_parent\" ON \"spans\"(\"parentSpanID\")",
        "idx CREATE INDEX \"idx_spans_trace\" ON \"spans\"(\"traceID\")",
        "idx CREATE INDEX \"idx_trace_configs_app_version\" ON \"trace_configs\"(\"appVersion\")",
        "idx CREATE INDEX \"idx_trace_configs_instr_hash\" ON \"trace_configs\"(\"instructionsHash\") WHERE \"instructionsHash\" IS NOT NULL",
        "idx CREATE INDEX \"idx_trace_configs_model\" ON \"trace_configs\"(\"modelName\")",
        "idx CREATE INDEX \"idx_trace_configs_profile_type\" ON \"trace_configs\"(\"profileType\")",
        "idx CREATE INDEX \"idx_trace_configs_provider\" ON \"trace_configs\"(\"provider\")",
        "idx CREATE INDEX \"idx_traces_conversation\" ON \"traces\"(\"conversationID\")",
        "idx CREATE INDEX \"idx_traces_message\" ON \"traces\"(\"messageID\")",
    ]

    func testTheBaselineProducesExactlyTheRetiredLaddersSchema() throws {
        let store = try TraceStore(inMemory: true)
        let actual = try store.schemaFingerprint()

        XCTAssertEqual(Set(actual).subtracting(expected).sorted(), [], "in the baseline but not the retired ladder")
        XCTAssertEqual(Set(expected).subtracting(actual).sorted(), [], "in the retired ladder but missing from the baseline")
        XCTAssertEqual(actual.count, expected.count)
    }
}
