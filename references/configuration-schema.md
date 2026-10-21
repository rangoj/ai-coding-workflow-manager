# Configuration Schema

`.ai-workflow/config.yml` uses schema version 1:

```yaml
version: 1
project:
  name: Example
routes:
  quick:
    allowed_paths: [AGENTS.md, WORKFLOW.md]
    allowed_prefixes: [Docs/, .ai-workflow/templates/]
  spec:
    path_patterns: []
    keyword_patterns: []
  reviewers:
    standard: [reviewer]
    spec: [reviewer, test_reviewer]
doctor:
  required_commands: [git, ruby]
  optional_commands: []
  required_paths: [AGENTS.md]
integrations:
  openspec:
    required: true
    config_path: openspec/config.yaml
    skill_root: .agents/skills
    target_marker: .agents/skills/.openspec-target
    required_skills: [openspec-propose, openspec-apply-change]
  superpowers:
    required: true
    bootstrap_skill: using-superpowers
validation:
  standard_commands: []
  spec_commands: []
```

Paths are repository-relative. Route patterns are Ruby regular expressions.
Commands are tokenized with `Shellwords`; they are not evaluated by a shell.
Standard commands run for Standard and Spec. Spec commands run only for Spec.
The target marker identifies OpenSpec-owned generated Skills. The shipped
configuration lists every required core-profile OpenSpec Skill;
the shortened example above shows the field shape only.

Spec validation also requires `--openspec-change NAME`. The named active change
must contain `proposal.md`, `design.md`, `tasks.md`, and at least one Markdown
file below `specs/`; all must be non-empty. The validator then runs
`openspec validate NAME`. Supplying the name acknowledges approval, which is a
human decision and is not inferred from file contents.

`.ai-workflow/generated-files.yml` uses:

```yaml
version: 1
files:
  - output: path/to/generated.file
    sources: [path/to/source.file]
    verify: ruby Scripts/generator.rb --check
```

Each output needs a source. When a changed source has no `verify` command,
validation reports `UNVERIFIED`. The Codex Hook blocks direct output edits and
permits the registered verification command.
