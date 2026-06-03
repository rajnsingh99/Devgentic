//
//  AgentErrorCategory.swift
//  Devgentic
//
//  Canonical error taxonomy for structured telemetry.
//
//  The agent pipeline has ~80 distinct failure/warning sites spread across parsing,
//  LLM providers, tool execution, circuit-breaker safety, capabilities, memory, and
//  workflow orchestration. Before this type, each layer had its own category enum
//  (WarningCategory, ToolFailureCategory) and many failures had no classification
//  at all — just stringified messages. That made deduplication, aggregation, and
//  post-hoc bug analysis impossible.
//
//  `AgentErrorCategory` is a single flat enum covering every classifiable failure
//  point in the pipeline. A SpanEvent's `error_category` column stores its rawValue
//  so analytics can `GROUP BY` without parsing JSON. The enum is stable — adding a
//  case never removes one, and mapping extensions from the legacy enums keep existing
//  code compiling.
//
//  Design principles:
//  - FLAT. No nested enums. Makes SQLite GROUP BY trivial.
//  - NAMED BY MACHINE. `providerRateLimit` not `rate_limit_429`. Human-readable UI
//    labels come from `displayName`; the rawValue is for storage + querying.
//  - SHORT PREFIXES. `cb` = circuit breaker, `wf` = workflow, `mem` = memory.
//    Prevents noisy long names while remaining unambiguous.
//  - EXTENSIBLE. Adding a new case + updating the four property switches is all it
//    takes to onboard a new failure mode.
//

import Foundation
import GRDB

// MARK: - Severity

/// Coarse severity bucket for telemetry aggregation and UI tinting.
enum ErrorSeverity: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Warning-level signal; system is recovering or will retry. No user action needed.
    case informational
    /// Error occurred but execution continues (fallback, retry, alternative path).
    case recoverable
    /// Error that terminates the current execution branch.
    case fatal
}

// MARK: - Execution Phase

/// The coarse phase of agent execution where a failure originates.
/// Groups the 46 error categories into 7 buckets for dashboard aggregation.
enum ExecutionPhase: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case parsing      // model output → structured step (all parser stages)
    case llm          // provider call (rate limit, timeout, auth, etc.)
    case tooling      // tool dispatch / execution / circuit breaker
    case capability   // planning, self-reflection, delegation
    case memory       // working memory, scratchpad, context budget
    case workflow     // DAG orchestration, per-node failures
    case session      // lifecycle: cancellation, suspension, model unload
}

// MARK: - Agent Error Category

/// Canonical failure classification across the entire agent pipeline.
///
/// Each case represents a distinct, analyzable failure mode. The rawValue is the
/// stable storage key; `displayName` is the human-readable label for UI.
///
/// When adding a new case, also update:
/// - `severity` (which bucket: informational / recoverable / fatal)
/// - `phase` (which execution phase it belongs to)
/// - `isRetryable` (can the agent automatically retry?)
/// - `displayName` (human-readable label)
enum AgentErrorCategory: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {

    // MARK: Parsing (6)
    case parseJsonMalformed         // structured decode failed; output isn't valid JSON
    case parseJsonEmpty             // no JSON/tool calls extracted from response
    case parseFormatDrift           // dialect mismatch — model emitted format A, parser expected B
    case parseHeuristicFallback     // primary parser failed; heuristic recovery succeeded
    case parseExhausted             // all parser stages failed; no structured step produced
    case parseStageTransition       // primary→fallback→heuristic transition happened (informational)

    // MARK: Provider / LLM layer (7)
    case providerRateLimit          // HTTP 429 or equivalent throttle signal
    case providerTimeout            // connection/read/request timeout
    case providerAuth               // 401/403 — invalid key or insufficient permissions
    case providerServerError        // 5xx from provider
    case providerStreamError        // error mid-stream (partial response received)
    case providerModelNotFound      // requested model doesn't exist / unavailable
    case providerCapabilityMissing  // model can't do something requested (e.g., extended thinking)

