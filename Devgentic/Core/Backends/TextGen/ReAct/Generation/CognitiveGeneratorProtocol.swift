//
//  CognitiveGeneratorProtocol.swift
//  Devgentic
//
//  Created by Raj Singh on 26/02/26.
//


import Foundation

// MARK: - Prompt Structural Wrapping

/// Controls how structural sections are wrapped in the prompt.
/// XML for native/Mistral models (they handle XML naturally).
/// Markdown for local models using Markdown or JSON response formats (avoids format conflict).
enum PromptWrapping: Sendable {
    case xml       // <tag>\ncontent\n</tag>
    case markdown  // ## Tag\ncontent

    /// Wraps content in a named structural section.
    func section(_ tag: String, content: String) -> String {
        switch self {
        case .xml:
            return "<\(tag)>\n\(content)\n</\(tag)>"
        case .markdown:
            let heading = tag.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return "## \(heading)\n\(content)"
        }
    }

    /// Wraps a labeled field within a section (e.g. clarification sub-tags).
    func field(_ label: String, value: String) -> String {
        switch self {
        case .xml:
            return "<\(label)>\(value)</\(label)>"
        case .markdown:
            let heading = label.prefix(1).uppercased() + label.dropFirst()
            return "**\(heading):** \(value)"
        }
    }
}

// MARK: - Prompt Layer Configuration

/// Controls which optional layers are included in the unified prompt builder.
/// Agent mode includes all layers; Workflow mode strips RAG, episodic memory, and user profile.
struct PromptLayerConfig: Sendable {
    let includeRAG: Bool
    let includeEpisodicMemory: Bool
    let includeUserProfile: Bool

    static let agent = PromptLayerConfig(includeRAG: true, includeEpisodicMemory: true, includeUserProfile: true)
    static let workflow = PromptLayerConfig(includeRAG: false, includeEpisodicMemory: false, includeUserProfile: false)
    static let bot = PromptLayerConfig(includeRAG: true, includeEpisodicMemory: true, includeUserProfile: false)
    static let code = PromptLayerConfig(includeRAG: false, includeEpisodicMemory: true, includeUserProfile: false)
}

// MARK: - Cognitive Generator Protocol

/// Defines a strategy for generating structured cognitive steps from an LLM.
/// Strategies operate on the SemanticContext payload and compile provider-specific message arrays.
protocol CognitiveGenerator: Sendable {
    /// The adapter responsible for formatting tools for this specific generator.
    var toolAdapter: ToolSchemaAdapter { get }

    /// Dialect-specific formatting rules for the execution contract.
    /// Non-native generators return their rules (XML, Markdown, JSON schemas).
    /// Native generators return nil (tools are sent via API, not embedded in prompt).
    var dialectRules: String? { get }

    /// Compiles the raw execution state into a provider-specific message array.
    func compileMessages(from context: SemanticContext) -> [[String: String]]

    /// Executes the cognitive step and returns a structured response.
    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep

    /// Multimodal message compilation. Default wraps legacy compileMessages().
    func compileProviderMessages(from context: SemanticContext) -> [ProviderMessage]

    /// Returns the dialect-appropriate prompt trigger for the given iteration.
    /// Default returns the universal base. Override to append dialect-specific suffixes.
    func promptTrigger(for iteration: Int) -> String

    /// Structural wrapping style for prompt sections.
    /// XML for native/Mistral models; Markdown for local JSON/Markdown dialects.
    var promptWrapping: PromptWrapping { get }
}

extension CognitiveGenerator {
    /// Default: no dialect rules (native generators).
    var dialectRules: String? { nil }

    /// Default wrapping: XML tags (suitable for frontier models and XML dialect).
    var promptWrapping: PromptWrapping { .xml }

    func compileProviderMessages(from context: SemanticContext) -> [ProviderMessage] {
        compileMessages(from: context).map { ProviderMessage(legacy: $0) }
    }

    /// Default trigger: clean universal base used by XML & Markdown generators.
    /// Generators needing dialect-specific suffixes (Native, JSON, MLX) override this.
    func promptTrigger(for iteration: Int) -> String {
        iteration == 1
            ? "Analyze the task and working memory, then decide your next action."
            : "New observations have been recorded in working memory. Decide your next action."
    }
}

// MARK: - Unified Prompt Builder

/// Standalone prompt builder shared by all execution modes (Agent, Workflow, Bot).
/// Extracted from the CognitiveGenerator protocol extension so that ChatExecutor
/// (which is an Executor, not a CognitiveGenerator) can also call it.
enum PromptBuilder {

