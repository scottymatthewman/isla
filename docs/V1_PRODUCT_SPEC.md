# Isla v1 Product Specification (macOS)

This is the original v1 design. The app now organizes secrets by workspace; the earlier project layer was folded into workspaces. Where this document and the code disagree, the code is the source of truth.

## 1) Product Intent

Isla is a macOS app for indie and solo developers to securely store, organize, and use API keys and related secrets with minimal friction.

Core value proposition:
- Keep secrets secure by default
- Make everyday secret tasks one click (`copy`, `edit`, `rotate`)
- Reduce setup toil via `.env` paste import
- Organize secrets by workspace and project

## 2) Target User

Primary:
- Solo developers
- Indie hackers
- Small founders who work across multiple products and APIs

User problems:
- Secrets scattered across `.env` files, notes, and dashboards
- Repetitive copy/paste and key management overhead
- No simple local-first secret manager built for dev workflows

## 3) Platform and Technical Direction

- Platform: macOS only (v1)
- UI framework: SwiftUI
- Storage:
  - Secret values: encrypted and persisted securely with Keychain-backed approach
  - Non-sensitive metadata: local persistence (Core Data or SQLite-backed model)
- App behavior:
  - Local-first
  - No cloud sync in v1
  - No telemetry containing secret values

## 4) Scope

### In Scope (v1)
- Create/save secrets
- Edit secret metadata and value
- Single-click copy of secret values
- Paste `.env` file contents and import parsed entries
- Organize by workspaces and projects
- Basic rotate/refresh action framework with manual and provider-specific paths

### Out of Scope (v1)
- Team collaboration and multi-user permissions
- Cloud sync
- CLI integration
- Secret scanning from repositories
- Full provider rotation automation for every API provider

## 5) Information Architecture

- Workspace
  - Contains projects
- Project
  - Contains secrets
- Secret
  - Key/value plus metadata (environment, tags, provider, notes, timestamps)

Sidebar structure:
- All Workspaces
  - Workspace A
    - Project 1
    - Project 2
  - Workspace B

Main panel:
- Secret list with quick actions

Detail panel / modal:
- Secret details and editing form

## 6) Functional Requirements

### 6.1 Secrets CRUD

User can:
- Create a secret with required fields: `key`, `value`, `project`
- Optionally set: `environment`, `provider`, `tags`, `notes`
- Edit any field
- Delete a secret (with confirmation)

Validation:
- `key` required
- `value` required
- Prevent duplicate key collisions per project+environment unless user confirms overwrite

### 6.2 Copy Secret

From list and detail views:
- Single click `Copy`
- Secret value copied to clipboard
- Show transient success feedback
- Clipboard auto-clear after configurable timeout (default 45s)

### 6.3 Import from `.env` Paste

Input:
- Raw pasted text from `.env` content

Parser behavior:
- Accept lines in `KEY=VALUE` form
- Ignore empty lines and comments (`# ...`)
- Preserve quoted values and escaped characters
- Handle duplicate keys with preview and conflict controls

Import flow:
1. Paste content
2. Parse and preview rows
3. Choose target workspace/project/environment
4. Resolve conflicts (`skip`, `overwrite`, `keep both with suffix`)
5. Save and show import summary

### 6.4 Rotate / Refresh

For each secret:
- `Rotate` button in list and detail
- If provider supports API-based rotation adapter in v1:
  - Execute adapter
  - Update stored value and `lastRotatedAt`
  - Show status
- If unsupported:
  - Offer guided manual flow:
    - Open provider dashboard link
    - Prompt user to paste new value
    - Save and timestamp rotation

v1 rotation adapter recommendation:
- Start with 1-2 providers only (e.g., GitHub token flow may be manual; choose one API that supports clean key lifecycle)

### 6.5 Workspaces & Projects

User can:
- Create/rename/delete workspaces
- Create/rename/delete projects inside workspace
- Move secret between projects
- Filter secrets by workspace/project/environment/tag

## 7) Security & Privacy Requirements

Must-have:
- Secret values encrypted at rest using secure key management strategy
- Never log raw secret values
- Mask values by default in UI
- Require re-auth for reveal/copy after idle timeout
- Auto-lock app after inactivity (default 5 min)
- Clipboard auto-clear

Should-have:
- Export without values by default
- Optional secure delete semantics for local persistence cleanup

Threat model assumptions:
- v1 protects against accidental exposure and local-at-rest compromise scenarios
- v1 does not claim HSM-grade enterprise controls

