# AI Coding Workflow Manager

A Codex Skill for installing and maintaining a **personal, local-only** AI coding workflow in an existing Git checkout.

- Quick / Standard / Spec routing, project validation, and evidence reporting.
- OpenSpec integration and official Superpowers plugin discovery.
- Local Codex Hook and read-only reviewer templates.
- Safe install, update, audit, and uninstall with checksum-based ownership checks.
- Documentation comments for every new or modified property and method; Chinese by default.

## Install the Skill for your user

```sh
npx skills add rangoj/ai-coding-workflow-manager --skill ai-coding-workflow-manager -a codex -g
```

This installs the Skill for your user. It does not install the workflow into a business project until you ask it to. The public repository can also be discovered through the [Skills directory](https://skills.sh/); indexing depends on that service.

## Local installation

Install this Skill in Codex, then ask it to install the workflow in your target project. The manager can also be run directly from this repository:

```sh
ruby scripts/workflow_manager.rb install --target /absolute/project --local
ruby scripts/workflow_manager.rb audit --target /absolute/project
ruby scripts/workflow_manager.rb update --target /absolute/project
ruby scripts/workflow_manager.rb uninstall --target /absolute/project
```

Uninstall previews changes unless `--apply` is supplied. The target must be an existing Git repository root. Install requires Git and Ruby. Complete project adaptation additionally requires supported Node.js, OpenSpec, the official Superpowers plugin, and verified project validation commands. See [SKILL.md](SKILL.md) for the complete process.

Installed workflow files use `.git/info/exclude`. The manager does not change the shared `.gitignore`, stage, commit, or automatically untrack files. Existing project instructions and conflicting configuration are preserved. Each teammate installs independently. The Skill's own source repository remains separately versioned and distributable.

Project Hooks require repository trust and explicit approval. They are local assistance, not CI enforcement. Reviewer acknowledgements and harness text are supplied evidence, not proof that a review or test ran.

## Build the directory plugin

```sh
python3 scripts/build_plugin.py
```

The command creates a ZIP and SHA-256 file in the sibling `releases/` directory. The plugin includes this Skill under `skills/ai-coding-workflow-manager/`, an MIT license, listing metadata, and a square SVG icon. It requires local desktop execution. Hook files inside the Skill are installation templates; the plugin does not register lifecycle hooks.

Upload the `*-plugin.zip` to the [OpenAI plugin submission portal](https://platform.openai.com/plugins). A verified publishing identity and submission permissions are required. Automated scans and directory review determine eligibility; a local package is not a published listing.

## 验证与许可

```sh
ruby scripts/workflow_manager_test.rb
ruby assets/generic/Scripts/ai_workflow_test.rb
```

本工具安装到业务项目后的文件仅在本机使用，不随项目提交。源码本身按 [MIT License](LICENSE) 开源。
