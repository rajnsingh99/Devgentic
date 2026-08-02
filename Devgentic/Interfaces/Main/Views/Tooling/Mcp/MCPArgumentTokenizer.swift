//
//  MCPArgumentTokenizer.swift
//  Devgentic
//
//  Created 2026-08-01 for P1 #16.
//
//  The Add-Server form keeps arguments as one free-text field but `ServerDefinition.args`
//  is an argv ARRAY, so the two representations have to convert both ways without loss.
//
//  They used to convert with a bare `split(whereSeparator: \.isWhitespace)` one way and a
//  `joined(separator: " ")` the other. Neither honoured quoting, so any argument containing
//  a space — overwhelmingly a path — was silently split into two argv entries. Worse, the
//  two halves round-tripped: pasting a valid JSON config into the JSON tab joined the args
//  with spaces, and saving split them back differently, corrupting a config the user never
//  edited.
//
//  These are pure functions with no UI or I/O so they can be unit-tested directly.
//

import Foundation

enum MCPArgumentTokenizer {

    /// Splits a command-line-ish string into argv entries, honouring single and double
    /// quotes and backslash escapes.
    ///
    /// Deliberately NOT a shell parser: it does not expand `$VAR`, globs, or backticks.
    /// `ShellProcess` execs argv directly with no shell, so expanding anything here would
    /// reintroduce exactly the injection surface that design removes. Quotes are purely a
    /// grouping mechanism for the user.
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
