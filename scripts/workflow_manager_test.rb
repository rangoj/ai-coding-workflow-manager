# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"

require_relative "workflow_manager"

class WorkflowManagerTest < Minitest::Test
  def setup
    @skill_root = File.expand_path("..", __dir__)
  end

  def with_repository(agents: true)
    Dir.mktmpdir("workflow-manager-test") do |root|
      system("git", "init", "-q", root)
      File.write(File.join(root, "AGENTS.md"), "# Project rules\n") if agents
      yield root
    end
  end

  def cli(output = StringIO.new, error = StringIO.new)
    [AIWorkflowManager::CLI.new(skill_root: @skill_root, output: output, error: error), output, error]
  end

  # 本机安装、审计、验证和卸载保持一致的文件所有权边界。
  def test_install_audit_and_uninstall_lifecycle
    with_repository do |root|
      manager, output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--local"]), error.string
      assert File.executable?(File.join(root, "Scripts/ai-workflow"))
      assert_equal "# Project rules\n", File.read(File.join(root, "AGENTS.md"))
      config = YAML.safe_load(File.read(File.join(root, ".ai-workflow/config.yml")), permitted_classes: [], aliases: false)
      assert_equal File.basename(root), config.dig("project", "name")
      assert_equal ["AGENTS.md"], config.dig("doctor", "required_paths")
      assert system("git", "-C", root, "check-ignore", "-q", "--no-index", "WORKFLOW.md")

      doctor_out, _doctor_err, doctor_status = Open3.capture3(File.join(root, "Scripts/ai-workflow"), "doctor", chdir: root)
      assert_equal 4, doctor_status.exitstatus
      assert_includes doctor_out, "No project validation command configured"
      assert_includes doctor_out, "openspec"
      assert_includes doctor_out, "superpowers"

      assert system("git", "-C", root, "add", ".")
      assert system(
        "git", "-C", root, "-c", "user.name=Workflow Test", "-c",
        "user.email=workflow@example.invalid", "commit", "-q", "-m", "workflow baseline"
      )
      quick_out, _quick_err, quick_status = Open3.capture3(File.join(root, "Scripts/ai-workflow"), "validate", "--route", "quick", chdir: root)
      assert_equal 0, quick_status.exitstatus, quick_out

      File.write(File.join(root, "source.rb"), "value = 1\n")
      standard_out, _standard_err, standard_status = Open3.capture3(
        File.join(root, "Scripts/ai-workflow"), "validate", "--route", "standard",
        "--harness-evidence", "focused check passed", "--reviewed-by", "reviewer", chdir: root
      )
      assert_equal 3, standard_status.exitstatus
      assert_includes standard_out, "No standard validation commands configured"
      FileUtils.rm_f(File.join(root, "source.rb"))

      auditor, = cli
      assert_equal 0, auditor.run(["audit", "--target", root])

      dry_runner, = cli
      assert_equal 0, dry_runner.run(["uninstall", "--target", root])
      assert File.exist?(File.join(root, "WORKFLOW.md"))

      remover, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      refute File.exist?(File.join(root, "WORKFLOW.md"))
      assert File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  # 克隆仅携带业务文件，团队成员需在自己的副本独立安装。
  def test_local_workflow_does_not_follow_project_clone
    with_repository(agents: false) do |root|
      File.write(File.join(root, "app.rb"), "value = 1\n")
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      assert system("git", "-C", root, "add", ".")
      assert system("git", "-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "app")
      assert_equal "app.rb\n", Open3.capture3("git", "-C", root, "ls-files").first
      Dir.mktmpdir("workflow-clone") do |parent|
        clone = File.join(parent, "project")
        assert system("git", "clone", "-q", root, clone)
        refute File.exist?(File.join(clone, "WORKFLOW.md"))
        refute File.exist?(File.join(clone, "AGENTS.md"))
        refute File.exist?(File.join(clone, "Scripts/ai-workflow"))
        independent, _out, error = cli
        assert_equal 0, independent.run(["install", "--target", clone]), error.string
        assert File.executable?(File.join(clone, "Scripts/ai-workflow"))
      end
    end
  end

  # 缺失的入口由本机安装生成并排除，卸载时可安全删除。
  def test_install_creates_and_manages_agents_when_missing
    with_repository(agents: false) do |root|
      manager, _output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--local"]), error.string
      agents = File.join(root, "AGENTS.md")
      assert File.file?(agents)
      assert_includes File.read(agents), File.basename(root)
      assert system("git", "-C", root, "check-ignore", "-q", "--no-index", "AGENTS.md")

      remover, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      refute File.exist?(agents)
    end
  end

  # 安装输出继续包含完整的工程约束，不因模式迁移丢失。
  def test_install_distributes_complete_engineering_guardrails
    with_repository do |root|
      manager, _output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--local"]), error.string

      workflow = File.read(File.join(root, "WORKFLOW.md")).gsub(/\s+/, " ")
      expected_guardrails = [
        "State assumptions, unresolved questions, and material trade-offs",
        "Write only the minimum code required by the current acceptance criteria",
        "Change only what the task requires",
        "Define observable success criteria before implementation",
        "Trust internal code contracts, type-system guarantees, and documented framework invariants",
        "Validate at actual system boundaries",
        "Do not add error handling, fallback behavior, optionality, nil checks, or validation for states proven impossible",
        "Never swallow errors",
        "Do not create a helper, utility, type, protocol, or abstraction for a single use",
        "Fail fast when an internal invariant is violated"
      ]

      expected_guardrails.each do |guardrail|
        assert_includes workflow, guardrail
      end
    end
  end

  # 安装输出和审查角色统一要求属性及方法备注，默认使用中文。
  def test_install_distributes_chinese_comment_contract
    with_repository(agents: false) do |root|
      manager, _output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--local"]), error.string

      normalize = ->(path) { File.read(File.join(root, path)).gsub(/\s+/, " ") }
      agents = normalize.call("AGENTS.md")
      workflow = normalize.call("WORKFLOW.md")
      task_contract = normalize.call(".ai-workflow/templates/task.md")
      verification_report = normalize.call(".ai-workflow/templates/verification-report.md")
      reviewer = normalize.call(".codex/agents/reviewer.toml")
      test_reviewer = normalize.call(".codex/agents/test-reviewer.toml")

      [agents, workflow, reviewer, test_reviewer].each do |contract|
        assert_includes contract, "every method"
        assert_includes contract, "Chinese by default"
        refute_includes contract, "not a requirement to comment every method"
        refute_includes contract, "do not require comments"
      end
      assert_includes workflow, "simple methods, getters and setters, initializers, and lifecycle methods"
      assert_includes workflow, "Do not retroactively comment untouched historical properties or methods"
      assert_includes workflow, "Missing, incorrect, misleading, or stale comments are correctness findings"
      assert_includes task_contract, "Property/method comment coverage"
      assert_includes verification_report, "Property/method comment review"
      assert_includes reviewer, "Do not request comments that merely translate code"
      assert_includes test_reviewer, "including simple methods and test methods"

    end
  end

  # 既有忽略项无需移除，安装也不改变共享 .gitignore。
  def test_install_preserves_existing_ignore_rules
    with_repository do |root|
      exclude = File.join(root, ".git/info/exclude")
      before = File.read(exclude) + "\n/WORKFLOW.md\n/private-notes/\n"
      File.write(exclude, before)
      File.write(File.join(root, ".gitignore"), "build/\n")
      manager, _output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--local"]), error.string
      assert File.read(exclude).start_with?(before)
      assert_equal "build/\n", File.read(File.join(root, ".gitignore"))
      FileUtils.mkdir_p(File.join(root, ".codex"))
      File.write(File.join(root, ".codex/unrelated.toml"), "value = true\n")
      refute system("git", "-C", root, "check-ignore", "-q", ".codex/unrelated.toml")
      refute system("git", "-C", root, "check-ignore", "-q", "AGENTS.md")
    end
  end

  # 项目已有入口不归本工具所有，其原有忽略状态保持不变。
  def test_install_preserves_existing_ignored_agents
    with_repository do |root|
      exclude = File.join(root, ".git/info/exclude")
      File.write(exclude, File.read(exclude) + "\n/AGENTS.md\n")
      manager, _output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--local"]), error.string
      assert_equal "# Project rules\n", File.read(File.join(root, "AGENTS.md"))
    end
  end

  # 已有团队入口不修改内容，也不取消 Git 跟踪。
  def test_install_preserves_tracked_agents
    with_repository do |root|
      system("git", "-C", root, "add", "AGENTS.md")
      manager, output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--local"]), error.string
      assert_includes output.string, "preserved existing AGENTS.md"
      assert_equal "# Project rules\n", File.read(File.join(root, "AGENTS.md"))
      assert_includes `git -C #{root} ls-files -- AGENTS.md`, "AGENTS.md"
    end
  end

  # 旧集成配置补齐必要键并保留项目选择。
  def test_update_migrates_legacy_configuration
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      config_path = File.join(root, ".ai-workflow/config.yml")
      config = YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false)
      config["integrations"].delete("superpowers")
      config["integrations"]["openspec"]["required_skills"] = %w[openspec-propose openspec-verify-change]
      config["doctor"]["required_commands"] -= %w[node openspec]
      config["doctor"]["required_paths"].delete("AGENTS.md")
      File.write(config_path, YAML.dump(config))

      updater, _output, error = cli
      assert_equal 0, updater.run(["update", "--target", root]), error.string
      migrated = YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false)
      assert migrated["integrations"].key?("openspec")
      assert migrated["integrations"].key?("superpowers")
      refute_includes migrated.dig("doctor", "required_commands"), "openspec"
      assert_includes migrated.dig("doctor", "required_paths"), "AGENTS.md"
      refute_includes migrated.dig("integrations", "openspec", "required_skills"), "openspec-verify-change"
      assert_includes migrated.dig("integrations", "openspec", "required_skills"), "openspec-apply-change"
    end
  end

  # 外部生成的 OpenSpec 文件也必须保持本机忽略。
  def test_audit_covers_openspec_external_files
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      FileUtils.mkdir_p(File.join(root, "openspec"))
      File.write(File.join(root, "openspec/config.yaml"), "schema: spec-driven\n")
      skill = File.join(root, ".agents/skills/openspec-propose/SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill))
      File.write(skill, "---\nname: openspec-propose\ndescription: test\n---\n")
      marker = File.join(root, ".agents/skills/.openspec-target")
      File.write(marker, "codex\n")

      auditor, _output, error = cli
      assert_equal 0, auditor.run(["audit", "--target", root]), error.string
      %w[openspec/config.yaml .agents/skills/openspec-propose/SKILL.md .agents/skills/.openspec-target].each do |path|
        assert system("git", "-C", root, "check-ignore", "-q", "--no-index", path)
      end
    end
  end

  # 目标内容冲突时，安装不创建其他工作流文件。
  def test_install_is_atomic_when_a_conflict_exists
    with_repository do |root|
      File.write(File.join(root, "WORKFLOW.md"), "user content\n")
      manager, _output, error = cli
      assert_equal 2, manager.run(["install", "--target", root, "--local"])
      assert_includes error.string, "conflict WORKFLOW.md"
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
      assert_equal "user content\n", File.read(File.join(root, "WORKFLOW.md"))
    end
  end

  # 管理目录的符号链接不能使写入逃离目标仓库。
  def test_install_rejects_symlinked_managed_directory_before_writing
    with_repository do |root|
      outside = Dir.mktmpdir("workflow-manager-outside")
      FileUtils.rm_rf(File.join(root, ".codex"))
      File.symlink(outside, File.join(root, ".codex"))
      manager, _output, error = cli

      assert_equal 2, manager.run(["install", "--target", root, "--local"])
      assert_includes error.string, "symlink in managed path"
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
      assert_empty Dir.children(outside)
    ensure
      FileUtils.rm_rf(outside) if outside
    end
  end

  # 悬空入口符号链接同样需要在写入前拒绝。
  def test_install_rejects_dangling_agents_symlink_before_writing
    with_repository(agents: false) do |root|
      outside = File.join(File.dirname(root), "outside-agents-#{File.basename(root)}.md")
      File.symlink(outside, File.join(root, "AGENTS.md"))
      manager, _output, error = cli

      assert_equal 2, manager.run(["install", "--target", root, "--local"])
      assert_includes error.string, "AGENTS.md must not be a symlink"
      refute File.exist?(outside)
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
    ensure
      FileUtils.rm_f(outside) if outside
    end
  end

  # 更新预检管理路径，避免改写链接目标。
  def test_update_rejects_symlinked_managed_path_before_writing
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      hook = File.join(root, ".codex/hooks.json")
      outside = File.join(File.dirname(root), "outside-hook-#{File.basename(root)}.json")
      FileUtils.rm_f(hook)
      File.symlink(outside, hook)

      updater, _output, error = cli
      assert_equal 2, updater.run(["update", "--target", root])
      assert_includes error.string, "symlink in managed path"
      refute File.exist?(outside)
    ensure
      FileUtils.rm_f(outside) if outside
    end
  end

  # 配置损坏时不能先恢复或修改其他文件。
  def test_update_rejects_invalid_config_before_restoring_managed_files
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      missing = File.join(root, ".codex/hooks/stop_reminder.rb")
      FileUtils.rm_f(missing)
      File.write(File.join(root, ".ai-workflow/config.yml"), "- invalid\n- root\n")

      updater, _output, error = cli
      assert_equal 2, updater.run(["update", "--target", root])
      assert_includes error.string, "root must be a mapping"
      refute File.exist?(missing)
    end
  end

  # 被跟踪但缺失的入口由用户恢复，安装不擅自重建。
  def test_install_rejects_tracked_but_missing_agents_before_writing
    with_repository do |root|
      system("git", "-C", root, "add", "AGENTS.md")
      FileUtils.rm_f(File.join(root, "AGENTS.md"))
      manager, _output, error = cli

      assert_equal 2, manager.run(["install", "--target", root, "--local"])
      assert_includes error.string, "tracked AGENTS.md is missing"
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
    end
  end

  # 已跟踪文件不能靠 ignore 变为本地文件，安装应在写入前停止。
  def test_install_rejects_tracked_workflow_path_before_writing
    with_repository do |root|
      source = File.join(@skill_root, "assets/generic/WORKFLOW.md")
      FileUtils.cp(source, File.join(root, "WORKFLOW.md"))
      system("git", "-C", root, "add", "WORKFLOW.md")
      before = Open3.capture3("git", "-C", root, "diff", "--cached").first
      manager, _output, error = cli
      assert_equal 2, manager.run(["install", "--target", root, "--local"])
      assert_includes error.string, "cannot own tracked files"
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
      assert_equal before, Open3.capture3("git", "-C", root, "diff", "--cached").first
    end
  end

  # 自定义工作流内容不能被更新或卸载覆盖。
  def test_update_preserves_locally_modified_managed_file
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      File.write(File.join(root, "WORKFLOW.md"), "local customization\n")

      updater, output, = cli
      assert_equal 1, updater.run(["update", "--target", root])
      assert_includes output.string, "preserved locally modified WORKFLOW.md"
      assert_equal "local customization\n", File.read(File.join(root, "WORKFLOW.md"))

      remover, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      assert File.exist?(File.join(root, "WORKFLOW.md"))
    end
  end

  # 生成入口追加的项目上下文在更新和卸载时保留。
  def test_adapted_managed_agents_is_valid_and_preserved_on_uninstall
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      agents = File.join(root, "AGENTS.md")
      File.write(agents, File.read(agents) + "\n## Project Context\n\nVerified project fact.\n")

      updater, output, error = cli
      assert_equal 0, updater.run(["update", "--target", root]), error.string
      assert_includes output.string, "preserved adapted AGENTS.md"
      auditor, = cli
      assert_equal 0, auditor.run(["audit", "--target", root])

      remover, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      assert File.exist?(agents)
    end
  end

  # 历史入口模板的合法项目上下文仍可识别。
  def test_update_accepts_adapted_agents_from_previous_template
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      agents = File.join(root, "AGENTS.md")
      previous_template = File.read(agents).sub(/\n## Code Comments\n.*?(?=\n## Specification And Method)/m, "")
      adapted = previous_template + "\n## Project Context\n\nVerified project fact.\n"
      File.write(agents, adapted)

      updater, output, error = cli
      assert_equal 0, updater.run(["update", "--target", root]), error.string
      assert_includes output.string, "preserved adapted AGENTS.md"
      assert_equal adapted, File.read(agents)
      auditor, = cli
      assert_equal 0, auditor.run(["audit", "--target", root])
    end
  end

  # 空入口不满足工作流契约，不能声明更新成功。
  def test_invalid_managed_agents_adaptation_fails_update_and_audit
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      File.write(File.join(root, "AGENTS.md"), "")

      updater, output, = cli
      assert_equal 1, updater.run(["update", "--target", root])
      assert_includes output.string, "missing required workflow contract markers"
      auditor, = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
    end
  end

  # 只堆砌关键字的入口不视为完整协作契约。
  def test_marker_only_agents_adaptation_fails_update_and_audit
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      File.write(
        File.join(root, "AGENTS.md"),
        "WORKFLOW.md Route Validation Harness OpenSpec Superpowers ./Scripts/ai-workflow validate\n"
      )

      updater, = cli
      assert_equal 1, updater.run(["update", "--target", root])
      auditor, = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
    end
  end

  # 已转交 Git 管理的入口缺失时报告失败，不自动恢复。
  def test_update_fails_when_git_owned_agents_is_missing
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      system("git", "-C", root, "add", "-f", "AGENTS.md")
      FileUtils.rm_f(File.join(root, "AGENTS.md"))

      updater, output, = cli
      assert_equal 1, updater.run(["update", "--target", root])
      assert_includes output.string, "tracked AGENTS.md is missing"
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  # 入口已进入索引后，卸载不能删除或撤销暂存内容。
  def test_uninstall_preserves_agents_after_git_takes_ownership
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      agents = File.join(root, "AGENTS.md")
      system("git", "-C", root, "add", "-f", "AGENTS.md")

      remover, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      assert File.exist?(agents)
      assert_includes `git -C #{root} diff --cached --name-only -- AGENTS.md`, "AGENTS.md"
    end
  end

  # 排除规则被意外撤销时必须阻止错误的本机隔离成功结论。
  def test_audit_rejects_unignored_workflow_file
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      exclude = File.join(root, ".git/info/exclude")
      File.write(exclude, File.read(exclude) + "\n!/WORKFLOW.md\n")
      auditor, _output, error = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
      assert_includes error.string, "workflow files are locally ignored"
      assert_includes error.string, "WORKFLOW.md"
    end
  end

  # OpenSpec 尚未生成的文件也应受到本机排除规则保护。
  def test_audit_rejects_unignored_future_openspec_paths
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      exclude = File.join(root, ".git/info/exclude")
      File.write(exclude, File.read(exclude) + "\n!/openspec/\n")
      auditor, _output, error = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
      assert_includes error.string, "future OpenSpec paths are locally ignored"
      assert_includes error.string, "openspec/changes/local-audit/proposal.md"
    end
  end

  # 审计拒绝重定向到仓库外的 OpenSpec 根目录。
  def test_audit_rejects_symlinked_openspec_root
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      outside = Dir.mktmpdir("workflow-openspec-outside")
      File.write(File.join(outside, "config.yaml"), "schema: spec-driven\n")
      File.symlink(outside, File.join(root, "openspec"))

      auditor, _output, error = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
      assert_includes error.string, "OpenSpec trees contain no symlinks"
      assert_includes error.string, "openspec"
    ensure
      FileUtils.rm_rf(outside) if outside
    end
  end


  # 嵌套变更和技能目录中的符号链接同样需要报告。
  def test_audit_rejects_nested_openspec_and_skill_symlinks
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      outside = Dir.mktmpdir("workflow-openspec-nested")
      change = File.join(outside, "change")
      skill = File.join(outside, "skill")
      FileUtils.mkdir_p(change)
      FileUtils.mkdir_p(skill)
      File.write(File.join(change, "proposal.md"), "# Proposal\n")
      File.write(File.join(skill, "SKILL.md"), "---\nname: openspec-propose\ndescription: test\n---\n\n# Skill\n")
      FileUtils.mkdir_p(File.join(root, "openspec/changes"))
      FileUtils.mkdir_p(File.join(root, ".agents/skills"))
      File.symlink(change, File.join(root, "openspec/changes/add-feature"))
      File.symlink(skill, File.join(root, ".agents/skills/openspec-propose"))

      auditor, _output, error = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
      assert_includes error.string, "OpenSpec trees contain no symlinks"
      assert_includes error.string, "openspec/changes/add-feature"
      assert_includes error.string, ".agents/skills/openspec-propose"
    ensure
      FileUtils.rm_rf(outside) if outside
    end
  end

  # 更新将旧个人排除块替换为当前本机排除块。
  def test_update_removes_legacy_personal_exclusion_block
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      exclude = File.join(root, ".git/info/exclude")
      File.write(
        exclude,
        File.read(exclude) + "\n#{AIWorkflowManager::LEGACY_EXCLUDE_BEGIN}\n/WORKFLOW.md\n#{AIWorkflowManager::LEGACY_EXCLUDE_END}\n"
      )

      auditor, _output, error = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
      assert_includes error.string, "legacy personal exclusion is absent"

      updater, _output, error = cli
      assert_equal 0, updater.run(["update", "--target", root]), error.string
      refute_includes File.read(exclude), AIWorkflowManager::LEGACY_EXCLUDE_BEGIN
      assert_includes File.read(exclude), AIWorkflowManager::LOCAL_EXCLUDE_BEGIN
      final_auditor, = cli
      assert_equal 0, final_auditor.run(["audit", "--target", root])
    end
  end

  # 用户关闭的集成不因配置迁移被重新启用。
  def test_update_preserves_disabled_openspec_without_requiring_commands
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      config_path = File.join(root, ".ai-workflow/config.yml")
      config = YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false)
      config["integrations"]["openspec"]["required"] = false
      config["doctor"]["required_commands"] |= %w[node openspec]
      File.write(config_path, YAML.dump(config))

      updater, _output, error = cli
      assert_equal 0, updater.run(["update", "--target", root]), error.string
      migrated = YAML.safe_load(File.read(config_path), permitted_classes: [], aliases: false)
      assert_equal false, migrated.dig("integrations", "openspec", "required")
      refute_includes migrated.dig("doctor", "required_commands"), "node"
      refute_includes migrated.dig("doctor", "required_commands"), "openspec"
    end
  end

  # 卸载不能沿管理目录符号链接删除外部内容。
  def test_uninstall_rejects_symlinked_managed_ancestor_before_deleting
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      outside = Dir.mktmpdir("workflow-manager-uninstall")
      external_codex = File.join(outside, "managed-codex")
      FileUtils.mv(File.join(root, ".codex"), external_codex)
      File.symlink(external_codex, File.join(root, ".codex"))

      remover, _output, error = cli
      assert_equal 2, remover.run(["uninstall", "--target", root, "--apply"])
      assert_includes error.string, "symlink in managed path"
      assert File.exist?(File.join(external_codex, "hooks.json"))
      assert File.exist?(File.join(root, "WORKFLOW.md"))
    ensure
      FileUtils.rm_rf(outside) if outside
    end
  end

  # 排除文件不安全时，卸载在删除前停止。
  def test_uninstall_rejects_symlinked_git_exclude_before_deleting
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      exclude = File.join(root, ".git/info/exclude")
      outside = File.join(File.dirname(root), "outside-exclude-#{File.basename(root)}")
      File.write(outside, "external\n")
      FileUtils.rm_f(exclude)
      File.symlink(outside, exclude)

      remover, _output, error = cli
      assert_equal 2, remover.run(["uninstall", "--target", root, "--apply"])
      assert_includes error.string, "Git exclude path must not be a symlink"
      assert File.exist?(File.join(root, "WORKFLOW.md"))
      assert File.exist?(File.join(root, AIWorkflowManager::MANIFEST))
      assert_equal "external\n", File.read(outside)
    ensure
      FileUtils.rm_f(outside) if outside
    end
  end

  # 安装清单不能借未知路径扩大删除范围。
  def test_uninstall_rejects_unknown_manifest_path_before_deleting
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      git_config = File.join(root, ".git/config")
      manifest_path = File.join(root, AIWorkflowManager::MANIFEST)
      manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
      manifest.fetch("files")[".git/config"] = Digest::SHA256.file(git_config).hexdigest
      File.write(manifest_path, YAML.dump(manifest))

      remover, _output, error = cli
      assert_equal 2, remover.run(["uninstall", "--target", root, "--apply"])
      assert_includes error.string, "unsafe managed path"
      assert File.file?(git_config)
      assert File.file?(File.join(root, "WORKFLOW.md"))
    end
  end

  # 审计拒绝路径穿越形式的伪造清单。
  def test_audit_rejects_manifest_path_traversal
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      manifest_path = File.join(root, AIWorkflowManager::MANIFEST)
      manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
      manifest.fetch("files")["../outside"] = "0" * 64
      File.write(manifest_path, YAML.dump(manifest))

      auditor, _output, error = cli
      assert_equal 2, auditor.run(["audit", "--target", root])
      assert_includes error.string, "unsafe managed path"
    end
  end

  # 审计拒绝清单声称拥有的业务文件。
  def test_audit_rejects_unowned_manifest_path
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      manifest_path = File.join(root, AIWorkflowManager::MANIFEST)
      manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
      manifest.fetch("files")["README.md"] = "0" * 64
      File.write(manifest_path, YAML.dump(manifest))

      auditor, _output, error = cli
      assert_equal 2, auditor.run(["audit", "--target", root])
      assert_includes error.string, "unknown managed path README.md"
    end
  end

  # 非法校验值不能触发文件恢复或更新。
  def test_update_rejects_invalid_manifest_checksum_before_writing
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      workflow = File.join(root, "WORKFLOW.md")
      manifest_path = File.join(root, AIWorkflowManager::MANIFEST)
      manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
      manifest.fetch("files")["WORKFLOW.md"] = "not-a-sha256"
      File.write(manifest_path, YAML.dump(manifest))
      FileUtils.rm_f(workflow)

      updater, _output, error = cli
      assert_equal 2, updater.run(["update", "--target", root])
      assert_includes error.string, "invalid checksum for WORKFLOW.md"
      refute File.exist?(workflow)
    end
  end

  # 卸载保留外部 OpenSpec 文件及其本机忽略保护。
  def test_uninstall_preserves_external_openspec_files
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--local"])
      config = File.join(root, "openspec/config.yaml")
      FileUtils.mkdir_p(File.dirname(config))
      File.write(config, "schema: spec-driven\n")

      remover, output, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      assert File.exist?(config)
      assert_includes output.string, "preserve external OpenSpec files"
      assert system("git", "-C", root, "check-ignore", "-q", "--no-index", "openspec/config.yaml")
    end
  end
  # 未跟踪的旧共享安装可迁移，且重复更新不累积管理块。
  def test_update_migrates_untracked_portable_install_and_is_idempotent
    with_repository do |root|
      manager, = cli
      assert_equal 0, manager.run(["install", "--target", root])
      exclude = File.join(root, ".git/info/exclude")
      original = File.read(exclude).sub(/^# BEGIN ai-coding-workflow-manager \(local\)\n.*?^# END ai-coding-workflow-manager \(local\)\n/m, "")
      File.write(exclude, original)
      updater, _out, error = cli
      assert_equal 0, updater.run(["update", "--target", root]), error.string
      first = File.read(exclude)
      assert_equal 0, updater.run(["update", "--target", root]), error.string
      assert_equal first, File.read(exclude)
      assert_equal 1, first.scan(AIWorkflowManager::LOCAL_EXCLUDE_BEGIN).length
    end
  end

  # 已跟踪的旧安装必须由用户迁移，更新不修改文件内容或索引。
  def test_update_stops_for_tracked_portable_files_without_mutation
    with_repository do |root|
      manager, = cli
      assert_equal 0, manager.run(["install", "--target", root])
      system("git", "-C", root, "add", "-f", "WORKFLOW.md")
      workflow = File.read(File.join(root, "WORKFLOW.md"))
      index = Open3.capture3("git", "-C", root, "diff", "--cached").first
      updater, _out, error = cli
      assert_equal 2, updater.run(["update", "--target", root])
      assert_includes error.string, "removing workflow files from Git tracking first"
      assert_equal workflow, File.read(File.join(root, "WORKFLOW.md"))
      assert_equal index, Open3.capture3("git", "-C", root, "diff", "--cached").first
      auditor, _out, error = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
      assert_includes error.string, "workflow files are not tracked"
    end
  end

  # 完全卸载恢复用户排除内容，预览模式不能改写排除文件。
  def test_uninstall_cleans_only_own_ignore_block
    with_repository do |root|
      exclude = File.join(root, ".git/info/exclude")
      original = File.read(exclude) + "\n/private-notes/\n"
      File.write(exclude, original)
      manager, = cli
      assert_equal 0, manager.run(["install", "--target", root])
      installed = File.read(exclude)
      assert_equal 0, manager.run(["uninstall", "--target", root])
      assert_equal installed, File.read(exclude)
      assert_equal 0, manager.run(["uninstall", "--target", root, "--apply"])
      assert_equal original, File.read(exclude)
    end
  end

  # 自定义文件卸载后仍需忽略，避免将个人配置意外加入提交。
  def test_uninstall_keeps_modified_files_ignored
    with_repository do |root|
      manager, = cli
      assert_equal 0, manager.run(["install", "--target", root])
      File.write(File.join(root, "WORKFLOW.md"), "personal configuration\n")
      assert_equal 0, manager.run(["uninstall", "--target", root, "--apply"])
      assert system("git", "-C", root, "check-ignore", "-q", "WORKFLOW.md")
      assert_includes File.read(File.join(root, ".git/info/exclude")), AIWorkflowManager::LOCAL_EXCLUDE_BEGIN
    end
  end

  # 排除文件路径被重定向时，必须在安装任何文件之前拒绝执行。
  def test_install_rejects_symlinked_exclude_before_writing
    with_repository do |root|
      Dir.mktmpdir("exclude-outside") do |outside|
        target = File.join(outside, "exclude")
        File.write(target, "user rules\n")
        path = File.join(root, ".git/info/exclude")
        FileUtils.rm_f(path)
        File.symlink(target, path)
        manager, _out, error = cli
        assert_equal 2, manager.run(["install", "--target", root])
        assert_includes error.string, "Git exclude path must not be a symlink"
        refute File.exist?(File.join(root, "WORKFLOW.md"))
        assert_equal "user rules\n", File.read(target)
      end
    end
  end

  # linked worktree 的 .git 是文件，应使用 Git 返回的实际元数据路径。
  def test_install_in_linked_worktree
    with_repository do |root|
      system("git", "-C", root, "add", "AGENTS.md")
      assert system("git", "-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base")
      Dir.mktmpdir("workflow-worktree") do |parent|
        tree = File.join(parent, "checkout")
        assert system("git", "-C", root, "worktree", "add", "-q", "-b", "personal-workflow", tree)
        manager, _out, error = cli
        assert_equal 0, manager.run(["install", "--target", tree]), error.string
        assert File.file?(File.join(tree, ".git"))
        assert system("git", "-C", tree, "check-ignore", "-q", "WORKFLOW.md")
        assert_equal "", Open3.capture3("git", "-C", tree, "status", "--porcelain").first
      end
    end
  end

  # 校验日志不在安装清单内，但卸载后仍属于本机私有数据。
  def test_uninstall_keeps_logs_ignored
    with_repository do |root|
      manager, = cli
      assert_equal 0, manager.run(["install", "--target", root])
      logs = File.join(root, ".ai-workflow/logs")
      FileUtils.mkdir_p(logs)
      File.write(File.join(logs, "project.log"), "local validation output\n")
      assert_equal 0, manager.run(["uninstall", "--target", root, "--apply"])
      assert File.file?(File.join(logs, "project.log"))
      assert system("git", "-C", root, "check-ignore", "-q", ".ai-workflow/logs/project.log")
    end
  end

  # 标记损坏时不能尝试修复并吞掉用户维护的忽略规则。
  def test_install_rejects_incomplete_ignore_block_before_writing
    with_repository do |root|
      exclude = File.join(root, ".git/info/exclude")
      original = File.read(exclude) + AIWorkflowManager::LOCAL_EXCLUDE_BEGIN + "\n/user-file\n"
      File.write(exclude, original)
      manager, _out, error = cli
      assert_equal 2, manager.run(["install", "--target", root])
      assert_includes error.string, "Invalid workflow exclude block"
      refute File.exist?(File.join(root, "WORKFLOW.md"))
      assert_equal original, File.read(exclude)
    end
  end

  # 旧共享安装的自定义项目说明迁移后应原样保留，并受到本机忽略保护。
  def test_update_preserves_adapted_portable_agents
    with_repository(agents: false) do |root|
      manager, = cli
      assert_equal 0, manager.run(["install", "--target", root])
      path = File.join(root, "AGENTS.md")
      local_intro = "project did not already provide `AGENTS.md`. This generated entry and the other\ninstalled workflow definitions are personal files excluded through\n`.git/info/exclude`. Do not add them to project commits; other team members\ninstall their own workflow. Preserve an existing project-owned `AGENTS.md`."
      old_intro = "project did not already provide `AGENTS.md`. Keep it in Git with the other\nworkflow definitions so every device receives the same collaboration contract."
      original = File.read(path).sub(local_intro, old_intro) + "\n## Project Context\n\nProject facts.\n"
      File.write(path, original)
      updater, _out, error = cli
      assert_equal 0, updater.run(["update", "--target", root]), error.string
      migrated = File.read(path)
      assert_includes migrated, "Project facts."
      refute_includes migrated, "Keep it in Git with the other"
      assert_includes migrated, "install their own workflow"
      assert system("git", "-C", root, "check-ignore", "-q", "AGENTS.md")
    end
  end

end
