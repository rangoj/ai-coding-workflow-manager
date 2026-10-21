---
name: ai-coding-workflow-manager
license: MIT
description: Install, adapt, update, audit, or safely remove a local-only AI Coding workflow with AGENTS.md bootstrapping, Quick/Standard/Spec routing, OpenSpec, Superpowers, Codex Hooks, reviewers, and doctor/validate commands. Use when installing a personal Git-ignored workflow in a project or maintaining an existing installation; do not use for ordinary feature implementation.
---

# AI Coding Workflow Manager

Manage a personal AI coding workflow installed in a local project checkout.
Installed workflow files stay out of project commits through `.git/info/exclude`;
each team member installs and configures the workflow independently.
Use project inspection for configuration judgment and the bundled Ruby manager
for deterministic file lifecycle and local-isolation checks. The Skill's own
source repository can still be published and versioned independently.

## Boundaries

- Support local-only installation. Default install and `install --local` are equivalent.
- Never change the project `.gitignore` or global Git ignore configuration.
- Manage only this tool's marked block in the Git-resolved `info/exclude`.
- Do not add CI, Git Hooks, `core.hooksPath`, commits, or staging.
- Create `AGENTS.md` only when the project lacks one. Never modify or
  replace an existing `AGENTS.md`.
- Ignore installed workflow files, local OpenSpec artifacts, and generated
  OpenSpec Codex Skills through the local exclude block. Do not ignore entire
  `.codex/` or `.agents/` directories, unrelated files, or an existing project-owned
  `AGENTS.md`. Never run `git rm --cached`, stage, or commit automatically.
- Ignore rules do not affect tracked files. Stop installation or migration when
  owned workflow files are already tracked and report the exact paths; preserve
  their contents and the Git index until the user handles their shared history.
- Do not overwrite a differing target file.
- Do not install Node.js, edit shell startup files, use `sudo`, or invent project
  validation commands.
- Ask immediately before globally installing the OpenSpec package. Stop on
  permission, PATH, or runtime-version problems.
- Install Superpowers only through the official Codex plugin marketplace; do
  not clone, vendor, or reproduce its third-party Skills.
- Keep project-specific facts in `.ai-workflow/config.yml`, not in the manager.
- Treat Codex Hooks as local assistance, not remote enforcement.
- Treat the install manifest as untrusted project input. Accept only version 1,
  valid SHA-256 checksums, and paths explicitly owned by this manager version.
- Keep the installed code-comment contract active. Every newly added or modified
  type member property and every method requires a concise documentation comment,
  including self-explanatory properties and simple methods. Use Chinese by
  default unless the user or repository instructions explicitly require another
  language. Preserve a repository's stricter comment rules and report conflicting
  higher-precedence instructions instead of silently weakening either rule.

## Commands

Run the manager relative to this Skill directory:

```bash
ruby scripts/workflow_manager.rb install --target /absolute/project --local
ruby scripts/workflow_manager.rb audit --target /absolute/project
ruby scripts/workflow_manager.rb update --target /absolute/project
ruby scripts/workflow_manager.rb uninstall --target /absolute/project
ruby scripts/workflow_manager.rb uninstall --target /absolute/project --apply
```

`uninstall` is a dry run unless `--apply` is supplied.

## Install And Adapt

1. Resolve the target to the root of an existing Git repository.
2. Read `AGENTS.md` and nearby instruction files when present.
3. Inspect repository languages, source roots, build manifests, existing
   scripts, test entry points, sensitive subsystems, and generated-file rules.
4. Read [project-adaptation.md](references/project-adaptation.md),
   [configuration-schema.md](references/configuration-schema.md), and
   [integrations.md](references/integrations.md).
5. Run `install --local`. Stop on conflicts; explain each conflict and do
   not delete or overwrite it automatically.
6. If the manager created `AGENTS.md`, adapt its project context without
   weakening the workflow contract. If `AGENTS.md` already existed, preserve it.
