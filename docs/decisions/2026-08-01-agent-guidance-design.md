# Agent guidance synchronization

## Goal

Keep public contributor instructions consistent across Codex and Claude while
recording the completed GetHog rename and the repository's committed-data
privacy boundary.

## Canonical guidance

`AGENTS.md` remains the single source of truth for repository structure,
commands, testing, privacy, and Git conventions. It will explicitly state:

- Use the current GetHog and GetHogKit names throughout.
- Automated tests, UI tests, screenshots, fixtures, demos, documentation, and
  examples contain deterministic synthetic data only.
- Automated UI tests run through demo transport and never access a live tenant.
- Explicitly authorized manual simulator testing may use a developer PAT, but
  the credential and live values must never be printed, logged, committed,
  screenshotted, or used to generate fixtures.
- Manual API exploration may retain only public schema facts, recreated with
  fictional values and reserved example domains.
- Preserve the multi-commit history and unrelated worktree changes; do not
  rewrite history, configure a remote, or push without explicit authorization.

## Claude compatibility

`CLAUDE.md` will be a committed public file that imports `AGENTS.md` and tells
Claude to treat it as canonical. It will not duplicate repository rules.

## Publication gate

`scripts/verify-public-tree` will stop classifying `CLAUDE.md` as an internal
artifact. Because Markdown already belongs to the scanned public inventory,
the file will still receive legacy-name, credential, local-path, email, and
privacy checks. Existing internal-artifact self-test coverage remains provided
by the intentionally forbidden private planning path.

## Persistent memory

An ad-hoc Codex memory extension will record the completed public GetHog rename,
along with the canonical synthetic-only boundary and the distinction between
automated demo tests and authorized manual PAT-backed validation. The extension
will supersede older rename-in-progress wording without editing generated memory
files directly.

## Verification

Run the verifier self-test, the strict publication verifier, `git diff --check`,
and a focused scan for stale names. Commit locally with the configured author
identity and SSH signature. Do not push.
