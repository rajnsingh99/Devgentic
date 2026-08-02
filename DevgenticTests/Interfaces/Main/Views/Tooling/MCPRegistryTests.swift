//
//  MCPRegistryTests.swift
//  DevgenticTests
//
//  Gap 7 (Discover), 2026-08-01. The fixture below is REAL captured output from
//  https://registry.modelcontextprotocol.io/v0/servers — not a hand-written approximation,
//  so a schema drift that would empty the Discover list fails here first.
//

import XCTest
@testable import devgentic

final class MCPRegistryTests: XCTestCase {

    // MARK: - Fixture (captured 2026-08-01)

    private let realResponse = """
    {
      "servers": [
        {
          "server": {
            "name": "io.github.example/remote-filesystem",
            "title": "Remote Filesystem",
            "description": "Access files stored in Google Cloud Storage.",
            "version": "0.1.2",
            "packages": [{
              "registryType": "npm",
              "registryBaseUrl": "https://registry.npmjs.org",
              "identifier": "remote-filesystem-mcp-server",
              "version": "0.1.2",
              "runtimeHint": "npx",
              "transport": {"type": "stdio"},
              "runtimeArguments": [{"value": "-y", "type": "positional"}],
              "environmentVariables": [
                {"description": "Google Cloud Storage bucket name.", "isRequired": true, "name": "GCS_BUCKET"},
                {"description": "Google Cloud project ID.", "name": "GCS_PROJECT_ID"}
              ]
            }]
          },
          "_meta": {"io.modelcontextprotocol.registry/official": {"status": "active"}}
        },
        {
          "server": {
            "name": "ac.inference.sh/mcp",
            "title": "inference.sh",
            "description": "run any ai model.",
            "version": "2.0.0",
            "remotes": [{"type": "streamable-http", "url": "https://api.inference.sh/mcp"}]
          },
          "_meta": {}
        },
        {
          "server": {
            "name": "io.github.example/docs-only",
            "description": "Metadata-only entry with nothing to connect to.",
            "version": "1.0.0"
          },
          "_meta": {}
        }
      ],
      "metadata": {"nextCursor": "io.github.j0hanz/filesystem-mcp:1.1.0", "count": 3}
    }
    """

    private func decodeFixture() throws -> MCPRegistryResponse {
        try JSONDecoder().decode(MCPRegistryResponse.self, from: Data(realResponse.utf8))
    }

    // MARK: - Envelope

    func testDecode_RealEnvelope_ParsesServersAndCursor() throws {
        let response = try decodeFixture()
        XCTAssertEqual(response.servers.count, 3)
        XCTAssertEqual(response.metadata?.nextCursor, "io.github.j0hanz/filesystem-mcp:1.1.0")
        XCTAssertEqual(response.metadata?.count, 3)
    }

    func testDecode_PackageFields_MatchTheLiveSchema() throws {
        let server = try decodeFixture().servers[0].server
        let package = try XCTUnwrap(server.primaryPackage)

        XCTAssertEqual(package.registryType, "npm")
        XCTAssertEqual(package.identifier, "remote-filesystem-mcp-server")
        XCTAssertEqual(package.version, "0.1.2")
        XCTAssertEqual(package.runtimeHint, "npx")
        XCTAssertEqual(package.runtimeArguments.first?.value, "-y")
        XCTAssertEqual(package.environmentVariables.count, 2)
    }

    /// `isRequired` and `isSecret` are the reason a registry-prefilled form beats typing a
    /// command by hand — they drive validation and masking.
    func testDecode_EnvironmentVariableFlags() throws {
        let package = try XCTUnwrap(decodeFixture().servers[0].server.primaryPackage)
        let bucket = try XCTUnwrap(package.environmentVariables.first { $0.name == "GCS_BUCKET" })
        let project = try XCTUnwrap(package.environmentVariables.first { $0.name == "GCS_PROJECT_ID" })

        XCTAssertTrue(bucket.isRequired)
        XCTAssertFalse(project.isRequired, "Absent isRequired must mean optional, not required")
        XCTAssertEqual(bucket.description, "Google Cloud Storage bucket name.")
    }

    // MARK: - Local vs remote classification

