#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "yaml"

module AIWorkflowManager
  VERSION = "3.3.0"
  MANIFEST = ".ai-workflow/install-manifest.yml"
  CONFIG = ".ai-workflow/config.yml"
  AGENTS = "AGENTS.md"
  RETIRED_MANAGED_PATHS = [].freeze
  PORTABLE_PATH_PROBES = [
    "openspec/config.yaml",
    "openspec/changes/portable-audit/proposal.md",
    ".agents/skills/openspec-audit/SKILL.md",
    ".agents/skills/.openspec-target"
  ].freeze
  DEPRECATED_OPENSPEC_SKILLS = %w[openspec-verify-change].freeze
  LEGACY_EXCLUDE_BEGIN = "# BEGIN ai-coding-workflow-manager (personal)"
  LEGACY_EXCLUDE_END = "# END ai-coding-workflow-manager (personal)"

  class Error < StandardError; end

  class CLI
    def initialize(skill_root: File.expand_path("..", __dir__), output: $stdout, error: $stderr)
      @skill_root = skill_root
      @output = output
      @error = error
    end

    def run(argv)
      operation = argv.shift
      return help(0) if %w[-h --help help].include?(operation)
      raise Error, "Expected install, update, audit, or uninstall" unless %w[install update audit uninstall].include?(operation)

      options = parse(argv, operation)
      root = git_root(options.fetch(:target))
      case operation
      when "install" then install(root, options)
      when "update" then update(root)
      when "audit" then audit(root)
      when "uninstall" then uninstall(root, apply: options[:apply])
      end
    rescue Error, OptionParser::ParseError => e
      @error.puts "[FAIL] #{e.message}"
      2
    end

    private

    def parse(argv, operation)
      options = { apply: false, portable: false }
      parser = OptionParser.new do |opts|
        opts.on("--target PATH") { |value| options[:target] = value }
        opts.on("--portable") { options[:portable] = true }
        opts.on("--apply") { options[:apply] = true }
      end
      parser.parse!(argv)
      raise Error, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      raise Error, "--target is required" unless options[:target]
      raise Error, "install requires --portable" if operation == "install" && !options[:portable]
      raise Error, "--portable is valid only for install" if operation != "install" && options[:portable]
      raise Error, "--apply is valid only for uninstall" if operation != "uninstall" && options[:apply]
      options
    end

    def help(code)
      @output.puts <<~TEXT
        Usage:
          ruby scripts/workflow_manager.rb install --target PATH --portable
          ruby scripts/workflow_manager.rb update --target PATH
          ruby scripts/workflow_manager.rb audit --target PATH
          ruby scripts/workflow_manager.rb uninstall --target PATH [--apply]

        Portable mode creates AGENTS.md only when absent and keeps workflow
        files Git-visible for repository sharing. It never stages files,
        commits, installs dependencies, or configures Git Hooks. Uninstall is
        dry-run by default.
      TEXT
      code
    end

    def git_root(target)
      expanded = File.expand_path(target)
      raise Error, "Target does not exist: #{expanded}" unless File.directory?(expanded)

      stdout, stderr, status = Open3.capture3("git", "-C", expanded, "rev-parse", "--show-toplevel")
      raise Error, "Target is not a Git repository: #{stderr.strip}" unless status.success?

      root = File.realpath(stdout.strip)
      raise Error, "Target must be the Git root: #{root}" unless File.realpath(expanded) == root
      root
    end

    def asset_root
      File.join(@skill_root, "assets", "generic")
    end

    def asset_paths
      Dir.glob(File.join(asset_root, "**", "*"), File::FNM_DOTMATCH).select do |path|
        File.file?(path) && !%w[. ..].include?(File.basename(path))
      end.map { |path| path.delete_prefix("#{asset_root}/") }.sort
    end

    def desired_content(relative, root)
      content = File.binread(File.join(asset_root, relative))
      return content.gsub("{{PROJECT_NAME}}", File.basename(root)) if relative == AGENTS
      return content unless relative == CONFIG

      data = YAML.safe_load(content, permitted_classes: [], aliases: false)
      data["project"]["name"] = File.basename(root)
      data["doctor"]["required_paths"] = Array(data["doctor"]["required_paths"]) | [AGENTS]
      YAML.dump(data)
    end

    def install(root, _options)
      raise Error, "Workflow already has a manifest; use update" if File.exist?(File.join(root, MANIFEST))

      install_paths = asset_paths.dup
      agents_target = File.join(root, AGENTS)
      tracked_agents = git_nul(root, "ls-files", "-z", "--", AGENTS)
      if File.symlink?(agents_target)
        raise Error, "Installation stopped before changes; #{AGENTS} must not be a symlink"
      elsif !tracked_agents.empty? && !path_entry_exists?(agents_target)
        raise Error, "Installation stopped before changes; tracked #{AGENTS} is missing from the working tree"
      elsif File.file?(agents_target) || File.symlink?(agents_target)
        install_paths.delete(AGENTS)
        @output.puts "[WARN] preserved existing #{AGENTS}"
      elsif File.exist?(agents_target)
        raise Error, "Installation stopped before changes; #{AGENTS} exists but is not a file"
      end

      ensure_no_symlink_components!(root, install_paths + [MANIFEST])

      conflicts = install_paths.select do |relative|
        target = File.join(root, relative)
        path_entry_exists?(target) && (!File.file?(target) || File.symlink?(target) || File.binread(target) != desired_content(relative, root))
      end
      unless conflicts.empty?
        conflicts.each { |path| @error.puts "[FAIL] conflict #{path}" }
        raise Error, "Installation stopped before changes; reconcile conflicts explicitly"
      end

      checksums = {}
      install_paths.each do |relative|
        target = File.join(root, relative)
        content = desired_content(relative, root)
        unless File.file?(target)
          FileUtils.mkdir_p(File.dirname(target))
          File.binwrite(target, content)
          @output.puts "[PASS] installed #{relative}"
        else
          @output.puts "[PASS] identical #{relative}"
        end
        FileUtils.chmod(0o755, target) if relative == "Scripts/ai-workflow"
        checksums[relative] = sha(target)
      end
      write_manifest(root, checksums)

      tests_ok = run_workflow_tests(root)
      audit_code = audit(root)
      @output.puts "[PASS] portable workflow files are Git-visible" if audit_code.zero?
      tests_ok && audit_code.zero? ? 0 : 1
    end

    def update(root)
      ensure_no_symlink_components!(root, [MANIFEST])
      manifest = read_manifest(root)
      old = manifest.fetch("files")
      next_hashes = old.dup
      conflicts = []
      tracked_agents = !git_nul(root, "ls-files", "-z", "--", AGENTS).empty?

      write_candidates = asset_paths.reject do |relative|
        relative == AGENTS && path_entry_exists?(File.join(root, relative)) &&
          (tracked_agents || !old.key?(relative) || managed_agents_adapted?(root, old))
      end
      ensure_no_symlink_components!(root, write_candidates)
      migrated_config = migrated_config_content(root)

      asset_paths.each do |relative|
        target = File.join(root, relative)
        source_content = desired_content(relative, root)
        if relative == AGENTS && tracked_agents
          if File.file?(target) && !File.symlink?(target)
            next_hashes.delete(relative)
            @output.puts "[WARN] preserved Git-owned #{relative}"
          else
            conflicts << relative
            @output.puts "[WARN] tracked #{relative} is missing or not a regular file"
          end
          next
        end
        if relative == AGENTS && path_entry_exists?(target) && !old.key?(relative)
          @output.puts "[WARN] preserved existing #{relative}"
          next
        end
        if relative == AGENTS && managed_agents_adapted?(root, old)
          if valid_agents_contract?(target, root)
            @output.puts "[WARN] preserved adapted #{relative}"
          else
            conflicts << relative
            @output.puts "[WARN] adapted #{relative} is missing required workflow contract markers"
          end
          next
        end
        if relative == CONFIG && File.file?(target)
          @output.puts "[WARN] preserved project-owned #{relative}"
          next
        end

        managed = true
        if !File.exist?(target)
          FileUtils.mkdir_p(File.dirname(target))
          File.binwrite(target, source_content)
          @output.puts "[PASS] added #{relative}"
          next_hashes[relative] = sha(target)
        elsif !File.file?(target)
          conflicts << relative
          managed = false
        elsif File.binread(target) == source_content
          @output.puts "[PASS] current #{relative}"
          next_hashes[relative] = sha(target)
        elsif old[relative] && sha(target) == old[relative]
          File.binwrite(target, source_content)
          @output.puts "[PASS] updated #{relative}"
          next_hashes[relative] = sha(target)
        else
          conflicts << relative
          managed = false
          @output.puts "[WARN] preserved locally modified #{relative}"
        end
        FileUtils.chmod(0o755, target) if managed && relative == "Scripts/ai-workflow" && File.file?(target)
      end

      File.write(File.join(root, CONFIG), migrated_config)
      write_manifest(root, next_hashes)
      remove_legacy_exclude_block(root) if legacy_exclude_present?(root)
      tests_ok = run_workflow_tests(root)
      audit_code = audit(root)
      return 1 unless conflicts.empty?
      tests_ok && audit_code.zero? ? 0 : 1
    end

    def audit(root)
      ensure_no_symlink_components!(root, [MANIFEST])
      manifest = read_manifest(root)
      integration_symlinks = integration_tree_symlinks(root)
      integration = integration_symlinks.empty? ? integration_files(root) : []
      files = manifest.fetch("files").keys + [MANIFEST, AGENTS] + integration
      files.uniq!
      failed = false

      failed |= report_check(
        integration_symlinks.empty?,
        "OpenSpec trees contain no symlinks",
        integration_symlinks.join(", ")
      )

      missing = files.reject do |path|
        target = File.join(root, path)
        File.file?(target) && !File.symlink?(target)
      end
      failed |= report_check(missing.empty?, "managed files exist", missing.join(", "))

      drift = manifest.fetch("files").keys.select do |path|
        target = File.join(root, path)
        File.file?(target) && !File.symlink?(target) && sha(target) != manifest.fetch("files").fetch(path)
      end
      config_drift = drift.delete(CONFIG)
      agents_drift = drift.include?(AGENTS)
      drift.delete(AGENTS) if agents_drift && valid_agents_contract?(File.join(root, AGENTS), root)
      @output.puts "[WARN] project configuration differs from installed baseline" if config_drift
      @output.puts "[WARN] generated #{AGENTS} was adapted after installation" if agents_drift
      failed |= report_check(drift.empty?, "managed implementation checksums", drift.join(", "))

      ignored = files.select { |path| git_success?(root, "check-ignore", "--no-index", "-q", "--", path) }
      failed |= report_check(ignored.empty?, "workflow files are Git-visible", ignored.join(", "))

      tracked = git_nul(root, "ls-files", "-z", "--", *files)
      pending = files - tracked
      if pending.empty?
        @output.puts "[PASS] workflow files are tracked"
      else
        @output.puts "[WARN] workflow files pending Git add: #{pending.join(', ')}"
      end

      executable = File.executable?(File.join(root, "Scripts/ai-workflow"))
      failed |= report_check(executable, "Scripts/ai-workflow is executable", "chmod +x required")
      failed |= !syntax_checks(root)

      ignored_probes = PORTABLE_PATH_PROBES.select do |path|
        git_success?(root, "check-ignore", "--no-index", "-q", "--", path)
      end
      failed |= report_check(ignored_probes.empty?, "future OpenSpec paths are Git-visible", ignored_probes.join(", "))
      failed |= report_check(!legacy_exclude_present?(root), "legacy personal exclusion is absent", "run update to remove the old manager block")

      @output.puts(failed ? "[FAIL] audit" : "[PASS] audit")
      failed ? 1 : 0
    end

    def uninstall(root, apply: false)
      ensure_no_symlink_components!(root, [MANIFEST])
      if apply && File.symlink?(exclude_path(root))
        raise Error, "Git exclude path must not be a symlink"
      end
      manifest = read_manifest(root)
      ensure_no_symlink_components!(root, manifest.fetch("files").keys) if apply
      external = integration_files(root)
      removable = []
      preserved = []
      manifest.fetch("files").each do |relative, expected|
        target = File.join(root, relative)
        next unless path_entry_exists?(target)
        tracked = !git_nul(root, "ls-files", "-z", "--", relative).empty?
        staged = !git_nul(root, "diff", "--cached", "--name-only", "-z", "--", relative).empty?
        if tracked || staged || File.symlink?(target)
          preserved << relative
        elsif File.file?(target) && sha(target) == expected
          removable << relative
        else
          preserved << relative
        end
      end

      removable.each { |path| @output.puts "[PASS] #{apply ? 'remove' : 'would remove'} #{path}" }
      preserved.each { |path| @output.puts "[WARN] preserve modified #{path}" }
      unless external.empty?
        @output.puts "[WARN] preserve external OpenSpec files: #{external.length}; they remain Git-visible"
      end
      unless apply
        @output.puts "[WARN] dry run only; use --apply to remove checksum-matching files"
        return 0
      end

      removable.each { |relative| FileUtils.rm_f(File.join(root, relative)) }
      manifest_tracked = !git_nul(root, "ls-files", "-z", "--", MANIFEST).empty?
      manifest_staged = !git_nul(root, "diff", "--cached", "--name-only", "-z", "--", MANIFEST).empty?
      if manifest_tracked || manifest_staged
        @output.puts "[WARN] preserve Git-owned #{MANIFEST}"
      else
        FileUtils.rm_f(File.join(root, MANIFEST))
      end
      remove_legacy_exclude_block(root) if legacy_exclude_present?(root)
      prune_empty_directories(root)
      @output.puts "[PASS] uninstall applied; modified and unrelated files were preserved"
      0
    end

    def read_manifest(root)
      path = File.join(root, MANIFEST)
      raise Error, "Missing #{MANIFEST}; install first" unless File.file?(path)
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      validate_manifest!(data)
      data
    rescue Psych::Exception => e
      raise Error, "Invalid manifest: #{e.message}"
    end

    def write_manifest(root, checksums)
      path = File.join(root, MANIFEST)
      data = { "version" => 1, "manager_version" => VERSION, "files" => checksums.sort.to_h }
      validate_manifest!(data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(data))
    end

    def validate_manifest!(data)
      unless data.is_a?(Hash) && data["version"] == 1 && data["files"].is_a?(Hash)
        raise Error, "Invalid manifest: expected version 1 with a files mapping"
      end

      allowed = asset_paths | RETIRED_MANAGED_PATHS
      data.fetch("files").each do |relative, checksum|
        unless safe_relative_path?(relative)
          raise Error, "Invalid manifest: unsafe managed path #{relative.inspect}"
        end
        unless allowed.include?(relative)
          raise Error, "Invalid manifest: unknown managed path #{relative}"
        end
        unless checksum.is_a?(String) && checksum.match?(/\A[0-9a-f]{64}\z/)
          raise Error, "Invalid manifest: invalid checksum for #{relative}"
        end
      end
    end

    def safe_relative_path?(relative)
      return false unless relative.is_a?(String) && !relative.empty? && relative.valid_encoding?
      return false if relative.include?("\0") || relative.include?("\\")

      path = Pathname.new(relative)
      components = relative.split("/", -1)
      !path.absolute? && components.none?(&:empty?) &&
        components.none? { |component| %w[. ..].include?(component) } &&
        components.first != ".git"
    end

    def migrated_config_content(root)
      path = File.join(root, CONFIG)
      raise Error, "Missing #{CONFIG}" unless File.file?(path) && !File.symlink?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      defaults = YAML.safe_load(File.read(File.join(asset_root, CONFIG)), permitted_classes: [], aliases: false)
      raise Error, "Cannot migrate #{CONFIG}: root must be a mapping" unless data.is_a?(Hash)
      raise Error, "Cannot migrate #{CONFIG}: doctor must be a mapping" unless data["doctor"].nil? || data["doctor"].is_a?(Hash)
      raise Error, "Cannot migrate #{CONFIG}: integrations must be a mapping" unless data["integrations"].nil? || data["integrations"].is_a?(Hash)
      data["doctor"] ||= {}
      data["doctor"]["required_paths"] = Array(data["doctor"]["required_paths"]) | [AGENTS]
      data["doctor"]["required_commands"] = Array(data["doctor"]["required_commands"])
      data["integrations"] ||= {}
      defaults.fetch("integrations").each do |name, default_config|
        if data["integrations"].key?(name) && !data["integrations"][name].is_a?(Hash)
          raise Error, "Cannot migrate #{CONFIG}: integrations.#{name} must be a mapping"
        end
        data["integrations"][name] ||= {}
        default_config.each do |key, value|
          data["integrations"][name][key] = value unless data["integrations"][name].key?(key)
        end
      end
      openspec = data.fetch("integrations").fetch("openspec")
      unless openspec["required"]
        data["doctor"]["required_commands"] -= %w[node openspec]
      end
      current_skills = Array(openspec["required_skills"]) - DEPRECATED_OPENSPEC_SKILLS
      openspec["required_skills"] = current_skills | Array(defaults.dig("integrations", "openspec", "required_skills"))
      YAML.dump(data)
    rescue Psych::SyntaxError => e
      raise Error, "Cannot migrate #{CONFIG}: #{e.message}"
    end

    def integration_files(root)
      patterns = [
        File.join(root, "openspec", "**", "*"),
        File.join(root, ".agents", "skills", "openspec-*", "**", "*"),
        File.join(root, ".agents", "skills", ".openspec-target")
      ]
      patterns.flat_map { |pattern| Dir.glob(pattern, File::FNM_DOTMATCH) }
        .reject { |path| %w[. ..].include?(File.basename(path)) }
        .select { |path| File.file?(path) }
        .map { |path| path.delete_prefix("#{root}/") }.sort
    end

    def integration_tree_symlinks(root)
      pending = %w[openspec .agents/skills]
      found = []
      until pending.empty?
        relative = pending.pop
        path = File.join(root, relative)
        next unless path_entry_exists?(path)
        if File.symlink?(path)
          found << relative
          next
        end
        next unless File.directory?(path)

        Dir.children(path).each do |child|
          pending << File.join(relative, child)
        end
      end
      found.sort
    rescue Errno::EACCES => e
      raise Error, "Cannot inspect OpenSpec integration tree: #{e.message}"
    end

    def exclude_path(root)
      common = Open3.capture3("git", "-C", root, "rev-parse", "--git-path", "info/exclude").first.strip
      File.expand_path(common, root)
    end

    def path_entry_exists?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def managed_agents_adapted?(root, manifest_files)
      expected = manifest_files[AGENTS]
      target = File.join(root, AGENTS)
      expected && path_entry_exists?(target) &&
        (File.symlink?(target) || !File.file?(target) || sha(target) != expected)
    end

    def valid_agents_contract?(path, root)
      return false unless File.file?(path) && !File.symlink?(path)
      source = File.read(path)
      agents_contract_prefixes(root).any? { |prefix| source.start_with?(prefix) }
    rescue Errno::EACCES, Errno::ENOENT
      false
    end

    def agents_contract_prefixes(root)
      current = desired_content(AGENTS, root)
      # 3.1 模板没有注释规范段；保留旧前缀以支持已适配项目无损升级。
      previous = current.sub(/\n## Code Comments\n.*?(?=\n## Specification And Method)/m, "")
      [current, previous].uniq
    end

    def ensure_no_symlink_components!(root, relatives)
      offenders = symlink_components(root, relatives)
      return if offenders.empty?

      raise Error, "Installation stopped before changes; symlink in managed path: #{offenders.uniq.join(', ')}"
    end

    def symlink_components(root, relatives)
      relatives.each_with_object([]) do |relative, found|
        current = root
        offender = nil
        relative.split(File::SEPARATOR).each do |component|
          current = File.join(current, component)
          if File.symlink?(current)
            offender = current.delete_prefix("#{root}/")
            break
          end
        end
        found << offender if offender
      end
    end

    def legacy_exclude_present?(root)
      path = exclude_path(root)
      File.file?(path) && !File.symlink?(path) && File.read(path).include?(LEGACY_EXCLUDE_BEGIN)
    end

    def remove_legacy_exclude_block(root)
      path = exclude_path(root)
      return unless File.file?(path)
      raise Error, "Git exclude path must not be a symlink" if File.symlink?(path)
      content = File.read(path)
      return unless content.include?(LEGACY_EXCLUDE_BEGIN)
      content = content.sub(/\n?#{Regexp.escape(LEGACY_EXCLUDE_BEGIN)}.*?#{Regexp.escape(LEGACY_EXCLUDE_END)}\n?/m, "\n")
      File.write(path, content.sub(/\n{3,}/, "\n\n"))
    end

    def syntax_checks(root)
      ok = true
      Dir.glob(File.join(root, "{Scripts/ai_workflow,.codex/hooks}", "**", "*.rb")).sort.each do |path|
        _stdout, stderr, status = Open3.capture3("/usr/bin/ruby", "-c", path)
        ok &= !report_check(status.success?, "Ruby syntax #{path.delete_prefix("#{root}/")}", stderr.strip)
      end
      begin
        JSON.parse(File.read(File.join(root, ".codex/hooks.json")))
        report_check(true, "hooks JSON", "")
      rescue JSON::ParserError, Errno::ENOENT => e
        ok = false
        report_check(false, "hooks JSON", e.message)
      end
      %w[.ai-workflow/config.yml .ai-workflow/generated-files.yml].each do |relative|
        begin
          YAML.safe_load(File.read(File.join(root, relative)), permitted_classes: [], aliases: false)
          report_check(true, "YAML #{relative}", "")
        rescue Psych::SyntaxError, Errno::ENOENT => e
          ok = false
          report_check(false, "YAML #{relative}", e.message)
        end
      end
      ok
    end

    def report_check(condition, name, detail)
      if condition
        @output.puts "[PASS] #{name}"
        false
      else
        @error.puts "[FAIL] #{name}#{detail.empty? ? '' : ": #{detail}"}"
        true
      end
    end

    def run_workflow_tests(root)
      stdout, stderr, status = Open3.capture3("ruby", "Scripts/ai_workflow_test.rb", chdir: root)
      stream = status.success? ? @output : @error
      stream.puts(status.success? ? "[PASS] workflow tests" : "[FAIL] workflow tests")
      stream.puts((stdout + stderr).lines.last(4).join) unless status.success?
      status.success?
    end

    def git_success?(root, *arguments)
      system("git", "-C", root, *arguments, out: File::NULL, err: File::NULL)
    end

    def git_nul(root, *arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
      raise Error, "Git failed: #{stderr.strip}" unless status.success?
      stdout.split("\0").reject(&:empty?)
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def prune_empty_directories(root)
      %w[Scripts/ai_workflow_tests Scripts/ai_workflow Scripts .codex/hooks .codex/agents .codex .ai-workflow/allowlists .ai-workflow/templates .ai-workflow].each do |relative|
        path = File.join(root, relative)
        Dir.rmdir(path) if File.directory?(path) && Dir.children(path).empty?
      rescue SystemCallError
        next
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit AIWorkflowManager::CLI.new.run(ARGV)
end
