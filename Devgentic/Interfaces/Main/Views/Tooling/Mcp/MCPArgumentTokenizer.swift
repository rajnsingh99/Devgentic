// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPArgumentTokenizer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Converts between the Add-Server form's free-text arguments and `ServerDefinition.args` (an argv array) without
/// loss, honouring quoting. Pure functions with no UI or I/O.
enum MCPArgumentTokenizer {

    /// Splits a command-line-style string into argv entries, honouring single and double quotes and backslash escapes.
    /// Not a shell parser: it never expands `$VAR`, globs or backticks, because `ShellProcess` execs argv with no
    /// shell.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false          // distinguishes "" (quoted empty) from no token
        var quote: Character? = nil
        var escaped = false

        for character in input {
            if escaped {
                current.append(character)
                hasCurrent = true
                escaped = false
                continue
            }

            // A backslash escapes the next character everywhere except inside single
            // quotes, matching POSIX shell quoting rules closely enough to be unsurprising.
            if character == "\\" && quote != "'" {
                escaped = true
                hasCurrent = true
                continue
            }

            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasCurrent = true
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                hasCurrent = true
                continue
            }

            if character.isWhitespace {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
                continue
            }

            current.append(character)
            hasCurrent = true
        }

        // A trailing backslash is a literal, and an unterminated quote still yields its
        // content — the user is mid-edit, not attacking us. Never drop typed characters.
        if escaped { current.append("\\") ; hasCurrent = true }
        if hasCurrent { tokens.append(current) }

        return tokens
    }

    /// Renders an argv array back into the single-line form, quoting whatever would not
    /// survive `tokenize`. `tokenize(join(args)) == args` for every input.
    static func join(_ arguments: [String]) -> String {
        arguments.map(quoteIfNeeded).joined(separator: " ")
    }

    private static func quoteIfNeeded(_ argument: String) -> String {
        if argument.isEmpty { return "\"\"" }

        let needsQuoting = argument.contains(where: { $0.isWhitespace })
            || argument.contains("\"")
            || argument.contains("'")
            || argument.contains("\\")

        guard needsQuoting else { return argument }

        // Double-quote and escape the characters that are special inside double quotes.
        var escapedValue = ""
        for character in argument {
            if character == "\"" || character == "\\" {
                escapedValue.append("\\")
            }
            escapedValue.append(character)
        }
        return "\"\(escapedValue)\""
    }
}
