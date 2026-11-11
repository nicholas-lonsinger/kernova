# RELEASING.md

Read this when cutting a release; the reader is the maintainer, at the Mac holding the signing identities, and each step names the file that explains its mechanism.

1. Bump `KERNOVA_MARKETING_VERSION` in `Config/Base.xcconfig`.
2. Regenerate both wizard catalogs, `swift Tools/regen-restore-image-catalog.swift` and `swift Tools/regen-linux-image-catalog.swift`, and commit what changed.
3. Re-read README.md's Features section against what this release ships and correct it — nothing else re-checks it.
4. In Xcode, **Product → Archive** on the Kernova scheme.
5. Distribute, in one lane or both:
   - **TestFlight:** **Distribute App → App Store Connect → Upload**; the build appears in TestFlight.
   - **Developer ID:** **Distribute App → Direct Distribution → Export**. Check the exported app, and the agent inside `Kernova.app/Contents/Resources/KernovaMacOSAgent.dmg` — why that one needs its own look is in `Config/Targets/KernovaMacOSAgent.xcconfig`. Then `ditto -c -k --keepParent Kernova.app Kernova-<version>.zip` and send the zip to its recipients.
6. In `CHANGELOG.md`, rewrite the top section's first line to say where the release went, with its build number and date, and open `## <next version>` above it for the changes that follow. The build number is the archived commit's count, so this commit comes after the archive.
