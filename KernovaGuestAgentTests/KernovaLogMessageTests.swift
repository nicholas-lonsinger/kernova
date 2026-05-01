import Testing

@Suite("KernovaLogMessage privacy redaction")
struct KernovaLogMessageTests {

    // MARK: - .public

    @Test("public String interpolation renders cleartext in both local and wire forms")
    func publicStringRendersInBothForms() {
        let name = "alice"
        let msg: KernovaLogMessage = "hi \(name, privacy: .public)"
        #expect(msg.localRendered == "hi alice")
        #expect(msg.wireRendered == "hi alice")
    }

    // MARK: - .private

    @Test("private String interpolation redacts local form, preserves wire form")
    func privateStringRedactsLocal() {
        let name = "alice"
        let msg: KernovaLogMessage = "hi \(name, privacy: .private)"
        #expect(msg.localRendered == "hi <private>")
        #expect(msg.wireRendered == "hi alice")
    }

    // MARK: - .sensitive

    @Test("sensitive String interpolation redacts local form, preserves wire form")
    func sensitiveStringRedactsLocal() {
        let name = "alice"
        let msg: KernovaLogMessage = "hi \(name, privacy: .sensitive)"
        #expect(msg.localRendered == "hi <private>")
        #expect(msg.wireRendered == "hi alice")
    }

    // MARK: - .auto

    @Test("auto String interpolation renders cleartext in both forms")
    func autoStringRendersInBothForms() {
        let name = "alice"
        let msg: KernovaLogMessage = "hi \(name, privacy: .auto)"
        #expect(msg.localRendered == "hi alice")
        #expect(msg.wireRendered == "hi alice")
    }

    // MARK: - Default privacy (private)

    @Test("default privacy String interpolation redacts local form")
    func defaultPrivacyRedactsLocal() {
        let name = "alice"
        let msg: KernovaLogMessage = "hi \(name)"
        #expect(msg.localRendered == "hi <private>")
        #expect(msg.wireRendered == "hi alice")
    }

    // MARK: - Generic fallback (non-String types)

    @Test("private Int interpolation redacts local form via generic fallback")
    func privateIntRedactsLocal() {
        let n = 42
        let msg: KernovaLogMessage = "\(n, privacy: .private)"
        #expect(msg.localRendered == "<private>")
        #expect(msg.wireRendered == "42")
    }

    @Test("public Bool interpolation renders cleartext via generic fallback")
    func publicBoolRendersInBothForms() {
        let flag = true
        let msg: KernovaLogMessage = "\(flag, privacy: .public)"
        #expect(msg.localRendered == "true")
        #expect(msg.wireRendered == "true")
    }

    // MARK: - Mixed interpolations

    @Test("mixed public/private interpolations redact selectively")
    func mixedInterpolationsRedactSelectively() {
        let n = 42
        let secret = "secret"
        let msg: KernovaLogMessage = "\(n, privacy: .public)=\(secret, privacy: .private)"
        #expect(msg.localRendered == "42=<private>")
        #expect(msg.wireRendered == "42=secret")
    }

    // MARK: - String literal init

    @Test("string literal init produces identical local and wire forms")
    func stringLiteralInit() {
        let msg: KernovaLogMessage = "no interpolation here"
        #expect(msg.localRendered == "no interpolation here")
        #expect(msg.wireRendered == "no interpolation here")
    }

    // MARK: - Empty string

    @Test("empty string literal produces empty local and wire forms")
    func emptyStringLiteral() {
        let msg: KernovaLogMessage = ""
        #expect(msg.localRendered == "")
        #expect(msg.wireRendered == "")
    }

    // MARK: - Literal segments preserved

    @Test("literal segments adjacent to redacted interpolation are preserved")
    func literalSegmentsPreserved() {
        let value = "secret"
        let msg: KernovaLogMessage = "prefix \(value, privacy: .private) suffix"
        #expect(msg.localRendered == "prefix <private> suffix")
        #expect(msg.wireRendered == "prefix secret suffix")
    }
}
