import XCTest
@testable import AwgScale

final class LocalAPITests: XCTestCase {
    func testBodylessResponsesNeverCallGomobileReader() throws {
        for status in [204, 205, 304] {
            let body = try localAPIResponseBody(statusCode: status, method: "POST", readBody: true) {
                XCTFail("A bodyless response must not cross the NSData bridge")
                throw NSError(domain: "bridge", code: 1)
            }
            XCTAssertTrue(body.isEmpty)
        }
        XCTAssertTrue(localAPIResponseBody(statusCode: 200, method: "HEAD", readBody: true) {
            XCTFail("HEAD must not read a body")
            return Data()
        }.isEmpty)
    }

    func testRealBodyReadFailuresAreNotSwallowed() {
        XCTAssertThrowsError(try localAPIResponseBody(statusCode: 200, method: "GET", readBody: true) {
            throw NSError(domain: "read", code: 2)
        })
        let expected = Data("response".utf8)
        XCTAssertEqual(localAPIResponseBody(statusCode: 200, method: "GET", readBody: true) { expected }, expected)
    }

    func testAuthKeyErrorsKeepStageAndStatusButNotSecrets() {
        let error = LocalAPIError.unsuccessfulStatus(statusCode: 500, endpoint: "secret-key", bodyPreview: "secret-key")
        let submit = authKeyLoginFailureMessage(error, activating: false)
        let activate = authKeyLoginFailureMessage(error, activating: true)
        XCTAssertTrue(submit.contains("submit"))
        XCTAssertTrue(activate.contains("registration"))
        XCTAssertTrue(submit.contains("HTTP 500"))
        XCTAssertFalse(submit.contains("secret-key"))
        XCTAssertFalse(activate.contains("secret-key"))
        let unknown = NSError(domain: "secret-key", code: 42, userInfo: [NSLocalizedDescriptionKey: "secret-key"])
        XCTAssertFalse(authKeyLoginFailureMessage(unknown, activating: false).contains("secret-key"))
    }

    private struct Sample: Codable, Equatable {
        let value: String
    }

    func testDecodedBodyReturnsModel() throws {
        let data = try JSONEncoder().encode(Sample(value: "ok"))
        let response = IPCResponse.success(statusCode: 200, body: data)

        let decoded = try response.decodedBody(Sample.self, endpoint: "/localapi/v0/test")

        XCTAssertEqual(decoded, Sample(value: "ok"))
    }

    func testRequireSuccessIncludesErrorBodyPreview() {
        let response = IPCResponse.success(statusCode: 409, body: Data("peer unavailable".utf8))

        XCTAssertThrowsError(try response.requireSuccess(endpoint: "/localapi/v0/test")) { error in
            XCTAssertTrue(error.localizedDescription.contains("HTTP 409"))
            XCTAssertTrue(error.localizedDescription.contains("peer unavailable"))
        }
    }

    func testBodyDataRejectsInvalidBase64() {
        let response = IPCResponse(statusCode: 200, bodyBase64: "not base64", error: nil)

        XCTAssertThrowsError(try response.bodyData(endpoint: "/localapi/v0/test")) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid response body"))
        }
    }

    func testTaildropDeleteEscapesOnePathSegment() async throws {
        var capturedEndpoint = ""
        let client = LocalAPIClient { _, endpoint, _, _, _ in
            capturedEndpoint = endpoint
            return IPCResponse.success(statusCode: 204)
        }

        try await client.deleteTaildropFile(name: "a/b #?.txt")

        XCTAssertEqual(capturedEndpoint, "/localapi/v0/files/a%2Fb%20%23%3F.txt")
    }

    func testProfileIDsAreEscapedAsPathSegments() async throws {
        var capturedEndpoints: [String] = []
        let client = LocalAPIClient { _, endpoint, _, _, _ in
            capturedEndpoints.append(endpoint)
            return IPCResponse.success(statusCode: 204)
        }

        try await client.switchProfile(id: "profile/one")
        try await client.deleteProfile(id: "profile#two")

        XCTAssertEqual(capturedEndpoints, [
            "/localapi/v0/profiles/profile%2Fone",
            "/localapi/v0/profiles/profile%23two",
        ])
    }

    func testProfileCreationAndAuthKeyUseOfficialLocalAPIContracts() async throws {
        var requests: [(method: String, endpoint: String, body: Data?)] = []
        let client = LocalAPIClient { method, endpoint, body, _, _ in
            requests.append((method, endpoint, body))
            return IPCResponse.success(statusCode: 204)
        }

        try await client.newProfile()
        try await client.login(authKey: "tskey-auth-test")

        XCTAssertEqual(requests.map(\.method), ["PUT", "POST"])
        XCTAssertEqual(requests.map(\.endpoint), [
            "/localapi/v0/profiles/",
            "/localapi/v0/start",
        ])
        let startBody = try XCTUnwrap(requests.last?.body)
        let startOptions = try XCTUnwrap(
            JSONSerialization.jsonObject(with: startBody) as? [String: String]
        )
        XCTAssertEqual(startOptions, ["AuthKey": "tskey-auth-test"])
    }

    func testAuthKeyLoginPropagatesRejectedStart() async {
        let client = LocalAPIClient { method, endpoint, _, timeout, readBody in
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(endpoint, "/localapi/v0/start")
            XCTAssertEqual(timeout, 30_000)
            XCTAssertFalse(readBody, "A successful /start has no response body")
            return .success(statusCode: 401, body: Data("registration rejected".utf8))
        }
        do {
            try await client.login(authKey: "key")
            XCTFail("A rejected start must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
        }
    }

    func testBugReportUsesRequiredPOSTMethod() async throws {
        var capturedMethod = ""
        var capturedEndpoint = ""
        let client = LocalAPIClient { method, endpoint, _, _, _ in
            capturedMethod = method
            capturedEndpoint = endpoint
            return IPCResponse.success(statusCode: 200, body: Data("BUG-test".utf8))
        }

        let marker = try await client.bugReportLogs()
        XCTAssertEqual(marker, "BUG-test")
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedEndpoint, "/localapi/v0/bugreport")
    }

    func testAWGPeerDiscoveryLeavesMarginForCoreBatchDeadline() async throws {
        var capturedTimeout = 0
        let client = LocalAPIClient { method, endpoint, _, timeout, _ in
            XCTAssertEqual(method, "GET")
            XCTAssertEqual(endpoint, "/localapi/v0/awg-sync-peers")
            capturedTimeout = timeout
            return IPCResponse.success(statusCode: 200, body: Data("[]".utf8))
        }

        let peers = try await client.awgPeers()

        XCTAssertTrue(peers.isEmpty)
        XCTAssertEqual(capturedTimeout, 30_000)
        XCTAssertGreaterThan(capturedTimeout, 14_000)
    }
}

