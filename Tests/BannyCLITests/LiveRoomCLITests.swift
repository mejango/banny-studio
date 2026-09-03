import Foundation
import XCTest
@testable import BannyCLI
import BannyCore
import BannyLive
import BannyRender

final class LiveRoomCLITests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("banny-room-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRoomURLNormalizesBrowserAndAPIPaths() throws {
        let expected = URL(string: "https://rooms.example/v1/rooms/after-hours")
        for raw in [
            "https://rooms.example/rooms/after-hours",
            "https://rooms.example/rooms/after-hours/live",
            "https://rooms.example/rooms/after-hours/join",
            "https://rooms.example/v1/rooms/after-hours",
        ] {
            let endpoint = try RoomCLIEndpoint(raw)
            XCTAssertEqual(endpoint.roomID, "after-hours")
            XCTAssertEqual(endpoint.apiRoomURL, expected)
        }

        XCTAssertEqual(
            try RoomCLIEndpoint("http://127.0.0.1:7330/rooms/local").roomID,
            "local")
        XCTAssertThrowsError(
            try RoomCLIEndpoint("http://rooms.example/rooms/plaintext"))
        XCTAssertEqual(
            try RoomCLIEndpoint(
                "http://rooms.example/rooms/plaintext",
                allowInsecureRemote: true).roomID,
            "plaintext")

        for raw in [
            "file:///rooms/after-hours",
            "https://user:secret@rooms.example/rooms/after-hours",
            "https://rooms.example/rooms/after-hours?token=secret",
            "https://rooms.example/rooms/after-hours/unknown",
            "https://rooms.example/rooms/%2Fetc%2Fpasswd",
            "https://rooms.example/v1/rooms/%2E",
            "https://rooms.example/v1/rooms/%2E%2E",
        ] {
            XCTAssertThrowsError(try RoomCLIEndpoint(raw), raw)
        }
    }

    func testRoomServeOptionsRequireExactHostsForInternetListeners() throws {
        let local = try parseRoomServeCommandOptions([])
        XCTAssertEqual(local.bind, "127.0.0.1")
        XCTAssertEqual(local.port, 7_330)
        XCTAssertTrue(local.allowedHosts.isEmpty)
        XCTAssertEqual(local.maximumRooms, 100)
        XCTAssertEqual(local.maximumStorageBytes, 20 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(local.director, .builtIn)

        let publicOptions = try parseRoomServeCommandOptions([
            "--bind", "0.0.0.0",
            "--port", "8443",
            "--allowed-host", "rooms.example.com",
            "--allowed-host", "www.rooms.example.com",
            "--max-rooms", "12",
            "--max-storage-bytes", "3456789",
            "--director", "ollama",
            "--director-url", "http://127.7.0.1:22434",
            "--director-model", "qwen2.5:7b",
            "--json",
        ])
        XCTAssertEqual(publicOptions.bind, "0.0.0.0")
        XCTAssertEqual(publicOptions.port, 8_443)
        XCTAssertEqual(publicOptions.allowedHosts, [
            "rooms.example.com", "www.rooms.example.com",
        ])
        XCTAssertEqual(publicOptions.maximumRooms, 12)
        XCTAssertEqual(publicOptions.maximumStorageBytes, 3_456_789)
        XCTAssertEqual(
            publicOptions.director,
            .ollama(.init(
                endpoint: try XCTUnwrap(URL(string: "http://127.7.0.1:22434")),
                model: "qwen2.5:7b")))
        XCTAssertEqual(
            publicOptions.hostLimits,
            LiveRoomHostLimits(maximumRooms: 12, maximumStorageBytes: 3_456_789))
        XCTAssertTrue(publicOptions.json)

        XCTAssertThrowsError(try parseRoomServeCommandOptions([
            "--bind", "0.0.0.0",
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("requires at least one --allowed-host"))
        }
        XCTAssertThrowsError(try parseRoomServeCommandOptions([
            "--bind", "::",
        ]))

        for host in [
            "https://rooms.example.com",
            "*.example.com",
            "rooms.example.com:443",
        ] {
            XCTAssertThrowsError(try parseRoomServeCommandOptions([
                "--bind", "0.0.0.0", "--allowed-host", host,
            ]), host) { error in
                XCTAssertTrue(String(describing: error).contains("invalid --allowed-host"))
            }
        }

        for arguments in [
            ["--max-rooms", "0"],
            ["--max-rooms", "-1"],
            ["--max-storage-bytes", "0"],
            ["--max-storage-bytes", "-1"],
            ["--max-storage-bytes", "18446744073709551616"],
            ["--max-rooms", "1", "--max-rooms", "2"],
            ["--max-storage-bytes", "1", "--max-storage-bytes", "2"],
        ] {
            XCTAssertThrowsError(try parseRoomServeCommandOptions(arguments))
        }

        let report = RoomServeReadyReport(
            ok: true,
            operation: "room_serve",
            url: "http://127.0.0.1:7330/",
            bind: "127.0.0.1",
            port: 7_330,
            storage: "/tmp/rooms",
            maximumRooms: 100,
            maximumStorageBytes: 20 * 1_024 * 1_024 * 1_024,
            director: "ollama",
            directorModel: "llama3.2:3b")
        let encodedReport = String(
            decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertTrue(encodedReport.contains(#""maximum_rooms":100"#))
        XCTAssertTrue(encodedReport.contains(#""maximum_storage_bytes":21474836480"#))
        XCTAssertTrue(encodedReport.contains(#""director":"ollama""#))
        XCTAssertTrue(encodedReport.contains(#""director_model":"llama3.2:3b""#))
    }

    func testRoomServeOllamaDirectorDefaultsAndRejectsUnsafeConfiguration() throws {
        let ollama = try parseRoomServeCommandOptions(["--director", "ollama"])
        XCTAssertEqual(
            ollama.director,
            .ollama(.init(
                endpoint: OllamaLiveDirectorConfiguration.defaultEndpoint,
                model: OllamaLiveDirectorConfiguration.defaultModel)))

        for arguments in [
            ["--director", "unknown"],
            ["--director-url", "http://127.0.0.1:11434"],
            ["--director-model", "llama3.2:3b"],
            ["--director", "built-in", "--director-model", "llama3.2:3b"],
            ["--director", "ollama", "--director-url", "http://localhost:11434"],
            ["--director", "ollama", "--director-url", "https://127.0.0.1:11434"],
            ["--director", "ollama", "--director-url", "http://192.168.1.2:11434"],
            ["--director", "ollama", "--director-url", "http://127.0.0.1:11434/api/chat"],
            ["--director", "ollama", "--director-model", "bad model"],
        ] {
            XCTAssertThrowsError(try parseRoomServeCommandOptions(arguments), arguments.joined(separator: " "))
        }
    }

    func testRoomContractLocksProtocolAndActionDiscriminator() throws {
        let contract = RoomAgentContractReport.current
        XCTAssertEqual(contract.protocolVersion, "banny.agent.v1")
        XCTAssertEqual(contract.actionDiscriminator, "op")
        XCTAssertEqual(contract.limits.responseBytes, 16 * 1_024)
        XCTAssertEqual(contract.limits.requestAfterMS.minimum, 250)
        XCTAssertEqual(contract.limits.reactionIntensity.maximum, 4)
        XCTAssertTrue(contract.rules.invalidDecisionIsAtomic)
        XCTAssertTrue(contract.rules.duplicateActionGroupsRejected)
        let joinCapability = try XCTUnwrap(commandCapabilities.first {
            $0.name == "room join"
        })
        XCTAssertTrue(joinCapability.summary.lowercased().contains("deprecated"))
        XCTAssertTrue(joinCapability.usage.contains("--credentials-file"))
        XCTAssertTrue(joinCapability.options.contains {
            $0.name == "--credentials-file"
        })
        let serveCapability = try XCTUnwrap(commandCapabilities.first {
            $0.name == "room serve"
        })
        XCTAssertTrue(serveCapability.usage.contains("--allowed-host HOST ..."))
        XCTAssertTrue(serveCapability.usage.contains("--max-rooms N"))
        XCTAssertTrue(serveCapability.usage.contains("--max-storage-bytes BYTES"))
        XCTAssertTrue(serveCapability.options.contains {
            $0.name == "--allowed-host"
                && $0.description.lowercased().contains("repeatable")
        })
        XCTAssertTrue(serveCapability.options.contains {
            $0.name == "--max-rooms" && $0.defaultValue == "100"
        })
        XCTAssertTrue(serveCapability.options.contains {
            $0.name == "--max-storage-bytes"
                && $0.defaultValue == "21474836480"
        })
        for option in ["--director", "--director-url", "--director-model"] {
            XCTAssertTrue(serveCapability.options.contains { $0.name == option })
        }
        XCTAssertEqual(
            contract.contextFields["context"],
            ["scene_time_ms", "room", "self_state", "cast", "recent_events", "constraints"])
        XCTAssertEqual(contract.actions.map(\.op), [
            "move", "depth", "tilt", "expression", "jump",
            "flip", "rotate", "zoom", "reset", "reaction",
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(contract)) as? [String: Any])
        XCTAssertEqual(object["protocol"] as? String, "banny.agent.v1")
        XCTAssertEqual(object["action_discriminator"] as? String, "op")
    }

    func testRevokedRoomSessionEndsBridgeCleanly() {
        XCTAssertTrue(roomBridgeWasClosed(.httpStatus(401)))
        XCTAssertFalse(roomBridgeWasClosed(.httpStatus(403)))
        XCTAssertFalse(roomBridgeWasClosed(.timedOut))
    }

    func testAvatarJSONIsStrictAndPortableCharacterDropsPerformance() throws {
        let root = try temporaryDirectory()
        let catalog = try AssetCatalog(assetsRoot: locateAssetsRoot())
        let avatarURL = root.appendingPathComponent("avatar.json")
        try Data(#"{"body":"pink","eyes":"default","mouth":"default","outfit":{}}"#.utf8)
            .write(to: avatarURL)
        XCTAssertEqual(
            try loadRoomCLIAvatar(at: avatarURL, catalog: catalog),
            RoomCLIAvatar(body: .pink, eyes: "default", mouth: "default", outfit: [:]))

        let rejectedURL = root.appendingPathComponent("rejected.json")
        try Data(#"{"body":"pink","eyes":"default","mouth":"default","outfit":{},"agent_endpoint":"http://127.0.0.1"}"#.utf8)
            .write(to: rejectedURL)
        XCTAssertThrowsError(try loadRoomCLIAvatar(at: rejectedURL, catalog: catalog))

        let character = Character(
            body: .alien,
            baseOutfit: [
                OutfitCategory.eyes.rawValue: "default",
                OutfitCategory.mouth.rawValue: "default",
            ],
            subs: [.init(text: "must be discarded", start: 0, dur: 1)],
            events: [.key(t: 0, code: .keyJ, down: true)],
            name: "Untrusted source name")
        let archive = PortableTrack(payload: .character(character))
        let trackURL = root.appendingPathComponent("character.bannytrack")
        try archive.encoded().write(to: trackURL)
        XCTAssertEqual(
            try loadRoomCLIAvatar(at: trackURL, catalog: catalog),
            RoomCLIAvatar(body: .alien, eyes: "default", mouth: "default", outfit: [:]))
    }

    func testCredentialsFileIsStrictBoundedAndPrivate() throws {
        let root = try temporaryDirectory()
        let credentialsURL = root.appendingPathComponent("credentials.json")
        try Data(#"{"identity":"machine-alice","invite":"room-secret","agent_token":"local-secret"}"#.utf8)
            .write(to: credentialsURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialsURL.path)
        XCTAssertEqual(
            try loadRoomCLIJoinCredentials(at: credentialsURL),
            RoomCLIJoinCredentials(
                identity: "machine-alice",
                invite: "room-secret",
                agentToken: "local-secret"))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: credentialsURL.path)
        XCTAssertThrowsError(try loadRoomCLIJoinCredentials(at: credentialsURL)) { error in
            XCTAssertTrue(String(describing: error).contains("chmod 600"))
        }

        let unknownURL = root.appendingPathComponent("unknown.json")
        try Data(#"{"invite":"secret","agent_endpoint":"http://127.0.0.1"}"#.utf8)
            .write(to: unknownURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: unknownURL.path)
        XCTAssertThrowsError(try loadRoomCLIJoinCredentials(at: unknownURL)) { error in
            XCTAssertTrue(String(describing: error).contains("agent_endpoint"))
        }

        let oversizedURL = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 16 * 1_024 + 1).write(to: oversizedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: oversizedURL.path)
        XCTAssertThrowsError(try loadRoomCLIJoinCredentials(at: oversizedURL)) { error in
            XCTAssertTrue(String(describing: error).contains("16384-byte"))
        }

        let symlinkURL = root.appendingPathComponent("credentials-link.json")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: credentialsURL)
        XCTAssertThrowsError(try loadRoomCLIJoinCredentials(at: symlinkURL)) { error in
            XCTAssertTrue(String(describing: error).contains("non-symlink"))
        }
    }

    func testCredentialsFileAndLegacyArgumentsCannotDuplicateFields() throws {
        let file = RoomCLIJoinCredentials(
            identity: "machine-alice",
            invite: "room-secret",
            agentToken: "local-secret")
        XCTAssertThrowsError(try mergeRoomCLIJoinCredentials(
            file: file, identity: "other", invite: nil, agentToken: nil))
        XCTAssertThrowsError(try mergeRoomCLIJoinCredentials(
            file: file, identity: nil, invite: "other", agentToken: nil))
        XCTAssertThrowsError(try mergeRoomCLIJoinCredentials(
            file: file, identity: nil, invite: nil, agentToken: "other"))

        XCTAssertEqual(
            try mergeRoomCLIJoinCredentials(
                file: RoomCLIJoinCredentials(invite: "room-secret"),
                identity: "machine-alice",
                invite: nil,
                agentToken: "local-secret"),
            file)
    }
}
