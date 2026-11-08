import XCTest
import ACP
@testable import ACPCode
import ACPClient

/// Pure rules for Git at project creation and git credentials (D-105). No network.
final class GatewayGitRulesTests: XCTestCase {

    // MARK: Remote URL

    func testEmptyRemoteMeansNoRemoteAndIsValid() {
        XCTAssertNil(GatewayGitRemoteRules.problem(with: ""))
        XCTAssertNil(GatewayGitRemoteRules.host(of: ""))
    }

    func testHTTPSRepositoryIsValidAndHostIsLowercased() {
        XCTAssertNil(GatewayGitRemoteRules.problem(with: "https://github.com/owner/repo.git"))
        XCTAssertEqual(GatewayGitRemoteRules.host(of: "https://GitHub.com/owner/repo.git"), "github.com")
    }

    func testHTTPIsRefused() {
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: "http://github.com/owner/repo.git"), "Use https:// for the remote.")
    }

    func testUserNameAndPasswordAreRefused() {
        let problem = GatewayGitRemoteRules.problem(with: "https://user:secret@github.com/owner/repo.git")
        XCTAssertEqual(problem, "Remove the user name and password from the URL. Choose a credential instead.")
        XCTAssertNil(GatewayGitRemoteRules.host(of: "https://user@github.com/owner/repo.git"))
    }

    func testQueryAndFragmentAreRefused() {
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: "https://github.com/owner/repo.git?ref=main"),
                       "Remove the query or fragment from the URL.")
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: "https://github.com/owner/repo.git#x"),
                       "Remove the query or fragment from the URL.")
    }

    func testPortIsRefused() {
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: "https://github.com:8443/owner/repo.git"), "Remove the port from the URL.")
    }

    func testSpacesAndNonASCIIAreRefused() {
        let spaced = GatewayGitRemoteRules.problem(with: "https://github.com/owner/my repo.git")
        XCTAssertEqual(spaced, "The URL has spaces or characters that are not allowed. Check it and try again.")
        XCTAssertNotNil(GatewayGitRemoteRules.problem(with: "https://gïthub.com/owner/repo.git"))
        XCTAssertNotNil(GatewayGitRemoteRules.problem(with: "https://github.com/owner/repo\u{7}.git"))
    }

    func testOtherSchemesAndLocalPathsAreRefused() {
        for raw in ["ssh://github.com/owner/repo.git", "git@github.com:owner/repo.git", "file:///tmp/repo",
                    "ext::sh", "/Users/me/repo", "-oProxyCommand=x"] {
            XCTAssertEqual(GatewayGitRemoteRules.problem(with: raw), "Use https:// for the remote.", raw)
        }
    }

    func testMissingRepositoryPathIsRefused() {
        let message = "Name the repository, such as https://github.com/owner/repo.git."
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: "https://github.com"), message)
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: "https://github.com/"), message)
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: "https://github.com/owner/"), message)
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: "https://github.com/owner/../x"), message)
    }

    func testRemoteLongerThan2048IsRefused() {
        let long = "https://github.com/" + String(repeating: "a", count: 2100) + ".git"
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: long), "Use at most 2048 characters.")
    }

    func testAllowListIsCheckedOnlyWhenTheGatewayReportsOne() {
        let url = "https://gitlab.com/owner/repo.git"
        XCTAssertNil(GatewayGitRemoteRules.problem(with: url), "shape only when no list is reported")
        XCTAssertEqual(GatewayGitRemoteRules.problem(with: url, allowedHosts: ["github.com"]),
                       "This host is not on the gateway's allow-list.")
        XCTAssertNil(GatewayGitRemoteRules.problem(with: url, allowedHosts: ["gitlab.com"]))
    }

    // MARK: Credential rows

    private func credential(_ id: String, _ name: String, _ host: String) -> GatewayGitCredential {
        GatewayGitCredential(id: id, name: name, host: host, createdAt: "2026-11-08T10:00:00.000Z", hasSecret: true)
    }

    func testCredentialRowsAreOnlyThoseForTheRemoteHost() {
        let all = [credential("a", "Work GitHub", "github.com"), credential("b", "Personal GitLab", "gitlab.com")]
        XCTAssertEqual(GatewayGitCredentialRows.matching(all, remoteHost: "github.com").map(\.id), ["a"])
        XCTAssertEqual(GatewayGitCredentialRows.matching(all, remoteHost: "GitHub.COM").map(\.id), ["a"])
        XCTAssertEqual(GatewayGitCredentialRows.matching(all, remoteHost: "example.com"), [])
    }

    func testNoRemoteHostMeansNoCredentialRows() {
        let all = [credential("a", "Work GitHub", "github.com")]
        XCTAssertEqual(GatewayGitCredentialRows.matching(all, remoteHost: nil), [])
        XCTAssertEqual(GatewayGitCredentialRows.matching(all, remoteHost: ""), [])
    }

    // MARK: Unborn and detached display

    func testUnbornRepositoryShowsNoCommitsYetNotDetachedHead() {
        XCTAssertEqual(GatewayGitHeadText.label(branch: "", unborn: true), "No commits yet")
        XCTAssertEqual(GatewayGitHeadText.label(branch: nil, unborn: true), "No commits yet")
        XCTAssertEqual(GatewayGitHeadText.label(branch: "main", unborn: true), "No commits yet")
    }

    func testDetachedHeadAndBranchAreUnchanged() {
        XCTAssertEqual(GatewayGitHeadText.label(branch: nil, unborn: false), "Detached HEAD")
        XCTAssertEqual(GatewayGitHeadText.label(branch: "main", unborn: false), "main")
    }

    // MARK: Secrets over ws://

    func testSecretsAreAllowedOnlyOverWSS() {
        XCTAssertTrue(GatewayGitSecretPolicy.allowsSecret(overScheme: "wss"))
        XCTAssertTrue(GatewayGitSecretPolicy.allowsSecret(overScheme: "WSS"))
        XCTAssertFalse(GatewayGitSecretPolicy.allowsSecret(overScheme: "ws"))
        XCTAssertFalse(GatewayGitSecretPolicy.allowsSecret(overScheme: "WS"))
        XCTAssertFalse(GatewayGitSecretPolicy.allowsSecret(overScheme: "http"))
        XCTAssertFalse(GatewayGitSecretPolicy.allowsSecret(overScheme: ""))
    }

    // MARK: Name, host and token

    func testNameRules() {
        XCTAssertEqual(GatewayGitCredentialRules.nameProblem("  ", existing: [], replacing: nil), "Enter a name.")
        XCTAssertEqual(GatewayGitCredentialRules.nameProblem(String(repeating: "n", count: 41), existing: [], replacing: nil),
                       "Use at most 40 characters.")
        let existing = [credential("a", "Work GitHub", "github.com")]
        XCTAssertEqual(GatewayGitCredentialRules.nameProblem("work github", existing: existing, replacing: nil),
                       "A credential named “work github” already exists.")
        XCTAssertNil(GatewayGitCredentialRules.nameProblem("Work GitHub", existing: existing, replacing: "a"),
                     "a profile may keep its own name when replaced")
    }

    func testHostRules() {
        XCTAssertNil(GatewayGitCredentialRules.hostProblem("github.com"))
        XCTAssertNotNil(GatewayGitCredentialRules.hostProblem(""))
        XCTAssertNotNil(GatewayGitCredentialRules.hostProblem("https://github.com"))
        XCTAssertNotNil(GatewayGitCredentialRules.hostProblem("github.com/owner"))
        XCTAssertNotNil(GatewayGitCredentialRules.hostProblem("github.com:443"))
    }

    func testTokenRules() {
        XCTAssertNil(GatewayGitCredentialRules.tokenProblem("ghp_abc123"))
        XCTAssertNotNil(GatewayGitCredentialRules.tokenProblem(""))
        XCTAssertNotNil(GatewayGitCredentialRules.tokenProblem("has space"))
        XCTAssertNotNil(GatewayGitCredentialRules.tokenProblem("tökén"))
        XCTAssertNotNil(GatewayGitCredentialRules.tokenProblem(String(repeating: "t", count: 4097)))
    }

    // MARK: Created date

    func testCreatedLabelReadsTheGatewayTimestamp() {
        let label = GatewayGitCredentialText.createdLabel("2026-11-08T10:00:00.000Z")
        XCTAssertNotNil(label)
        XCTAssertTrue(label?.hasPrefix("Created ") == true)
        XCTAssertTrue(label?.contains("2026") == true)
        XCTAssertNil(GatewayGitCredentialText.createdLabel("yesterday"))
    }

    // MARK: Create request

    func testCreateRequestSendsNoGitFieldsWhenTheToggleIsOff() {
        let params = GatewayProjectCreateRequest.params(name: "api", path: "/srv/root", git: nil).objectValue ?? [:]
        XCTAssertEqual(Set(params.keys), ["name", "path", "createFolder"])
        XCTAssertEqual(params["createFolder"]?.boolValue, true)
    }

    func testCreateRequestAddsGitFieldsWhenTheToggleIsOn() {
        let git = GatewayGitSetup(remote: "https://github.com/owner/repo.git", credentialId: "0123456789ab")
        let params = GatewayProjectCreateRequest.params(name: "api", path: "/srv/root", git: git).objectValue ?? [:]
        XCTAssertEqual(params["createFolder"]?.boolValue, true)
        XCTAssertEqual(params["gitInit"]?.boolValue, true)
        XCTAssertEqual(params["gitRemote"]?.stringValue, "https://github.com/owner/repo.git")
        XCTAssertEqual(params["credentialId"]?.stringValue, "0123456789ab")
    }

    func testCreateRequestInitsWithoutRemoteAndDropsCredentialWithoutRemote() {
        let git = GatewayGitSetup(remote: nil, credentialId: "0123456789ab")
        let params = GatewayProjectCreateRequest.params(name: "api", path: "/srv/root", git: git).objectValue ?? [:]
        XCTAssertEqual(params["gitInit"]?.boolValue, true)
        XCTAssertNil(params["gitRemote"])
        XCTAssertNil(params["credentialId"], "the gateway refuses a credential without a remote")
    }

    // MARK: Send log

    func testSecretMethodIsNotLogged() {
        let token = "ghp_TOPSECRETVALUE"
        let plain = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"_acpcode/git/credentials/set\",\"params\":{\"token\":\"\(token)\"}}"
        let escaped = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"_acpcode\\/git\\/credentials\\/set\",\"params\":{\"token\":\"\(token)\"}}"
        for text in [plain, escaped] {
            let logged = ACPLogRedaction.redactedForLog(text)
            XCTAssertFalse(logged.contains(token))
            XCTAssertTrue(logged.contains("_acpcode/git/credentials/set"))
        }
    }

    func testOtherMessagesAreLoggedAsSent() {
        let text = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"_acpcode/git/credentials/list\"}"
        XCTAssertEqual(ACPLogRedaction.redactedForLog(text), text)
    }
}