    func testClassification_LocalRemoteAndUnconnectable() throws {
        let servers = try decodeFixture().servers.map(\.server)

        XCTAssertTrue(servers[0].isLocal)
        XCTAssertFalse(servers[0].isRemote)

        XCTAssertTrue(servers[1].isRemote)
        XCTAssertFalse(servers[1].isLocal)

        // Nothing to connect to — must be filtered out of the browse list rather than shown
        // as a row whose only outcome is failure.
        XCTAssertFalse(servers[2].isConnectable)
    }

    func testDisplayName_FallsBackWhenTitleAbsent() throws {
        let servers = try decodeFixture().servers.map(\.server)
        XCTAssertEqual(servers[0].displayName, "Remote Filesystem")
        XCTAssertEqual(servers[2].displayName, "Docs Only", "Derived from the name's last path component")
        XCTAssertEqual(servers[0].publisher, "io.github.example")
    }

    // MARK: - Version pinning

    /// The supply-chain point: `npx -y pkg` re-resolves "latest" on every launch, so an
    /// unpinned spec means the reviewed code is not necessarily the code that runs later.
    func testPinnedIdentifier_PerRegistryType() throws {
        func package(_ type: String, _ version: String?) throws -> MCPRegistryPackage {
            let versionJSON = version.map { ",\"version\":\"\($0)\"" } ?? ""
            let json = "{\"registryType\":\"\(type)\",\"identifier\":\"pkg\"\(versionJSON)}"
            return try JSONDecoder().decode(MCPRegistryPackage.self, from: Data(json.utf8))
        }

        XCTAssertEqual(try package("npm", "1.2.3").pinnedIdentifier, "pkg@1.2.3")
        XCTAssertEqual(try package("pypi", "1.2.3").pinnedIdentifier, "pkg==1.2.3")
        XCTAssertEqual(try package("oci", "1.2.3").pinnedIdentifier, "pkg:1.2.3")
        XCTAssertEqual(try package("npm", nil).pinnedIdentifier, "pkg", "No version means no pin, not a broken spec")
    }

    func testEffectiveRuntime_FallsBackFromRegistryType() throws {
        func runtime(type: String, hint: String?) throws -> String {
            let hintJSON = hint.map { ",\"runtimeHint\":\"\($0)\"" } ?? ""
            let json = "{\"registryType\":\"\(type)\",\"identifier\":\"pkg\"\(hintJSON)}"
            return try JSONDecoder().decode(MCPRegistryPackage.self, from: Data(json.utf8)).effectiveRuntime
        }

        XCTAssertEqual(try runtime(type: "npm", hint: nil), "npx")
        XCTAssertEqual(try runtime(type: "pypi", hint: nil), "uvx")
        XCTAssertEqual(try runtime(type: "oci", hint: nil), "docker")
        XCTAssertEqual(try runtime(type: "npm", hint: "bunx"), "bunx", "An explicit hint wins")
        XCTAssertEqual(try runtime(type: "unknown", hint: nil), "", "Unknown must be empty, not guessed")
    }

    // MARK: - Install plan

    @MainActor
    func testPlan_LocalEntry_BuildsPinnedCommand() throws {
        let server = try decodeFixture().servers[0].server
        let plan = MCPRegistryInstallPlan.make(for: server)

        guard case .local(let runtime, let command, let arguments) = plan.kind else {
            return XCTFail("Expected a local plan")
        }
        XCTAssertEqual(runtime, "npx")
        XCTAssertEqual(command, "npx")
        XCTAssertEqual(arguments, ["-y", "remote-filesystem-mcp-server@0.1.2"])
        XCTAssertTrue(plan.displayCommand.contains("@0.1.2"), "The reviewed command must show the pin")
    }

    /// npx prompts on stdin without `-y` — which deadlocks a stdio handshake rather than
    /// asking anyone anything.
    @MainActor
    func testPlan_NpxWithoutYesFlag_GetsOneInserted() throws {
        let json = """
        {"name":"x/y","description":"d","packages":[{"registryType":"npm","identifier":"pkg","version":"1.0.0","runtimeHint":"npx"}]}
        """
        let server = try JSONDecoder().decode(MCPRegistryServer.self, from: Data(json.utf8))
        let plan = MCPRegistryInstallPlan.make(for: server)

        guard case .local(_, _, let arguments) = plan.kind else { return XCTFail("Expected local") }
        XCTAssertEqual(arguments.first, "-y")
        XCTAssertEqual(arguments, ["-y", "pkg@1.0.0"])
    }

