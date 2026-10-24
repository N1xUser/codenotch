import XCTest
@testable import Codenotch

final class HiggsfieldCredentialsTests: XCTestCase {
    private func temporaryFileURL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("higgsfield-cred-\(UUID().uuidString).json")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    func testLoadsFromSettingsToken() throws {
        var sources = HiggsfieldCredentialSources()
        sources.settingsToken = { "hf-secret-from-settings" }
        sources.settingsPresent = { true }

        let cred = try HiggsfieldCredentials.load(sources)
        XCTAssertEqual(cred.token, "hf-secret-from-settings")
        XCTAssertEqual(cred.source, .settings)
        XCTAssertTrue(HiggsfieldCredentials.isPresent(sources))
    }

    func testLoadsFromEnvironment() throws {
        var sources = HiggsfieldCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = ["HIGGSFIELD_API_KEY": "env-api-key-123"]

        let cred = try HiggsfieldCredentials.load(sources)
        XCTAssertEqual(cred.token, "env-api-key-123")
        XCTAssertEqual(cred.source, .environment)
        XCTAssertTrue(HiggsfieldCredentials.isPresent(sources))
    }

    func testLoadsFromCredentialsFile() throws {
        let fileURL = try temporaryFileURL(#"{"access_token": "token-from-file-abc"}"#)
        var sources = HiggsfieldCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURL = fileURL

        let cred = try HiggsfieldCredentials.load(sources)
        XCTAssertEqual(cred.token, "token-from-file-abc")
        XCTAssertEqual(cred.source, .credentialsFile)
        XCTAssertTrue(HiggsfieldCredentials.isPresent(sources))
    }

    func testThrowsNeedsAuthWhenNoCredentialsFound() {
        var sources = HiggsfieldCredentialSources()
        sources.settingsToken = { nil }
        sources.settingsPresent = { false }
        sources.environment = [:]
        sources.credentialsURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")
        sources.locateBinary = { nil }

        XCTAssertFalse(HiggsfieldCredentials.isPresent(sources))
        XCTAssertThrowsError(try HiggsfieldCredentials.load(sources)) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("Expected needsAuth, got \(error)")
            }
        }
    }
}