final class TaildropFileSafetyTests: XCTestCase {
    func testAPIFileNamesMustBeLocalBasenames() {
        XCTAssertTrue(TaildropFile.isSafeLocalName("report.txt"))
        XCTAssertTrue(TaildropFile.isSafeLocalName("space name.txt"))
        XCTAssertFalse(TaildropFile.isSafeLocalName(""))
        XCTAssertFalse(TaildropFile.isSafeLocalName("."))
        XCTAssertFalse(TaildropFile.isSafeLocalName(".."))
        XCTAssertFalse(TaildropFile.isSafeLocalName("../secret.txt"))
        XCTAssertFalse(TaildropFile.isSafeLocalName("folder/file.txt"))
        XCTAssertFalse(TaildropFile.isSafeLocalName("folder\\file.txt"))
    }

    func testSharedInputNamesAreReducedToSafeBasenames() {
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "../private/report.txt", fallbackName: "fallback"),
            "report.txt"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "..", fallbackName: "fallback.txt"),
            "fallback.txt"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: ".", fallbackName: ".."),
            "file"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "folder\\secret.txt", fallbackName: "fallback"),
            "folder-secret.txt"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "/", fallbackName: "fallback.txt"),
            "fallback.txt"
        )
        XCTAssertEqual(
            safeSharedFileName(suggestedName: "\u{0}", fallbackName: "fallback.txt"),
            "fallback.txt"
        )
    }
}

final class TerminalScreenBufferTests: XCTestCase {
    func testValidatedTCPPortRejectsOutOfRangeValues() {
        XCTAssertEqual(validatedTCPPort("22"), 22)
        XCTAssertEqual(validatedTCPPort(" 443 "), 443)
        XCTAssertNil(validatedTCPPort("0"))
        XCTAssertNil(validatedTCPPort("-1"))
        XCTAssertNil(validatedTCPPort("65536"))
        XCTAssertNil(validatedTCPPort("ssh"))
    }

    func testConsumesBracketedPasteModeSequences() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("\u{1B}[?2004hroot@host:~# ".utf8))
        terminal.append(Data("\u{1B}[?2004l".utf8))

        XCTAssertEqual(terminal.renderedText, "root@host:~#")
    }

    func testCarriageReturnAndEraseLineReplaceHistoryPrompt() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("root@host:~# docker ps".utf8))
        terminal.append(Data("\r\u{1B}[Kroot@host:~# ls".utf8))

        XCTAssertEqual(terminal.renderedText, "root@host:~# ls")
    }

    func testBackspaceEchoUpdatesCurrentLine() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("root@host:~# catt\u{8} \u{8}".utf8))

        XCTAssertEqual(terminal.renderedText, "root@host:~# cat")
    }

    func testSplitUTF8ScalarIsDecodedOnceComplete() {
        var terminal = TerminalScreenBuffer()
        let bytes = Array("好".utf8)

        terminal.append(Data(bytes.prefix(2)))
        XCTAssertEqual(terminal.renderedText, "")

        terminal.append(Data(bytes.suffix(1)))
        XCTAssertEqual(terminal.renderedText, "好")
    }

    func testRenderedTextWithCursorUsesBufferedCursorPosition() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("abc\u{1B}[D".utf8))

        XCTAssertEqual(terminal.renderedText, "abc")
        XCTAssertEqual(terminal.renderedTextWithCursor, "ab█")
    }

    func testCursorVisibilitySequencesHideAndShowCursor() {
        var terminal = TerminalScreenBuffer()

        terminal.append(Data("abc\u{1B}[?25l".utf8))
        XCTAssertEqual(terminal.renderedTextWithCursor, "abc")

        terminal.append(Data("\u{1B}[?25h".utf8))
        XCTAssertEqual(terminal.renderedTextWithCursor, "abc█")
    }
}