    @MainActor
    func testPlan_RemoteEntry_UsesStreamableTransport() throws {
        let server = try decodeFixture().servers[1].server
        let plan = MCPRegistryInstallPlan.make(for: server)

        guard case .remote(let url, let transport) = plan.kind else {
            return XCTFail("Expected a remote plan")
        }
        XCTAssertEqual(url, "https://api.inference.sh/mcp")
        XCTAssertEqual(transport, .streamableHTTP)
        XCTAssertTrue(plan.isRunnable)
    }

    /// A non-HTTPS endpoint would carry credentials and tool arguments in clear text.
    @MainActor
    func testPlan_InsecureRemote_IsBlocked() throws {
        let json = #"{"name":"x/y","description":"d","remotes":[{"type":"streamable-http","url":"http://evil.example/mcp"}]}"#
        let server = try JSONDecoder().decode(MCPRegistryServer.self, from: Data(json.utf8))
        let plan = MCPRegistryInstallPlan.make(for: server)

        XCTAssertFalse(plan.isRunnable)
        XCTAssertEqual(plan.blockedReason, "Insecure endpoint (not HTTPS)")
    }

    @MainActor
    func testPlan_LocalhostRemote_IsAllowedForDevelopment() throws {
        let json = #"{"name":"x/y","description":"d","remotes":[{"url":"http://localhost:3000/mcp"}]}"#
        let server = try JSONDecoder().decode(MCPRegistryServer.self, from: Data(json.utf8))
        XCTAssertTrue(MCPRegistryInstallPlan.make(for: server).isRunnable)
    }

    @MainActor
    func testPlan_ServerDefinition_CarriesEnvKeysNotValues() throws {
        let server = try decodeFixture().servers[0].server
        let definition = try XCTUnwrap(MCPRegistryInstallPlan.make(for: server).makeServerDefinition())

        XCTAssertEqual(definition.command, "npx")
        XCTAssertEqual(definition.envKeys, ["GCS_BUCKET", "GCS_PROJECT_ID"])
        XCTAssertNil(definition.url)
        // The definition is persisted to SwiftData; secrets belong in Keychain only.
        XCTAssertFalse("\(definition)".contains("secret"))
    }

    // MARK: - Lenient decoding

    /// A malformed or unfamiliar entry must not take the whole page down with it — the same
    /// failure mode that made ToolParameters silently swallow MCP tools.
    func testDecode_UnknownAndMissingFields_DoNotThrow() throws {
        let json = """
        {"servers":[{"server":{"name":"a/b","description":"d","futureField":{"x":1},
        "packages":[{"registryType":"npm","identifier":"p","unknownKey":[1,2]}]}}],"metadata":{}}
        """
        let response = try JSONDecoder().decode(MCPRegistryResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.servers.count, 1)
        XCTAssertEqual(response.servers[0].server.primaryPackage?.identifier, "p")
    }

