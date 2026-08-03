# AGENTS.md

## Purpose
This file orchestrates six specialized skills so Grok Build runs them in the correct
order for any feature request, bug fix, or UI change, across iOS, iPadOS, macOS, and Windows.

## Skill pipeline (run in this order for any feature/fix request)

1. **ui-ux-meticulous** — Design phase. Triggered first if the request involves any
   visual/UI component. Produces the wireframe/design rationale and platform-correct
   UI code (SwiftUI/UIKit/AppKit/WinUI3).
2. **safe-feature-dev** — Implementation phase. Takes the design output (or works alone
   if no UI is involved) and implements the feature/fix with minimal blast radius,
   investigating callers and existing tests before touching code.
3. **test-writer-qa** — Verification phase. Writes unit/integration/UI tests covering
   happy path, edge cases, and failure path for whatever safe-feature-dev just built.
   Confirms tests fail on broken code and pass on correct code.
4. **code-reviewer** — Review phase. Reviews the implementation and tests from steps 2-3
   across correctness, readability, architecture, security, and performance axes.
   Blocks progression if severity is Blocker/Major.
5. **security-auditor** — Security phase. Runs OWASP Top 10:2026-based audit on any code
   touching auth, input handling, APIs, secrets, or dependencies. Blocks progression if
   Critical/High findings exist.
6. **performance-optimizer** — Performance phase. Profiles the finished feature for
   platform-specific bottlenecks (SwiftUI re-renders, WinUI frame timing, memory leaks)
   before final sign-off.

## Handoff rules

- Skip step 1 (ui-ux-meticulous) automatically if the request has no visual/UI component
  (e.g. pure backend logic, data layer changes).
- Do NOT proceed from step 2 to step 3 until safe-feature-dev's own workflow checklist
  (tests added/updated, tests run, breaking-change flag) is complete.
- Do NOT proceed from step 4 to step 5 if code-reviewer's verdict is "Request changes."
  Route back to safe-feature-dev to fix flagged issues first.
- Do NOT ship/merge if security-auditor's verdict is "Do not deploy." Route back to
  safe-feature-dev immediately, regardless of how far along the pipeline is.
- performance-optimizer runs last because profiling a feature before it's functionally
  and securely correct wastes effort on code that may still change.

## Final report format

At the end of the full pipeline, produce one consolidated summary:

- [ ] Design rationale (if UI involved)
- [ ] What changed and why (files touched)
- [ ] Tests added and results (pass/fail)
- [ ] Code review verdict
- [ ] Security audit verdict
- [ ] Performance findings (if any)
- [ ] Overall status: Ready to merge / Needs follow-up / Blocked

## Project-specific settings (fill in per repo)

## Before any change
Run: [your test command, e.g. `swift test` / `dotnet test` / `npm test`]

## After any change
Run: [your lint/typecheck command] then re-run the full test suite.

## Never touch without asking
- /Auth/
- /Payments/
- Database migration files

## Project-specific settings (EQtargets Music iOS)

### Before any change
Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodebuild -scheme EQtargetsMusic -destination 'generic/platform=iOS Simulator' -derivedDataPath build build`

### After any change
Same build command; fix compile errors before continuing.

### Never touch without asking
- Signing / provisioning profiles
- Bundle identifier production release