7. Confirm `WORKFLOW.md` requires concise comments for non-obvious logic, public
   contracts, state transitions, algorithms, compatibility reasons, and failure
   or recovery constraints. Every newly added or modified type member property
   and every method must have a concise documentation comment, using Chinese by
   default unless another language is explicitly required. Exclude local
   variables, parameters, temporary values, and untouched historical declarations.
   Do not turn declaration comments into line-by-line narration.
8. Adapt `.ai-workflow/config.yml` using only commands and paths verified from
   repository evidence. Register generated outputs only when their source and
   verification command are known.
9. Establish OpenSpec exactly as described in `integrations.md`. Initialize the
   core Codex profile with cloud setup disabled. Keep `openspec/` and
   `.agents/skills/openspec-*` locally ignored; each teammate initializes their
   own installation. Never modify a tracked shared OpenSpec setup to make it local.
10. Confirm the official Superpowers Codex plugin exposes `using-superpowers`.
   When absent, tell the user to install it from the Codex Plugins sidebar and
   stop with integration status `UNVERIFIED`.
11. Run `ruby Scripts/ai_workflow_test.rb`, `./Scripts/ai-workflow doctor`, and
   the manager `audit` command.
12. Report configured validation commands, `UNVERIFIED` items, and that the user
   must trust the repository and approve project Hooks in a new Codex task.

Do not declare adaptation complete while validation commands, OpenSpec, or
Superpowers remain unknown. Core file installation may be complete, but label
the full workflow `UNVERIFIED` and name each missing prerequisite.

## Route Integration

- Quick: no OpenSpec change. Use only lightweight applicable methods.
- Standard: OpenSpec is optional unless behavior or acceptance criteria are
  unclear. Use applicable Superpowers testing, debugging, review, and
  verification Skills.
- Spec: require an approved OpenSpec change before implementation and pass its
  name to `validate --openspec-change NAME`. Use OpenSpec artifacts as the one
  requirements/design/task source. Use Superpowers for execution technique;
  do not create a competing plan document. Supplying the name acknowledges the
  human approval; the validator checks non-empty artifacts and runs
  `openspec validate NAME`, but cannot infer stakeholder approval.

## Update

Run `update` and inspect its report. It adds `AGENTS.md` only when
missing and migrates legacy configuration with integration keys. The manager
replaces a managed file only when the target matches the previous installed
checksum. It preserves the project-owned configuration and reports locally
modified files. It migrates the manager's legacy personal exclude block and
recreates the local exclude block without changing user rules. Previously
portable files that are already tracked need a user-managed Git migration first;
ignore rules alone cannot remove them from future commits.
Run `openspec update`, then re-run tests, doctor, and audit.

## Audit

Use `audit` after installation, environment changes, or when local isolation is
in doubt. Resolve every `FAIL`. Configuration drift after project adaptation is
expected. Owned workflow and OpenSpec paths must be ignored and untracked;
missing local exclusion rules or tracked workflow files are a `FAIL`. An existing
project-owned `AGENTS.md` is preserved and excluded from ownership checks.
Never ask users to add the installed workflow files to Git.

## Uninstall

Run the dry run first. With `--apply`, remove only checksum-matching managed
untracked files. Remove the manager's local and legacy exclude blocks only when
no managed or external files remain; otherwise retain exclusion for preserved
local files and explain why. Tracked, staged, existing, or modified project-owned files are preserved and should be
removed through the normal Git workflow. OpenSpec and Superpowers remain
externally owned and are never deleted by the manager. Never remove project
code or unrelated `.codex` content.

## Completion Evidence

Return the operation, target root, conflicts, installed or preserved files,
workflow test result, doctor result, audit result, OpenSpec and Superpowers
status, validation-command coverage, local Git-isolation status, comment-language
and property/method comment review results, and remaining risks. Use `PASS`, `FAIL`, `WARN`, and
`UNVERIFIED` literally.
