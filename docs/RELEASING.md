# RELEASING.md

Read this when cutting a release; the reader is the maintainer, at the Mac holding the signing identities.

1. Set `KERNOVA_MARKETING_VERSION` in `Config/Base.xcconfig` to `CHANGELOG.md`'s top heading.
2. Regenerate both wizard catalogs: `swift Tools/regen-restore-image-catalog.swift` and `swift Tools/regen-linux-image-catalog.swift`.
3. Correct README.md's Features section against `CHANGELOG.md`'s top section.
4. In Xcode, **Product → Archive** on the Kernova scheme, then **Distribute App → App Store Connect → Upload**.
5. In `CHANGELOG.md`, rewrite the top section's first line to say where the release went, with its build number and date, and open `## <next version>` above it. The build number is the archived commit's count, so this commit comes after the archive.
