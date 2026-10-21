# OpenSpec And Superpowers

Use this reference only while installing, updating, auditing, or explaining the
two external integrations.

## OpenSpec

Authoritative source: <https://github.com/Fission-AI/OpenSpec>

1. Run `node --version`. Require Node.js 20.19.0 or newer. When missing or older,
   stop; do not install Node or change the user's version manager.
2. Run `openspec --version`.
3. When the CLI is missing, select an already available global package manager,
   preferring npm. Show the exact command and obtain confirmation immediately
   before running it:

   ```bash
   npm install -g @fission-ai/openspec@latest
   ```

   Do not use `sudo`, edit shell profiles, or improvise around PATH failures.
4. From the target Git root, initialize Codex non-interactively:

   ```bash
   openspec init --tools codex --profile core --no-copilot-cloud
   ```

5. Verify `openspec/config.yaml` and the configured
   `.agents/skills/openspec-*/SKILL.md` files. Run `openspec update` after CLI
   upgrades or workflow-manager updates.
6. In Codex invoke generated Skills such as `$openspec-propose` and
   `$openspec-apply-change`, not `/opsx:*`. Before archiving, run
   `openspec validate <change>` and retain its result as validation evidence.

Keep local `openspec/`, `.agents/skills/openspec-*`, and OpenSpec's
`.agents/skills/.openspec-target` ownership marker ignored through the manager's
`.git/info/exclude` block. Do not commit them. Each team member initializes their
own OpenSpec installation. If the project already tracks these paths, stop and
report the conflict rather than modifying or untracking shared artifacts.
OpenSpec owns these outputs; the manager audits but never edits or removes them.

## Superpowers

Authoritative source: <https://github.com/obra/superpowers>

For Codex App, install Superpowers from **Plugins** in the sidebar using the
official Codex plugin marketplace. For Codex CLI, open `/plugins`, search for
`superpowers`, and select **Install Plugin**. Do not clone or vendor the upstream
repository into a project.

After installation, start a new task and verify that the `using-superpowers`
Skill is discoverable. The project `doctor` searches the Codex plugin cache.
Superpowers is installed separately on each device and is not committed into
the project. Missing discovery is `UNVERIFIED`, not `PASS`.

## Responsibility Map

- OpenSpec: durable proposal, requirements/scenarios, design, task list, change
  verification, and archive.
- Superpowers: brainstorming, TDD, systematic debugging, review discipline, and
  verification-before-completion.
- Workflow manager: route selection, local gates, local Git isolation, integration
  checks, and final evidence status.

For Spec work, OpenSpec tasks are the canonical plan. Apply Superpowers methods
to those tasks without generating a second competing plan.