## 8) UX Specification (Screen by Screen)

### 8.1 On First Launch

- Empty state: "Create your first workspace"
- CTA: `New Workspace`
- Secondary CTA: `Import .env`

### 8.2 Main App Shell

Layout:
- Left sidebar: workspaces/projects
- Center: secret list
- Right panel or modal: secret details

Toolbar actions:
- `New Secret`
- `Import .env`
- Search field

### 8.3 Secret List

Columns:
- Key
- Environment
- Provider
- Updated
- Actions (`Copy`, `Rotate`, `Edit`)

Interactions:
- Single click row selects
- Keyboard shortcuts:
  - `cmd+c` copy selected secret value
  - `cmd+n` create secret
  - `cmd+f` focus search

### 8.4 Secret Detail/Edit

Fields:
- Key
- Value (masked with reveal toggle)
- Environment
- Provider
- Tags
- Notes

Actions:
- Save
- Copy
- Rotate
- Delete

### 8.5 Import Modal

Sections:
- Paste area
- Parsed preview table
- Conflict panel
- Destination selector (workspace/project/environment)
- Import summary

## 9) Data Model (v1)

Entities:

`Workspace`
- id (UUID)
- name (String)
- createdAt, updatedAt

`Project`
- id (UUID)
- workspaceId (UUID FK)
- name (String)
- createdAt, updatedAt

`Secret`
- id (UUID)
- projectId (UUID FK)
- key (String)
- encryptedValueRef (String / Keychain item id)
- environment (String)
- provider (String?)
- tags (String[] serialized)
- notes (String?)
- createdAt, updatedAt
- lastCopiedAt (Date?)
- lastRotatedAt (Date?)

`ImportJob` (optional lightweight log)
- id, sourceType, startedAt, completedAt, totalParsed, totalImported, totalSkipped

Uniqueness rule:
- Unique index on `(projectId, environment, key)` for metadata record

## 10) Non-Functional Requirements

- Performance:
  - List render under 100ms for 2,000 secrets
  - Import parse under 1s for 1,000 lines
- Reliability:
  - No data loss on app restart
  - Atomic save behavior for import batches
- Accessibility:
  - Keyboard-navigable primary flows
  - VoiceOver labels for all actionable controls

## 11) Edge Cases

- `.env` with malformed lines (surface line-level errors)
- Duplicate keys across different environments
- Multi-line values and quoted strings
- Very long values (JWT/private keys)
- Clipboard copy when app auto-lock triggers
- Deleting workspace/project with existing secrets (confirm + cascade rules)

## 12) Acceptance Criteria (MVP Exit)

- User can create workspace/project and add at least one secret
- User can paste `.env`, preview parse results, and import successfully
- User can copy secret value with one click and clipboard auto-clears
- User can edit and delete secrets
- User can trigger rotate flow (adapter or guided manual path)
- Secret values are never displayed in logs and are masked by default

## 13) Implementation Backlog (6 Weeks)

### Week 1: Foundations
- App shell (sidebar + list + detail skeleton)
- Data model and local metadata persistence
- Keychain integration spike

### Week 2: Secrets CRUD
- Create/edit/delete forms
- Mask/reveal logic
- Search/filter in list

### Week 3: Copy + Locking
- One-click copy from list/detail
- Clipboard auto-clear timer
- Auto-lock + re-auth flow

### Week 4: `.env` Import
- Parser implementation
- Import preview UI
- Conflict resolution and batch save

### Week 5: Workspaces/Projects + Rotation
- Full workspace/project management
- Rotation action framework
- First provider/manual guided rotation flow

### Week 6: Hardening + QA
- Error handling polish
- Accessibility and keyboard shortcuts
- Regression tests and release prep

## 14) Test Plan

Unit tests:
- `.env` parser (quotes, comments, malformed lines, duplicates)
- Uniqueness/overwrite logic
- Clipboard timeout behavior

Integration tests:
- Create/edit/delete secret lifecycle
- Import 100+ secrets and verify persistence
- Lock/re-auth gating for reveal/copy

Manual QA:
- End-to-end from fresh install to daily workflow
- Crash/restart resilience checks

## 15) Future Roadmap (Post-v1)

- Encrypted sync across devices
- Team sharing and permissions
- CLI access (`isla secrets get ...`)
- Git repo scanner for missing/rotated keys
- More provider rotation adapters
