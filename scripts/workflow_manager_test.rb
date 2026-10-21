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

  def test_install_audit_and_uninstall_lifecycle
    with_repository do |root|
      manager, output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--portable"]), error.string
      assert File.executable?(File.join(root, "Scripts/ai-workflow"))
      assert_equal "# Project rules\n", File.read(File.join(root, "AGENTS.md"))
      config = YAML.safe_load(File.read(File.join(root, ".ai-workflow/config.yml")), permitted_classes: [], aliases: false)
      assert_equal File.basename(root), config.dig("project", "name")
      assert_equal ["AGENTS.md"], config.dig("doctor", "required_paths")
      refute system("git", "-C", root, "check-ignore", "-q", "--no-index", "WORKFLOW.md")

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
      assert File.exist?(File.join(root, "WORKFLOW.md"))
      assert File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_committed_workflow_survives_clone_and_audit
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      assert system("git", "-C", root, "add", ".")
      assert system(
        "git", "-C", root, "-c", "user.name=Workflow Test", "-c",
        "user.email=workflow@example.invalid", "commit", "-q", "-m", "portable workflow"
      )

      clone_parent = Dir.mktmpdir("workflow-manager-clone")
      clone = File.join(clone_parent, "project")
      assert system("git", "clone", "-q", root, clone)
      auditor, _output, error = cli
      assert_equal 0, auditor.run(["audit", "--target", clone]), error.string
      assert File.executable?(File.join(clone, "Scripts/ai-workflow"))
      doctor_out, _doctor_err, doctor_status = Open3.capture3(File.join(clone, "Scripts/ai-workflow"), "doctor", chdir: clone)
      assert_equal 4, doctor_status.exitstatus
      assert_includes doctor_out, "Required portable workflow files exist"
      quick_out, _quick_err, quick_status = Open3.capture3(
        File.join(clone, "Scripts/ai-workflow"), "validate", "--route", "quick", chdir: clone
      )
      assert_equal 0, quick_status.exitstatus, quick_out
      refute_includes File.read(File.join(clone, ".git/info/exclude")), AIWorkflowManager::LEGACY_EXCLUDE_BEGIN
    ensure
      FileUtils.rm_rf(clone_parent) if clone_parent
    end
  end

  def test_install_creates_and_manages_agents_when_missing
    with_repository(agents: false) do |root|
      manager, _output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--portable"]), error.string
      agents = File.join(root, "AGENTS.md")
      assert File.file?(agents)
      assert_includes File.read(agents), File.basename(root)
      refute system("git", "-C", root, "check-ignore", "-q", "--no-index", "AGENTS.md")

      remover, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      refute File.exist?(agents)
    end
  end

  def test_install_distributes_complete_engineering_guardrails
    with_repository do |root|
      manager, _output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--portable"]), error.string

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

  def test_install_distributes_chinese_comment_contract
    with_repository(agents: false) do |root|
      manager, _output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--portable"]), error.string

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

  def test_install_fails_without_visibility_pass_when_workflow_is_preignored
    with_repository do |root|
      exclude = File.join(root, ".git/info/exclude")
      File.write(exclude, File.read(exclude) + "\n/WORKFLOW.md\n")
      manager, output, error = cli

      assert_equal 1, manager.run(["install", "--target", root, "--portable"])
      assert_includes error.string, "workflow files are Git-visible"
      refute_includes output.string, "[PASS] portable workflow files are Git-visible"
    end
  end

  def test_install_fails_when_existing_agents_is_ignored
    with_repository do |root|
      exclude = File.join(root, ".git/info/exclude")
      File.write(exclude, File.read(exclude) + "\n/AGENTS.md\n")
      manager, _output, error = cli

      assert_equal 1, manager.run(["install", "--target", root, "--portable"])
      assert_includes error.string, "workflow files are Git-visible"
      assert_includes error.string, "AGENTS.md"
    end
  end

  def test_install_preserves_tracked_agents
    with_repository do |root|
      system("git", "-C", root, "add", "AGENTS.md")
      manager, output, error = cli
      assert_equal 0, manager.run(["install", "--target", root, "--portable"]), error.string
      assert_includes output.string, "preserved existing AGENTS.md"
      assert_equal "# Project rules\n", File.read(File.join(root, "AGENTS.md"))
      assert_includes `git -C #{root} ls-files -- AGENTS.md`, "AGENTS.md"
    end
  end

  def test_update_migrates_legacy_configuration
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_audit_covers_openspec_external_files
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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
        refute system("git", "-C", root, "check-ignore", "-q", "--no-index", path)
      end
    end
  end

  def test_install_is_atomic_when_a_conflict_exists
    with_repository do |root|
      File.write(File.join(root, "WORKFLOW.md"), "user content\n")
      manager, _output, error = cli
      assert_equal 2, manager.run(["install", "--target", root, "--portable"])
      assert_includes error.string, "conflict WORKFLOW.md"
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
      assert_equal "user content\n", File.read(File.join(root, "WORKFLOW.md"))
    end
  end

  def test_install_rejects_symlinked_managed_directory_before_writing
    with_repository do |root|
      outside = Dir.mktmpdir("workflow-manager-outside")
      FileUtils.rm_rf(File.join(root, ".codex"))
      File.symlink(outside, File.join(root, ".codex"))
      manager, _output, error = cli

      assert_equal 2, manager.run(["install", "--target", root, "--portable"])
      assert_includes error.string, "symlink in managed path"
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
      assert_empty Dir.children(outside)
    ensure
      FileUtils.rm_rf(outside) if outside
    end
  end

  def test_install_rejects_dangling_agents_symlink_before_writing
    with_repository(agents: false) do |root|
      outside = File.join(File.dirname(root), "outside-agents-#{File.basename(root)}.md")
      File.symlink(outside, File.join(root, "AGENTS.md"))
      manager, _output, error = cli

      assert_equal 2, manager.run(["install", "--target", root, "--portable"])
      assert_includes error.string, "AGENTS.md must not be a symlink"
      refute File.exist?(outside)
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
    ensure
      FileUtils.rm_f(outside) if outside
    end
  end

  def test_update_rejects_symlinked_managed_path_before_writing
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_update_rejects_invalid_config_before_restoring_managed_files
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      missing = File.join(root, ".codex/hooks/stop_reminder.rb")
      FileUtils.rm_f(missing)
      File.write(File.join(root, ".ai-workflow/config.yml"), "- invalid\n- root\n")

      updater, _output, error = cli
      assert_equal 2, updater.run(["update", "--target", root])
      assert_includes error.string, "root must be a mapping"
      refute File.exist?(missing)
    end
  end

  def test_install_rejects_tracked_but_missing_agents_before_writing
    with_repository do |root|
      system("git", "-C", root, "add", "AGENTS.md")
      FileUtils.rm_f(File.join(root, "AGENTS.md"))
      manager, _output, error = cli

      assert_equal 2, manager.run(["install", "--target", root, "--portable"])
      assert_includes error.string, "tracked AGENTS.md is missing"
      refute File.exist?(File.join(root, ".ai-workflow/config.yml"))
    end
  end

  def test_install_accepts_identical_tracked_workflow_path
    with_repository do |root|
      source = File.join(@skill_root, "assets/generic/WORKFLOW.md")
      FileUtils.cp(source, File.join(root, "WORKFLOW.md"))
      system("git", "-C", root, "add", "WORKFLOW.md")
      manager, _output, error = cli

      assert_equal 0, manager.run(["install", "--target", root, "--portable"]), error.string
      assert File.exist?(File.join(root, ".ai-workflow/config.yml"))
      assert_includes `git -C #{root} ls-files -- WORKFLOW.md`, "WORKFLOW.md"
    end
  end

  def test_update_preserves_locally_modified_managed_file
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_adapted_managed_agents_is_valid_and_preserved_on_uninstall
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_update_accepts_adapted_agents_from_previous_template
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_invalid_managed_agents_adaptation_fails_update_and_audit
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      File.write(File.join(root, "AGENTS.md"), "")

      updater, output, = cli
      assert_equal 1, updater.run(["update", "--target", root])
      assert_includes output.string, "missing required workflow contract markers"
      auditor, = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
    end
  end

  def test_marker_only_agents_adaptation_fails_update_and_audit
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_update_fails_when_git_owned_agents_is_missing
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      system("git", "-C", root, "add", "-f", "AGENTS.md")
      FileUtils.rm_f(File.join(root, "AGENTS.md"))

      updater, output, = cli
      assert_equal 1, updater.run(["update", "--target", root])
      assert_includes output.string, "tracked AGENTS.md is missing"
      refute File.exist?(File.join(root, "AGENTS.md"))
    end
  end

  def test_uninstall_preserves_agents_after_git_takes_ownership
    with_repository(agents: false) do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      agents = File.join(root, "AGENTS.md")
      system("git", "-C", root, "add", "-f", "AGENTS.md")

      remover, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      assert File.exist?(agents)
      assert_includes `git -C #{root} diff --cached --name-only -- AGENTS.md`, "AGENTS.md"
    end
  end

  def test_audit_rejects_ignored_workflow_file
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      exclude = File.join(root, ".git/info/exclude")
      File.write(exclude, File.read(exclude) + "\n/WORKFLOW.md\n")

      auditor, _output, error = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
      assert_includes error.string, "workflow files are Git-visible"
      assert_includes error.string, "WORKFLOW.md"
    end
  end

  def test_audit_rejects_ignored_future_openspec_paths
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      exclude = File.join(root, ".git/info/exclude")
      File.write(exclude, File.read(exclude) + "\n/openspec/changes/\n")

      auditor, _output, error = cli
      assert_equal 1, auditor.run(["audit", "--target", root])
      assert_includes error.string, "future OpenSpec paths are Git-visible"
      assert_includes error.string, "openspec/changes/portable-audit/proposal.md"
    end
  end

  def test_audit_rejects_symlinked_openspec_root
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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


  def test_audit_rejects_nested_openspec_and_skill_symlinks
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_update_removes_legacy_personal_exclusion_block
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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
      final_auditor, = cli
      assert_equal 0, final_auditor.run(["audit", "--target", root])
    end
  end

  def test_update_preserves_disabled_openspec_without_requiring_commands
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_uninstall_rejects_symlinked_managed_ancestor_before_deleting
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_uninstall_rejects_symlinked_git_exclude_before_deleting
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_uninstall_rejects_unknown_manifest_path_before_deleting
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_audit_rejects_manifest_path_traversal
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      manifest_path = File.join(root, AIWorkflowManager::MANIFEST)
      manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
      manifest.fetch("files")["../outside"] = "0" * 64
      File.write(manifest_path, YAML.dump(manifest))

      auditor, _output, error = cli
      assert_equal 2, auditor.run(["audit", "--target", root])
      assert_includes error.string, "unsafe managed path"
    end
  end

  def test_audit_rejects_unowned_manifest_path
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      manifest_path = File.join(root, AIWorkflowManager::MANIFEST)
      manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], aliases: false)
      manifest.fetch("files")["README.md"] = "0" * 64
      File.write(manifest_path, YAML.dump(manifest))

      auditor, _output, error = cli
      assert_equal 2, auditor.run(["audit", "--target", root])
      assert_includes error.string, "unknown managed path README.md"
    end
  end

  def test_update_rejects_invalid_manifest_checksum_before_writing
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
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

  def test_uninstall_preserves_external_openspec_files
    with_repository do |root|
      installer, = cli
      assert_equal 0, installer.run(["install", "--target", root, "--portable"])
      config = File.join(root, "openspec/config.yaml")
      FileUtils.mkdir_p(File.dirname(config))
      File.write(config, "schema: spec-driven\n")

      remover, output, = cli
      assert_equal 0, remover.run(["uninstall", "--target", root, "--apply"])
      assert File.exist?(config)
      assert_includes output.string, "preserve external OpenSpec files"
      refute system("git", "-C", root, "check-ignore", "-q", "--no-index", "openspec/config.yaml")
    end
  end
end