    func testDecode_EmptyServerList_IsNotAnError() throws {
        let response = try JSONDecoder().decode(
            MCPRegistryResponse.self, from: Data(#"{"servers":[],"metadata":{"count":0}}"#.utf8)
        )
        XCTAssertTrue(response.servers.isEmpty)
    }

    // MARK: - Argument flattening

    func testArguments_NamedAndPositional() throws {
        let json = """
        {"registryType":"npm","identifier":"pkg","version":"1.0.0","runtimeHint":"npx",
         "runtimeArguments":[{"value":"-y","type":"positional"}],
         "packageArguments":[{"type":"named","name":"--root","value":"/tmp"},
                             {"type":"positional","value":"extra"},
                             {"type":"named","name":"--flag"}]}
        """
        let package = try JSONDecoder().decode(MCPRegistryPackage.self, from: Data(json.utf8))
        XCTAssertEqual(package.packageArguments.flatMap(\.argvComponents), ["--root", "/tmp", "extra", "--flag"])
    }

    /// A placeholder with no value belongs in the form, not silently in the command line.
    func testArguments_ValuelessPositional_ContributesNothing() throws {
        let json = #"{"registryType":"npm","identifier":"p","packageArguments":[{"type":"positional","isRequired":true}]}"#
        let package = try JSONDecoder().decode(MCPRegistryPackage.self, from: Data(json.utf8))
        XCTAssertTrue(package.packageArguments.flatMap(\.argvComponents).isEmpty)
    }

    // MARK: - Version deduplication
    //
    // Found on-device 2026-08-01: a real 50-entry page held only 32 distinct servers — one
    // publisher appeared four times. Duplicate names broke SwiftUI's ForEach identity and
    // scrambled the Discover grid into overlapping cells.

    private let multiVersionResponse = """
    {
      "servers": [
        {"server":{"name":"a/dup","description":"old","version":"1.0.0","remotes":[{"url":"https://x"}]},
         "_meta":{"io.modelcontextprotocol.registry/official":{"isLatest":false}}},
        {"server":{"name":"a/dup","description":"new","version":"3.0.0","remotes":[{"url":"https://x"}]},
         "_meta":{"io.modelcontextprotocol.registry/official":{"isLatest":true}}},
        {"server":{"name":"a/dup","description":"mid","version":"2.0.0","remotes":[{"url":"https://x"}]},
         "_meta":{"io.modelcontextprotocol.registry/official":{"isLatest":false}}},
        {"server":{"name":"b/solo","description":"only","version":"1.0.0","remotes":[{"url":"https://y"}]},
         "_meta":{"io.modelcontextprotocol.registry/official":{"isLatest":true}}}
      ],
      "metadata":{"count":4}
    }
    """

    @MainActor
    func testDeduplicate_KeepsOnlyTheLatestVersionPerServer() throws {
        let response = try JSONDecoder().decode(MCPRegistryResponse.self, from: Data(multiVersionResponse.utf8))
        let servers = MCPRegistryClient.deduplicate(response.servers)

        XCTAssertEqual(servers.count, 2, "Three versions of a/dup must collapse to one row")
        XCTAssertEqual(Set(servers.map(\.name)), ["a/dup", "b/solo"])

        let dup = try XCTUnwrap(servers.first { $0.name == "a/dup" })
        XCTAssertEqual(dup.version, "3.0.0", "The isLatest row must win, not the first encountered")
    }

    /// SwiftUI keys on `id`; a repeat here is what corrupted the grid.
    @MainActor
    func testDeduplicate_ProducesUniqueIdentifiers() throws {
        let response = try JSONDecoder().decode(MCPRegistryResponse.self, from: Data(multiVersionResponse.utf8))
        let ids = MCPRegistryClient.deduplicate(response.servers).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate ForEach IDs give undefined layout")
    }

    /// A metadata shape we don't recognise must not filter every row out.
    @MainActor
    func testDeduplicate_MissingIsLatest_StillYieldsOneRow() throws {
        let json = """
        {"servers":[
          {"server":{"name":"a/x","description":"d","version":"1.0.0","remotes":[{"url":"https://x"}]}},
          {"server":{"name":"a/x","description":"d","version":"2.0.0","remotes":[{"url":"https://x"}]}}
        ],"metadata":{}}
        """
        let response = try JSONDecoder().decode(MCPRegistryResponse.self, from: Data(json.utf8))
        let servers = MCPRegistryClient.deduplicate(response.servers)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.version, "1.0.0", "Falls back to first-seen")
    }

    @MainActor
    func testDeduplicate_AllOlderVersions_StillShowsTheServerOnce() throws {
        let json = """
        {"servers":[
          {"server":{"name":"a/x","description":"d","version":"1.0.0","remotes":[{"url":"https://x"}]},
           "_meta":{"io.modelcontextprotocol.registry/official":{"isLatest":false}}},
          {"server":{"name":"a/x","description":"d","version":"2.0.0","remotes":[{"url":"https://x"}]},
           "_meta":{"io.modelcontextprotocol.registry/official":{"isLatest":false}}}
        ],"metadata":{}}
        """
        let response = try JSONDecoder().decode(MCPRegistryResponse.self, from: Data(json.utf8))
        XCTAssertEqual(MCPRegistryClient.deduplicate(response.servers).count, 1,
                       "A server with no latest-marked row must still be reachable")
    }

    // MARK: - Remote transport mapping

    func testRemote_TransportMapping() throws {
        func mode(_ type: String?) throws -> MCPTransportMode {
            let typeJSON = type.map { "\"type\":\"\($0)\"," } ?? ""
            let json = "{\(typeJSON)\"url\":\"https://x\"}"
            return try JSONDecoder().decode(MCPRegistryRemote.self, from: Data(json.utf8)).transportMode
        }

        XCTAssertEqual(try mode("streamable-http"), .streamableHTTP)
        XCTAssertEqual(try mode("sse"), .httpNoStreaming, "Deprecated SSE servers need the non-streaming path")
        XCTAssertEqual(try mode(nil), .streamableHTTP, "Unstated defaults to the standard")
    }
}