    // MARK: Tool execution (8) — aligned with ToolFailureCategory
    case toolNotFound               // hallucinated tool name not in registry
    case toolArgMissing             // required argument not provided
    case toolArgInvalid             // argument validation failed (empty string, wrong type)
    case toolPermissionDenied       // OS-level permission missing (macOS privacy)
    case toolTimeout                // per-tool timeout deadline exceeded
    case toolSemanticFail           // tool ran but returned error-shaped output
    case toolSystemCrash            // tool's run closure threw an unhandled exception
    case toolUserDenied             // HITL: user explicitly rejected the call

    // MARK: Circuit breaker (5)
    case cbRepetitiveAction         // same (tool, args, output) fingerprint N times → abort
    case cbConsecutiveFail          // consecutive tool failures exceeded limit
    case cbToolRetryLimit           // same tool+args retried too many times
    case cbIdleLimit                // max idle steps without progress
    case cbAskUserLimit             // too many consecutive ask_user calls

    // MARK: Capability (6)
    case planGenFailed              // plan decomposition LLM call threw
    case planUserRejected           // HITL plan review — user rejected
    case subtaskFailed              // subtask inside a plan failed (soft — plan continues)
    case reflectionEvalFailed       // reflection evaluator LLM call threw
    case reflectionTrialRejected    // evaluator rejected a trial (reflexion retries)
    case reflectionExhausted        // all reflection trials rejected

    // MARK: Memory (4)
    case memObsTruncated            // single observation exceeded per-entry cap
    case memPressureWarn            // working-memory utilization > 75%
    case memExhausted               // utilization >= 100%; eviction triggered
    case memEviction                // entries dropped to fit budget

    // MARK: Workflow (8)
    case wfDepthExceeded            // workflow nesting depth past hard limit
    case wfEmpty                    // workflow has no nodes
    case wfCycle                    // DAG validation detected a cycle
    case wfValidationFailed         // pre-flight configuration validation failed
    case wfProfileNotFound          // node's referenced profile is missing
    case wfNodeSkipped              // node skipped because an upstream dependency failed
    case wfNodeFailed               // per-node inner agent/bot execution failed (post-synthesizer demotion)
    case wfClassifierFailed         // AI Classifier LLM call or response parsing failed

    // MARK: Session / lifecycle (4)
    case userCancelled              // user stopped the run
    case suspensionTimeout          // HITL operation (ask_user / plan review) timed out
    case suspensionServiceError     // ExecutionSuspensionService internal failure
    case modelUnloaded              // local model (MLX / Ollama) evicted mid-execution

    // MARK: Resource / data-loading (9)
    case executionFailed            // generic/unclassified terminal error (default for legacy string errors)
    case fileNotFound               // attached/upstream file does not exist at its path
    case fileAccessDenied           // OS / security-scoped access denied
    case fileReadFailed             // I/O read error (disk, transient)
    case fileTooLarge               // file exceeds the inlining size budget
    case documentExtractionFailed   // PDF/DOCX/XLSX/… extraction threw
    case documentPasswordProtected  // document is encrypted/password-protected
    case documentCorrupted          // document is malformed/corrupted
    case imageResolutionFailed      // MediaReference.resolve() failed for an image payload

    // MARK: - Derived properties

    var severity: ErrorSeverity {
        switch self {
        // Informational: agent is handling it, no user action needed
        case .parseHeuristicFallback, .parseStageTransition,
             .memObsTruncated, .memPressureWarn, .memEviction,
             .cbRepetitiveAction,          // N-1 warning, not the abort itself
             .wfNodeSkipped,
             .providerRateLimit, .providerStreamError,
             .reflectionTrialRejected, .planUserRejected:
            return .informational

        // Recoverable: error occurred, agent continues
        case .parseJsonMalformed, .parseJsonEmpty, .parseFormatDrift,
             .providerTimeout,
             .toolNotFound, .toolArgMissing, .toolArgInvalid, .toolPermissionDenied,
             .toolTimeout, .toolSemanticFail, .toolSystemCrash, .toolUserDenied,
             .cbToolRetryLimit, .cbAskUserLimit,
             .subtaskFailed, .reflectionEvalFailed,
             .memExhausted,
             .suspensionTimeout, .modelUnloaded,
             // Resource/data-loading: never silent, but recoverable — chat degrades,
             // workflow fails just the node (not the whole app).
             .fileNotFound, .fileAccessDenied, .fileReadFailed, .fileTooLarge,
             .documentExtractionFailed, .documentPasswordProtected, .documentCorrupted,
             .imageResolutionFailed:
            return .recoverable

        // Fatal: execution terminates
        case .parseExhausted,
             .providerAuth, .providerServerError, .providerModelNotFound, .providerCapabilityMissing,
             .cbConsecutiveFail, .cbIdleLimit,
             .planGenFailed, .reflectionExhausted,
             .wfDepthExceeded, .wfEmpty, .wfCycle, .wfValidationFailed, .wfProfileNotFound,
             .wfNodeFailed, .wfClassifierFailed,
             .userCancelled, .suspensionServiceError,
             .executionFailed:   // generic terminal error (legacy string-error default)
            return .fatal
        }
    }

