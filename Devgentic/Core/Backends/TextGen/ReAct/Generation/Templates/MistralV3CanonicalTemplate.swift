// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MistralV3CanonicalTemplate.swift
//  Devgentic
//
//  POC (2026-04-24) — bundled canonical Mistral v3 Tekken chat template with a
//  `{% if tools %}` rendering branch. Used to rescue MLX community quantizations of
//  Mistral-Nemo / Mistral-7B-v0.3 / Mixtral / Ministral / Pixtral which ship STRIPPED
//  chat templates (only `[INST]...[/INST]` alternation, no tool scaffolding).
//
//  Wired via `ChatTemplateSource.override(...)` and consumed in `MLXService.streamChat`
//  as a preempt of the tokenizer's embedded template.
//
//  IMPORTANT (POC scope):
//  - Simplified from the upstream Mistral v3 template — does NOT implement assistant
//    `tool_calls` rendering or the strict 9-char tool_call.id validation. The current
//    executor flow appends tool observations into scratchpad user content, not as
//    separate assistant(tool_calls) / tool(result) turns, so those branches aren't
//    needed yet. If we migrate to native tool turns for Mistral (G12-style), extend
//    this template with the tool_calls / tool_results branches from upstream.
//  - Still enforces strict user/assistant alternation — callers must merge
//    consecutive same-role turns before rendering. See
//    `NativeToolTemplateGenerator.mergeConsecutiveSameRole` for the guard.
//

import Foundation

enum MistralV3CanonicalTemplate {

    /// Canonical Jinja source for Mistral v3 Tekken family with tool support.
    ///
    /// Renders:
    /// - `[AVAILABLE_TOOLS] [...schemas...] [/AVAILABLE_TOOLS]` before the last user turn when `tools` is passed.
    /// - `[INST] ...[/INST]` wrapper for each user message, with system message folded into the last user turn.
    /// - `" " + content + eos_token` for assistant turns.
    /// - `[TOOL_RESULTS] ... [/TOOL_RESULTS]` for `role: "tool"` turns.
    ///
    /// Safe to use across Mistral v3 Tekken family (v0.3, Nemo, Mixtral 8x22B, Ministral 8B, Pixtral Large).
    static let jinja: String = """
    {%- if messages[0]["role"] == "system" %}
        {%- set system_message = messages[0]["content"] %}
        {%- set loop_messages = messages[1:] %}
    {%- else %}
        {%- set loop_messages = messages %}
    {%- endif %}
    {%- if not tools is defined %}
        {%- set tools = none %}
    {%- endif %}
    {{- bos_token }}
    {%- set user_messages = loop_messages | selectattr("role", "equalto", "user") | list %}
    {%- for message in loop_messages %}
        {%- if message["role"] == "user" %}
            {%- if tools is not none and (message == user_messages[-1]) %}
                {{- "[AVAILABLE_TOOLS] " + tools|tojson + "[/AVAILABLE_TOOLS]" }}
            {%- endif %}
            {%- if loop.last and system_message is defined %}
                {{- "[INST] " + system_message + "\\n\\n" + message["content"] + "[/INST]" }}
            {%- else %}
                {{- "[INST] " + message["content"] + "[/INST]" }}
            {%- endif %}
        {%- elif message["role"] == "assistant" %}
            {{- " " + message["content"] + eos_token }}
        {%- elif message["role"] == "tool" %}
            {{- "[TOOL_RESULTS] " + message["content"] + "[/TOOL_RESULTS]" }}
        {%- endif %}
    {%- endfor %}
    """
}
