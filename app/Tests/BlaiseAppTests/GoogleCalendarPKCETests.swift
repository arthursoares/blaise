import Foundation
import Testing

@testable import BlaiseApp

/// Pins the security-critical PKCE primitive: the S256 `code_challenge` must be
/// the base64url-no-pad SHA-256 of the verifier. Validated against the RFC 7636
/// §B test vector so a refactor of the hashing/encoding can't silently weaken
/// the OAuth flow.
struct GoogleCalendarPKCETests {
    @Test("S256 code challenge matches the RFC 7636 §B vector")
    func rfc7636Vector() {
        // RFC 7636 §B: verifier → expected S256 challenge.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = GoogleCalendarClient.codeChallenge(for: verifier)
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("challenge is URL-safe base64 with no padding")
    func urlSafeNoPadding() {
        let challenge = GoogleCalendarClient.codeChallenge(for: "any-verifier-value")
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test("a callback error echoed into the loopback page is not markup")
    func loopbackPageEscapesCallbackError() {
        let escaped = htmlEscaped("<script>alert(1)</script> & co")
        #expect(escaped == "&lt;script&gt;alert(1)&lt;/script&gt; &amp; co")
        #expect(htmlEscaped("access_denied") == "access_denied")
    }
}
