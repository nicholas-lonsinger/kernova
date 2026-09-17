# RELEASING.md

Read this when cutting a release; the reader is the maintainer, at the Mac holding the signing identities, and each step names the file that explains its mechanism.

1. Bump `KERNOVA_MARKETING_VERSION` in `Config/Base.xcconfig`.
2. Regenerate both wizard catalogs, `swift Tools/regen-restore-image-catalog.swift` and `swift Tools/regen-linux-image-catalog.swift`, and commit what changed.
3. Re-read README.md's Features section against what this release ships and correct it — nothing else re-checks it.
4. In Xcode, **Product → Archive** on the Kernova scheme.
5. Distribute, in one lane or both:
   - **TestFlight:** **Distribute App → App Store Connect → Upload**; the build appears in TestFlight.
   - **Developer ID:** **Distribute App → Direct Distribution → Export**. Check the exported app, and the agent inside `Kernova.app/Contents/Resources/KernovaMacOSAgent.dmg` — why that one needs its own look is in `Config/Targets/KernovaMacOSAgent.xcconfig`. Then `ditto -c -k --keepParent Kernova.app Kernova-<version>.zip` and send the zip to its recipients.