    var phase: ExecutionPhase {
        switch self {
        case .parseJsonMalformed, .parseJsonEmpty, .parseFormatDrift,
             .parseHeuristicFallback, .parseExhausted, .parseStageTransition:
            return .parsing

        case .providerRateLimit, .providerTimeout, .providerAuth,
             .providerServerError, .providerStreamError,
             .providerModelNotFound, .providerCapabilityMissing:
            return .llm

        case .toolNotFound, .toolArgMissing, .toolArgInvalid, .toolPermissionDenied,
             .toolTimeout, .toolSemanticFail, .toolSystemCrash, .toolUserDenied,
             .cbRepetitiveAction, .cbConsecutiveFail, .cbToolRetryLimit,
             .cbIdleLimit, .cbAskUserLimit,
             // Resource/data-loading happens during tool/context preparation —
             // bucketed under .tooling (no dedicated phase to avoid ExecutionPhase ripple).
             .fileNotFound, .fileAccessDenied, .fileReadFailed, .fileTooLarge,
             .documentExtractionFailed, .documentPasswordProtected, .documentCorrupted,
             .imageResolutionFailed:
            return .tooling

        case .planGenFailed, .planUserRejected, .subtaskFailed,
             .reflectionEvalFailed, .reflectionTrialRejected, .reflectionExhausted:
            return .capability

        case .memObsTruncated, .memPressureWarn, .memExhausted, .memEviction:
            return .memory

        case .wfDepthExceeded, .wfEmpty, .wfCycle, .wfValidationFailed,
             .wfProfileNotFound, .wfNodeSkipped, .wfNodeFailed, .wfClassifierFailed:
            return .workflow

        case .userCancelled, .suspensionTimeout, .suspensionServiceError, .modelUnloaded,
             .executionFailed:   // generic/unclassified terminal error (least-wrong bucket)
            return .session
        }
    }

    /// Whether the agent (or a retry strategy) can reasonably retry this operation
    /// without user intervention. Used by analytics to separate "bad call" errors
    /// (user/config fixable) from "transient" errors (auto-recoverable).
    var isRetryable: Bool {
        switch self {
        case .parseJsonMalformed, .parseJsonEmpty, .parseFormatDrift,
             .parseHeuristicFallback, .parseStageTransition,
             .providerRateLimit, .providerTimeout, .providerServerError, .providerStreamError,
             .toolTimeout, .toolSemanticFail,
             .memObsTruncated, .memPressureWarn, .memExhausted, .memEviction,
             .modelUnloaded, .reflectionTrialRejected,
             .wfNodeFailed,                          // per-node retry via maxNodeRetries
             .fileReadFailed, .imageResolutionFailed: // transient I/O — a retry may succeed
            return true
        default:
            return false
        }
    }

