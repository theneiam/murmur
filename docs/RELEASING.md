# Building and publishing a Murmur release

A release is an explicitly authorized GitHub release containing a Developer
ID-signed, notarized and stapled DMG. Building an artifact is not permission
to commit, push, tag or publish it. Follow the working agreements in
[AGENTS.md](../AGENTS.md).

## Prerequisites

All builds need Apple Silicon, macOS 14+, Xcode 16+, XcodeGen and SwiftFormat.
Generate the ignored Xcode project with `xcodegen generate`. Development
signing uses ignored `Config/Local.xcconfig`; copy the example and add your
team. Do not set the team only in Xcode's UI or in `project.yml`.

The maintainer's release machine also needs:

- A **Developer ID Application** certificate and private key in the login
  keychain. `security find-identity -v -p codesigning` must list it. The
  maintainer's team is `55GBH53Y3N`; the private key exists only on that Mac
  and is backed up as a `.p12`, not recoverable by downloading the certificate.
- The **`murmur-notary`** notarytool keychain profile.
  `xcrun notarytool history --keychain-profile murmur-notary` checks access.
  Create a profile on a new release machine with an Apple ID app-specific
  password, for example:

  ```bash
  xcrun notarytool store-credentials "murmur-notary" \
    --apple-id you@example.com --team-id XXXXXXXXXX --password xxxx-xxxx-xxxx-xxxx
  ```

Without those release credentials, contributors can build/test and create an
unsigned development DMG with `scripts/make-dmg.sh`; they cannot produce the
published notarized release. `SKIP_NOTARIZE=1` still requires a signing
identity: it creates a signed but unnotarized test build.

## Source and verification gates

These are required procedural gates. The current release script does not
enforce every gate; executable enforcement is tracked as MUR-018 in
[ROADMAP.md](ROADMAP.md). Never infer a gate passed merely because the script
finished.

1. Decide the version: patch for bug fixes/internal changes; minor for a new
   compatible user-facing feature. Move *Unreleased* to a dated changelog
   section and leave a new empty *Unreleased* section. Update comparison links
   and `MARKETING_VERSION` in `project.yml`, the version source of truth.
2. Run the complete tests, format lint and relevant manual checks in
   [TESTING.md](TESTING.md). Identify the actual binary tested. Resolve
   failures before requesting the owner's commit/push approval.
3. Commit the intended source only when authorized. The release must be built
   from a **clean checkout of that exact commit**, including no untracked
   source files. `git status --porcelain` must print nothing. Ignored generated
   project/build output is expected. Do not discard another contributor's
   pending work to make this pass; use a separate clean checkout if necessary.
4. Record the source commit and intended version for the rest of the run:

   ```bash
   MURMUR_RELEASE_COMMIT=$(git rev-parse HEAD)
   MURMUR_RELEASE_VERSION=X.Y.Z
   ```

   Replace `X.Y.Z` with the approved version. Confirm it agrees with
   `project.yml`. Do not edit source, switch branches or accept unrelated
   changes while the artifact is being built.
5. After the authorized push, require **Build & test** and **Format lint** to
   be green for `MURMUR_RELEASE_COMMIT` before publication. Inspect the run's
   SHA, not merely the latest green badge. CI is configured for pushes to
   `main` and pull requests; a tag alone does not trigger those jobs. Owner
   branch-protection exemptions do not waive this publication gate.

## Build and link the artifact to the source

From the clean source checkout:

```bash
TEAM_ID=55GBH53Y3N NOTARY_PROFILE=murmur-notary scripts/release.sh
```

The script regenerates the project, archives Release/arm64, exports with the
Developer ID method, verifies the app signature, notarizes/staples the app,
builds and **signs the DMG itself**, then notarizes/staples it and runs
Gatekeeper assessment. Output: `build/release/Murmur-X.Y.Z.dmg`. Notarization
usually dominates the elapsed time; do not publish an unfinished artifact.

The DMG signature matters: notarizing an unsigned DMG is insufficient for
Gatekeeper's disk-image assessment. Keep both app and DMG signing and
notarization in the script. `VERSION` can override the marketing version for
test builds; published builds must agree with the approved source version.
The script stamps a timestamp build number unless `BUILD_NUMBER` is provided.
It replaces `build/release/`, leaving the debug `build/DerivedData/` separate.

After the build, check the checkout is still clean and HEAD has not changed:

```bash
git status --porcelain
test "$(git rev-parse HEAD)" = "$MURMUR_RELEASE_COMMIT"
printf '%s\n' "$MURMUR_RELEASE_COMMIT" > build/release/SOURCE_COMMIT.txt
shasum -a 256 "build/release/Murmur-$MURMUR_RELEASE_VERSION.dmg"
```

Require empty status output and a successful SHA comparison. Record the DMG
checksum, source SHA, version/build and verification results in the release
notes. `SOURCE_COMMIT.txt` is a build provenance record, not an embedded app
attestation; the clean-tree and unchanged-HEAD checks establish its linkage.
Do not claim reproducibility from a hash alone.

## Tag and publish

After artifact verification and the owner's explicit authorization, create
an annotated `vX.Y.Z` tag on the recorded source commit and push it. Verify
the remote tag resolves to that commit. Do not retarget an existing public
release tag to hide a failed build. Prepare release notes as a file with
real newlines, the source SHA and DMG checksum.

```bash
gh release create "v$MURMUR_RELEASE_VERSION" \
  "build/release/Murmur-$MURMUR_RELEASE_VERSION.dmg" \
  build/release/SOURCE_COMMIT.txt \
  --repo theneiam/murmur --verify-tag \
  --title "Murmur $MURMUR_RELEASE_VERSION" --notes-file /path/to/release-notes.md --latest
```

Publication requires the clean-source, artifact/signature and exact-commit
CI gates above. A prior approval to implement or review a feature is not
approval to publish a release.

## Verify the published result

- The release page has the intended version, notes and asset; `releases/latest`
  resolves to the new tag.
- The tag's commit matches `SOURCE_COMMIT.txt` and the green CI run.
- Download the DMG through `releases/latest/download/`, compare SHA-256 with
  the local artifact, and check signing/Gatekeeper on that downloaded copy.
- Launch the release after quitting another Murmur. Verify permissions and a
  real dictation; signature-bound macOS grants can differ from a debug build.

## SSH authentication quirk

The agent shell's launchd `ssh-agent` can have no identities even while the
owner's terminal can push. If an already-authorized SSH push fails with
`Permission denied (publickey)`, HTTPS through existing `gh` credentials
works without changing Git configuration:

```bash
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    push https://github.com/theneiam/murmur.git main vX.Y.Z
git update-ref refs/remotes/origin/main <verified-remote-main-sha>
```

Substitute the approved tag and the verified remote `main` SHA. Do not use a
locally assumed SHA to conceal divergence. This fallback does not authorize
an otherwise unapproved push.
