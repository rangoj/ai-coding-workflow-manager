# Project Adaptation

Adapt only from repository evidence. Read root instructions first, then inspect
the smallest set of manifests, scripts, and module docs needed for configuration.

## Inspection Checklist

1. Identify source, test, documentation, generated, dependency, infrastructure,
   persistence, authentication, payment, device, and project-configuration paths.
2. Find existing fast checks, focused tests, module tests, builds, and broader
   validation commands. Prefer checked-in scripts or documented commands.
3. Add a required command only when project work cannot be validated without it.
4. Register generated outputs only when authoritative sources and a deterministic
   `verify` or check-mode command both exist.
5. Preserve existing `.codex` files. A differing file is a conflict requiring
   explicit reconciliation, not permission to replace it.
6. Preserve an existing `AGENTS.md`. When the manager created one, replace only
   generic project-context statements with facts verified from the repository.

## Route Guidance

- Quick: documentation-only paths with no runtime, resource, dependency,
  configuration, or generated behavior.
- Standard: bounded changes in one ordinary module.
- Spec: shared infrastructure, public contracts, security, authentication,
  payment, persistence/migration, concurrency, device/hardware, deployment,
  dependencies, generated sources, or project/build configuration.

For Spec, OpenSpec owns proposal, requirements, design, and tasks. Superpowers
supplies applicable execution methods. Never maintain two authoritative plans.

Use anchored path expressions where possible. Keyword expressions are a safety
net, not a replacement for known sensitive directories. Routes may upgrade but
must not downgrade below the computed minimum.

## Validation Commands

Each command must already be supported by the project and run non-interactively.
Commands are parsed as argument vectors, so pipes, redirections, `&&`, and
substitutions are unsupported. Wrap complex behavior in a checked-in script.

Standard commands provide meaningful coverage for ordinary runtime changes.
Spec commands are additional broader or sensitive checks; Spec runs both lists.
An empty command list is not success and is reported as `UNVERIFIED`.

## Local Installation Boundary

Keep installed workflow definitions, local OpenSpec artifacts, and generated
OpenSpec Codex Skills out of project commits using the manager-owned block in
`.git/info/exclude`. Do not edit `.gitignore`, global ignore settings, or unrelated
exclude rules. Do not ignore all of `.codex/` or `.agents/`. Preserve existing
project-owned instructions and shared configurations; a differing target is a
conflict. The manager excludes only a generated `AGENTS.md` it owns.

Tracked files are not hidden by ignore rules. Installation or migration stops
and lists tracked workflow files; the user must decide how to remove shared
workflow files through the repository's normal Git process. Do not run
`git rm --cached`, stage, or commit automatically. `update` can migrate an
untracked portable installation by adding local rules.

Each teammate installs independently. Audit after installation, adaptation,
and local Git metadata changes. Uninstall removes only safe managed files and
retains ignore protection when customized or external files remain.
