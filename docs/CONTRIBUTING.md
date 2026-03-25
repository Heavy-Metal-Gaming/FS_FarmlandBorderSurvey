# Contributing to FS Property Borders

Thank you for your interest in contributing! This document outlines the process for submitting bug fixes, translations, and new features.

## General Workflow

1. **Open an issue first** — every contribution starts with a GitHub issue.
2. **Get approval** (for features) — new feature work requires an approved RFE before a pull request will be accepted.
3. **Submit a pull request** — reference the issue number in your PR description.

> **Pull requests without a corresponding approved issue will be automatically rejected.**

## Bug Fixes

1. Open a [Bug Report](../../issues/new?template=bug_report.yml) issue describing the problem.
2. Fork the repository and create a branch from `main`.
3. Make your fix and test it in-game.
4. Submit a pull request referencing the bug report issue (e.g., `Fixes #42`).

### Bug fix PR checklist

- [ ] Links to a bug report issue
- [ ] Tested in single-player
- [ ] Tested in multiplayer (if the fix touches networking or synced settings)
- [ ] No unrelated changes included

## Translations

1. Open a [Translation Request](../../issues/new?template=translation_rfe.yml) issue indicating the language you want to add.
2. Copy `FS25_Src/l10n/l10n_template.xml` to `FS25_Src/l10n/l10n_XX.xml` (see the template header for language codes).
3. Translate all `text=""` values. **Do not** change `name=""` attributes.
4. Preserve `%d` and `%s` format specifiers exactly where they appear.
5. Ensure the file is saved as **UTF-8**.
6. Submit a pull request referencing your translation request issue.

### Translation PR checklist

- [ ] Links to a translation request issue
- [ ] File is named `l10n_XX.xml` with correct language code
- [ ] All `text=""` values are filled in (no empty strings)
- [ ] Format specifiers (`%d`, `%s`) are preserved
- [ ] File encoding is UTF-8
- [ ] No other files modified

## New Features

New features require prior approval to ensure they align with the mod's direction and scope.

1. Open a [Feature Request](../../issues/new?template=feature_rfe.yml) issue describing your proposed feature.
2. **Wait for the issue to be labeled `approved`** by a maintainer.
3. Only after approval: fork the repository, implement the feature, and submit a pull request referencing the approved issue.

> PRs for features without an approved RFE issue will be closed without review.

### Feature PR checklist

- [ ] Links to an **approved** feature request issue
- [ ] Tested in single-player
- [ ] Tested in multiplayer (if applicable)
- [ ] New user-facing strings added to `l10n_en.xml`, `l10n_de.xml`, and `l10n_template.xml`
- [ ] No unrelated changes included

## Code Style

- Follow existing Lua conventions in the codebase (PascalCase for classes, camelCase for locals/functions).
- Use `Logging.info()` / `Logging.warning()` for log output — never `print()`.
- Add doc comments (`---@param`, `---@return`) to public functions.

## Commit Messages

- Use clear, concise commit messages.
- Reference issue numbers where relevant (e.g., `Fix border flicker on steep terrain (#42)`).

## Questions?

If you're unsure about anything, open a [Discussion](../../discussions) or comment on the relevant issue before starting work.