    /// Human-readable label for dashboard UI. rawValue is for storage/queries;
    /// displayName is what a developer sees in the Report Inspector.
    var displayName: String {
        switch self {
        case .parseJsonMalformed:        return "Malformed JSON"
        case .parseJsonEmpty:            return "Empty JSON"
        case .parseFormatDrift:          return "Format Drift"
        case .parseHeuristicFallback:    return "Heuristic Fallback"
        case .parseExhausted:            return "Parse Exhausted"
        case .parseStageTransition:      return "Parser Stage Switch"

        case .providerRateLimit:         return "Rate Limited"
        case .providerTimeout:           return "Provider Timeout"
        case .providerAuth:              return "Auth Failure"
        case .providerServerError:       return "Provider 5xx"
        case .providerStreamError:       return "Stream Error"
        case .providerModelNotFound:     return "Model Not Found"
        case .providerCapabilityMissing: return "Capability Missing"

        case .toolNotFound:              return "Tool Not Found"
        case .toolArgMissing:            return "Missing Arg"
        case .toolArgInvalid:            return "Invalid Arg"
        case .toolPermissionDenied:      return "Permission Denied"
        case .toolTimeout:               return "Tool Timeout"
        case .toolSemanticFail:          return "Tool Semantic Fail"
        case .toolSystemCrash:           return "Tool Crash"
        case .toolUserDenied:            return "User Denied"

        case .cbRepetitiveAction:        return "Repetitive Action"
        case .cbConsecutiveFail:         return "Consecutive Failures"
        case .cbToolRetryLimit:          return "Tool Retry Limit"
        case .cbIdleLimit:               return "Idle Limit"
        case .cbAskUserLimit:            return "Ask-User Limit"

        case .planGenFailed:             return "Plan Generation Failed"
        case .planUserRejected:          return "Plan Rejected"
        case .subtaskFailed:             return "Subtask Failed"
        case .reflectionEvalFailed:      return "Reflection Eval Failed"
        case .reflectionTrialRejected:   return "Trial Rejected"
        case .reflectionExhausted:       return "Trials Exhausted"

        case .memObsTruncated:           return "Observation Truncated"
        case .memPressureWarn:           return "Memory Pressure"
        case .memExhausted:              return "Memory Exhausted"
        case .memEviction:               return "Memory Eviction"

        case .wfDepthExceeded:           return "Workflow Depth Exceeded"
        case .wfEmpty:                   return "Empty Workflow"
        case .wfCycle:                   return "Workflow Cycle"
        case .wfValidationFailed:        return "Workflow Invalid"
        case .wfProfileNotFound:         return "Profile Not Found"
        case .wfNodeSkipped:             return "Node Skipped"
        case .wfNodeFailed:              return "Node Failed"
        case .wfClassifierFailed:        return "Classifier Failed"

        case .userCancelled:             return "User Cancelled"
        case .suspensionTimeout:         return "HITL Timeout"
        case .suspensionServiceError:    return "Suspension Error"
        case .modelUnloaded:             return "Model Unloaded"

        case .executionFailed:           return "Execution Failed"
        case .fileNotFound:              return "File Not Found"
        case .fileAccessDenied:          return "File Access Denied"
        case .fileReadFailed:            return "File Read Failed"
        case .fileTooLarge:              return "File Too Large"
        case .documentExtractionFailed:  return "Document Extraction Failed"
        case .documentPasswordProtected: return "Document Password-Protected"
        case .documentCorrupted:         return "Document Corrupted"
        case .imageResolutionFailed:     return "Image Read Failed"
        }
    }
}

// MARK: - Mapping from existing enums

/// `WarningCategory` → `AgentErrorCategory`. Mappings are approximate — the existing
/// enum was designed for UI affordance, not analytics, so the canonical cases are
/// often more specific. When a new warning site lands, emit the canonical category
/// directly rather than going through `WarningCategory` first.
extension WarningCategory {
    var agentErrorCategory: AgentErrorCategory {
        switch self {
        case .retry:            return .providerStreamError    // closest transient-retry analog
        case .throttle:         return .providerRateLimit
        case .memoryPressure:   return .memPressureWarn
        case .parseFailure:     return .parseJsonMalformed     // most common parse failure
        case .formatCorrection: return .parseFormatDrift
        case .contextPressure:  return .memExhausted
        case .circuitBreaker:   return .cbRepetitiveAction     // most common CB trigger
        case .resourceUnavailable: return .fileReadFailed      // attachment/file couldn't be read
        }
    }
}

/// `ToolFailureCategory` → `AgentErrorCategory`. 1:1 semantic mapping.
extension ToolFailureCategory {
    var agentErrorCategory: AgentErrorCategory {
        switch self {
        case .userDenied:         return .toolUserDenied
        case .permissionRejected: return .toolPermissionDenied
        case .executionThrew:     return .toolSystemCrash
        case .timeout:            return .toolTimeout
        case .invalidArgs:        return .toolArgInvalid
        case .notFound:           return .toolNotFound
        case .cancelled:          return .toolUserDenied      // semantic overlap — user skipped ask_user
        }
    }
}
