// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MistralV3CanonicalTemplate.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Bundled Mistral v3 Tekken chat template with a `{% if tools %}` branch, for stripped quantization templates.
/// Applied via `ChatTemplateSource.override(...)` in `MLXService.streamChat`; it does not render assistant `tool_calls`.
/// Strict user/assistant alternation: callers merge consecutive same-role turns first (`mergeConsecutiveSameRole`).
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