    /// Constructs the unified prompt with attention-optimized layer ordering.
    ///
    /// Layer order (system message): WHAT → HOW → WHO → CONTEXT → CAPABILITIES → GUARDRAILS
    /// Optimized for small-model primacy/recency attention patterns. Critical layers (task, format rules)
    /// sit at peak primacy; working memory sits at peak recency in the user message.
    ///
    /// - Parameters:
    ///   - context: The semantic context with all execution state.
    ///   - dialectRules: Format contract for non-native generators (nil for native API flows).
    ///   - isNativeFlow: True when tools are sent via API (Claude, GPT, Gemini).
    ///   - layerConfig: Controls which optional layers are included (`.agent`, `.workflow`, `.bot`).
    ///   - userMessagePrefix: Optional prefix for the user message (workflow `<input>` block, bot query, etc.).
    static func buildStandardMessages(
        context: SemanticContext,
        dialectRules: String? = nil,
        isNativeFlow: Bool = false,
        layerConfig: PromptLayerConfig = .agent,
        userMessagePrefix: String? = nil,
        wrapping: PromptWrapping = .xml,
        includeWorkingMemory: Bool = true,
        includeAttachmentContext: Bool = true
    ) -> [[String: String]] {

        // =====================================================================
        // SYSTEM MESSAGE — Attention-Optimized Layer Order
        // =====================================================================

        var systemContent = ""

        // Layer 1: WHAT — Task (peak primacy)
        let task = context.taskDescription ?? context.originalQuery
        systemContent += wrapping.section("task", content: task)

        // Layer 2: WHAT — Clarification (task refinement from ask_user)
        if let clarification = context.latestClarification {
            let body = wrapping.field("query", value: clarification.query) + "\n" + wrapping.field("response", value: clarification.response)
            systemContent += "\n\n" + wrapping.section("clarification", content: body)
        }

        // Layer 3: HOW — Execution contract + tool definitions (non-native only)
        if !isNativeFlow, let rules = dialectRules {
            let toolsMarkdown = context.availableTools.map { $0.toMarkdownDefinition() }.joined(separator: "\n\n")
            systemContent += "\n\n" + wrapping.section("execution_contract", content: rules)
            systemContent += "\n\n" + wrapping.section("available_tools", content: toolsMarkdown)
        }

        // Layer 4: WHO — System instructions (user persona)
        systemContent += "\n\n" + wrapping.section("system_instructions", content: context.instructions ?? "You are a helpful AI assistant.")

        // Layer 5: CONTEXT — Environment facts (always full)
        // Home is rendered as an absolute path (never tilde): small models copy
        // paths verbatim from context, and a literal "/Users/<name>" anchor is what
        // stops them emitting training-data placeholders like "/path/to/X".
        let envContent = """
        - OS: \(context.environmentFacts.osVersion)
        - Shell: \(context.environmentFacts.shellType)
        - User: \(context.environmentFacts.userName)
        - Home: \(context.environmentFacts.homeDirectory)
        - Date: \(context.environmentFacts.currentDate)
        - Paths: use absolute paths; user folders are under \(context.environmentFacts.homeDirectory) (Desktop, Documents, Downloads)
        """
        systemContent += "\n\n" + wrapping.section("environment", content: envContent)

        // Layer 5.5: CONTEXT — Profile knowledge base (static reference material).
        // Payload is strategy-shaped upstream: extracted content (directInjection)
        // or a read_file path manifest (stateless). Byte-stable per profile so the
        // system prefix stays prompt-cache / KV-cache friendly.
        if let knowledgeBase = context.knowledgeBaseContext, !knowledgeBase.isEmpty {
            systemContent += "\n\n" + wrapping.section("knowledge_base", content: knowledgeBase)
        }

        // Layer 6: CONTEXT — RAG grounding (configurable)
        if layerConfig.includeRAG {
            let grounding = context.longTermMemory.getStaticGrounding()
            if !grounding.isEmpty {
                systemContent += "\n\n" + wrapping.section("semantic_context", content: grounding)
            }
        }

        // Layer 7: CONTEXT — Episodic memory (embedded in system prompt for all flows).
        //
        // Hybrid history strategy: episodic XML lives in the system prompt so the
        // model treats it as developer-supplied context, not as prior assistant
        // output to mimic. Native flows also get prose-only user/assistant turn
        // pairs appended below — those carry natural chat flow, while the XML
        // here carries tool-execution context. Keeping the two channels separate
        // prevents the "[Used: tool(...) → result]" mimicry loop we saw when
        // tool summaries were baked into assistant turns.
        if layerConfig.includeEpisodicMemory {
            if let history = context.recentHistory, !history.isEmpty {
                systemContent += "\n\n\(history)"
            }
        }

        // Layer 8: CONTEXT — User personal profile (configurable)
        if layerConfig.includeUserProfile {
            if let profile = context.userProfile, !profile.isEmpty {
                systemContent += "\n\n" + wrapping.section("user_profile", content: profile)
            }
        }

        // Layer 9: CAPABILITIES — Skill discovery
        if let skills = context.skillManifests, !skills.isEmpty {
            let skillBody = "You have access to specialized skills. When a task matches a skill's description,\nuse the `load_skill` tool to load its full instructions before proceeding.\n" + skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
            systemContent += "\n\n" + wrapping.section("available_skills", content: skillBody)
        }

        // Layer 10-11: GUARDRAILS — Negative constraints + hallucinated tools
        if !context.negativeConstraints.isEmpty {
            let body = "FAILED PATHS:\n" + context.negativeConstraints.map { "- \($0)" }.joined(separator: "\n")
            systemContent += "\n\n" + wrapping.section("negative_constraints", content: body)
        }
        if !context.hallucinatedTools.isEmpty {
            let body = "DO NOT USE:\n" + context.hallucinatedTools.map { "- \($0)" }.joined(separator: "\n")
            systemContent += "\n\n" + wrapping.section("hallucinated_tools", content: body)
        }

        // =====================================================================
        // MESSAGE ARRAY
        // =====================================================================

        var messages: [[String: String]] = [["role": "system", "content": systemContent]]

        // History messages: prose-only user/assistant turn pairs carry conversation
        // flow for native providers. Tool-execution context is already embedded in
        // the system prompt's episodic XML above — these turns no longer contain
        // `[Used: tool(...) → result]` summaries.
        if layerConfig.includeEpisodicMemory {
            if let turns = context.nativeHistoryTurns, !turns.isEmpty {
                messages.append(contentsOf: turns)
            }
        }

        // User message: optional prefix (workflow <input>, bot query) + working memory.
        // The native-turn path (G12) passes `includeWorkingMemory: false` so the
        // scratchpad isn't re-injected every iteration — observations flow instead
        // through `assistant(tool_calls) → tool(result)` turns managed by the executor.
        //
        // Prefix resolution: explicit `userMessagePrefix` argument wins; otherwise,
        // if the context carries a `workflowContext`, derive the per-node prefix
        // from it using this call's own `wrapping`. This is what lets every
        // generator inherit workflow behavior for free — no per-generator code.
        var userContent = ""

        // Current-turn attachments lead the user message (file text or stateless
        // path note), ahead of the query/prefix — mirroring how a person pastes a
        // file then asks about it. The native-turn executor passes
        // `includeAttachmentContext: false` and composes them into its kickoff
        // turn instead (same rationale as `includeWorkingMemory`).
        if includeAttachmentContext, let attachments = context.attachmentContext, !attachments.isEmpty {
            userContent += attachments
        }

        let resolvedPrefix: String? = {
            if let explicit = userMessagePrefix { return explicit }
            if let wf = context.workflowContext { return wf.userMessagePrefix(wrapping: wrapping) }
            return nil
        }()
        if let prefix = resolvedPrefix {
            if !userContent.isEmpty { userContent += "\n\n" }
            userContent += prefix
        }

        if includeWorkingMemory {
            let scratchpad = context.compiledScratchpad
            if !scratchpad.isEmpty && scratchpad != "No actions taken yet." {
                if !userContent.isEmpty { userContent += "\n\n" }
                userContent += wrapping.section("working_memory", content: scratchpad)
            }
        }

        if !userContent.isEmpty {
            messages.append(["role": "user", "content": userContent])
        }

        return messages
    }
}

// MARK: - CognitiveGenerator Convenience Wrapper

extension CognitiveGenerator {

    /// Convenience wrapper — delegates to `PromptBuilder.buildStandardMessages()`.
    /// Allows generators to call `self.buildStandardMessages(...)` as before.
    func buildStandardMessages(
        context: SemanticContext,
        dialectRules: String? = nil,
        isNativeFlow: Bool = false,
        layerConfig: PromptLayerConfig = .agent,
        userMessagePrefix: String? = nil,
        wrapping: PromptWrapping = .xml,
        includeWorkingMemory: Bool = true,
        includeAttachmentContext: Bool = true
    ) -> [[String: String]] {
        PromptBuilder.buildStandardMessages(
            context: context,
            dialectRules: dialectRules,
            isNativeFlow: isNativeFlow,
            layerConfig: layerConfig,
            userMessagePrefix: userMessagePrefix,
            wrapping: wrapping,
            includeWorkingMemory: includeWorkingMemory,
            includeAttachmentContext: includeAttachmentContext
        )
    }
}
