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
  # 4.x 默认采用本机安装，移除将工作流随业务仓库共享的模式。
  VERSION = "4.0.0"
  MANIFEST = ".ai-workflow/install-manifest.yml"
  CONFIG = ".ai-workflow/config.yml"
  AGENTS = "AGENTS.md"
  RETIRED_MANAGED_PATHS = [].freeze
  # 对尚未生成的 OpenSpec 输出预检忽略覆盖。
  LOCAL_PATH_PROBES = [
    "openspec/config.yaml",
    "openspec/changes/local-audit/proposal.md",
    ".agents/skills/openspec-audit/SKILL.md",
    ".agents/skills/.openspec-target"
  ].freeze
  DEPRECATED_OPENSPEC_SKILLS = %w[openspec-verify-change].freeze
  # 本机排除块仅写入 Git 私有元数据，不影响团队的忽略规则。
  LOCAL_EXCLUDE_BEGIN = "# BEGIN ai-coding-workflow-manager (local)"
  # 本机排除块结束标记，用于无损清理用户规则。
  LOCAL_EXCLUDE_END = "# END ai-coding-workflow-manager (local)"
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

    # 仅接受本机安装；旧共享模式必须显式迁移。
    def parse(argv, operation)
      options = { apply: false, local: false }
      parser = OptionParser.new do |opts|
        opts.on("--target PATH") { |value| options[:target] = value }
        opts.on("--local") { options[:local] = true }
        opts.on("--portable") { raise Error, "Portable mode was removed; install with --local" }
        opts.on("--apply") { options[:apply] = true }
      end
      parser.parse!(argv)
      raise Error, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      raise Error, "--target is required" unless options[:target]
      raise Error, "--local is valid only for install" if operation != "install" && options[:local]
      raise Error, "--apply is valid only for uninstall" if operation != "uninstall" && options[:apply]
      options
    end

    # 展示本机安装命令及不会变更 Git 索引的边界。
    def help(code)
      @output.puts <<~TEXT
        Usage:
          ruby scripts/workflow_manager.rb install --target PATH [--local]
          ruby scripts/workflow_manager.rb update --target PATH
          ruby scripts/workflow_manager.rb audit --target PATH
          ruby scripts/workflow_manager.rb uninstall --target PATH [--apply]

        Local mode creates AGENTS.md only when absent and excludes installed
        workflow files through .git/info/exclude. Team members install separately.
        It never edits .gitignore, stages, commits, untracks files, installs
        dependencies, or configures Git Hooks. Uninstall is dry-run by default.
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

    # 预检冲突和本机排除文件后安装，避免将工作流带入项目提交。
    def install(root, _options)
      raise Error, "Workflow already has a manifest; use update" if File.exist?(File.join(root, MANIFEST))

      ensure_exclude_safe!(root)
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

      tracked = git_nul(root, "ls-files", "-z", "--", *(install_paths + [MANIFEST] + integration_files(root)))
      unless tracked.empty?
        raise Error, "Local installation cannot own tracked files: #{tracked.join(', ')}; migrate them through the normal Git workflow first"
      end

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
      write_local_exclude(root, checksums.keys)

      tests_ok = run_workflow_tests(root)
      audit_code = audit(root)
      @output.puts "[PASS] workflow files are local-only and Git-ignored" if audit_code.zero?
      tests_ok && audit_code.zero? ? 0 : 1
    end

    # 将旧安装迁移为本机模式，并保留自定义文件和已跟踪内容。
    def update(root)
      ensure_no_symlink_components!(root, [MANIFEST])
      manifest = read_manifest(root)
      ensure_exclude_safe!(root)
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
      tracked = git_nul(root, "ls-files", "-z", "--", *(old.keys + asset_paths + [MANIFEST] + integration_files(root))) - [AGENTS]
      unless tracked.empty?
        raise Error, "Local migration requires removing workflow files from Git tracking first: #{tracked.join(', ')}; no files or index entries changed"
      end

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
            content = File.read(target)
            legacy_prefix = agents_contract_prefixes(root).find do |prefix|
              prefix.include?("Keep it in Git with the other") && content.start_with?(prefix)
            end
            if legacy_prefix
              File.write(target, source_content + content.delete_prefix(legacy_prefix))
              next_hashes[relative] = Digest::SHA256.hexdigest(source_content)
              @output.puts "[WARN] migrated managed #{relative} to local mode; preserved project context"
            else
              @output.puts "[WARN] preserved adapted #{relative}"
            end
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
      write_local_exclude(root, next_hashes.keys)
      tests_ok = run_workflow_tests(root)
      audit_code = audit(root)
      return 1 unless conflicts.empty?
      tests_ok && audit_code.zero? ? 0 : 1
    end

    # 同时验证安装完整性、本机排除规则和未被 Git 跟踪的状态。
    def audit(root)
      ensure_no_symlink_components!(root, [MANIFEST])
      manifest = read_manifest(root)
      ensure_exclude_safe!(root)
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

      local_files = manifest.fetch("files").keys + [MANIFEST] + integration
      tracked = git_nul(root, "ls-files", "-z", "--", *local_files)
      # 已有项目 AGENTS.md 仍由项目管理；仅审计本工具拥有的入口文件。
      local_files -= [AGENTS] unless manifest.fetch("files").key?(AGENTS)
      tracked &= local_files
      failed |= report_check(tracked.empty?, "workflow files are not tracked", "Already tracked: #{tracked.join(', ')}; ignore rules cannot untrack files")
      unignored = local_files.reject { |path| git_success?(root, "check-ignore", "--no-index", "-q", "--", path) }
      failed |= report_check(unignored.empty?, "workflow files are locally ignored", unignored.join(", "))
      failed |= report_check(local_exclude_present?(root), "local exclusion block exists", "run update to restore .git/info/exclude")

      executable = File.executable?(File.join(root, "Scripts/ai-workflow"))
      failed |= report_check(executable, "Scripts/ai-workflow is executable", "chmod +x required")
      failed |= !syntax_checks(root)

      unignored_probes = LOCAL_PATH_PROBES.reject do |path|
        git_success?(root, "check-ignore", "--no-index", "-q", "--", path)
      end
      failed |= report_check(unignored_probes.empty?, "future OpenSpec paths are locally ignored", unignored_probes.join(", "))
      failed |= report_check(!legacy_exclude_present?(root), "legacy personal exclusion is absent", "run update to migrate the old manager block")

      @output.puts(failed ? "[FAIL] audit" : "[PASS] audit")
      failed ? 1 : 0
    end

    # 仅删除校验值匹配的本机文件；残留自定义内容继续保持忽略。
    def uninstall(root, apply: false)
      ensure_no_symlink_components!(root, [MANIFEST])
      ensure_exclude_safe!(root) if apply
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
        @output.puts "[WARN] preserve external OpenSpec files: #{external.length}; their local exclusions are retained"
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
      remaining = preserved.select { |relative| File.file?(File.join(root, relative)) }
      local_metadata = Dir.glob(File.join(root, ".ai-workflow", "**", "*"), File::FNM_DOTMATCH)
        .any? { |path| File.file?(path) || File.symlink?(path) }
      if remaining.empty? && external.empty? && !local_metadata && !File.exist?(File.join(root, MANIFEST))
        remove_manager_exclude_blocks(root)
      else
        @output.puts "[WARN] retained local exclusion block for preserved files"
      end
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

    # 通过 Git 解析私有元数据位置，同时支持普通仓库和 linked worktree。
    def exclude_path(root)
      stdout, stderr, status = Open3.capture3("git", "-C", root, "rev-parse", "--git-path", "info/exclude")
      raise Error, "Cannot resolve Git exclude path: #{stderr.strip}" unless status.success? && !stdout.strip.empty?
      File.expand_path(stdout.strip, root)
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

    # 兼容旧共享模板的项目上下文追加，仍要求完整的原始协作契约。
    def agents_contract_prefixes(root)
      current = desired_content(AGENTS, root)
      old_intro = "project did not already provide `AGENTS.md`. Keep it in Git with the other\nworkflow definitions so every device receives the same collaboration contract."
      local_intro = "project did not already provide `AGENTS.md`. This generated entry and the other\ninstalled workflow definitions are personal files excluded through\n`.git/info/exclude`. Do not add them to project commits; other team members\ninstall their own workflow. Preserve an existing project-owned `AGENTS.md`."
      legacy = current.sub(local_intro, old_intro)
      old_comments = <<~TEXT.chomp
        Follow the Chinese comments contract in `WORKFLOW.md` for newly added or
        modified code. Every newly added or modified type member property requires a
        concise Chinese documentation comment, even when its name and type are
        self-explanatory. This is not a requirement to comment every method or narrate
        straightforward implementation code.
      TEXT
      legacy_properties = legacy.sub(/(?<=## Code Comments\n\n).*?(?=\n\n## Specification And Method)/m, old_comments)
      [current, legacy, legacy_properties].flat_map do |template|
        [template, template.sub(/\n## Code Comments\n.*?(?=\n## Specification And Method)/m, "")]
      end.uniq
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

    # 拒绝符号链接或损坏的标记块，避免改写仓库外的用户文件。
    def ensure_exclude_safe!(root)
      path = exclude_path(root)
      current = path
      loop do
        raise Error, "Git exclude path must not be a symlink: #{current}" if File.symlink?(current)
        break if File.dirname(current) == current
        current = File.dirname(current)
      end
      raise Error, "Git exclude path must be a regular file" if File.exist?(path) && !File.file?(path)
      content = File.file?(path) ? File.read(path) : ""
      [[LOCAL_EXCLUDE_BEGIN, LOCAL_EXCLUDE_END], [LEGACY_EXCLUDE_BEGIN, LEGACY_EXCLUDE_END]].each do |first, last|
        starts = content.lines.count { |line| line.chomp == first }
        ends = content.lines.count { |line| line.chomp == last }
        valid = starts == 0 && ends == 0 || starts == 1 && ends == 1 && content.index(first) < content.index(last)
        raise Error, "Invalid workflow exclude block; reconcile it before changes" unless valid
      end
    end

    # 识别旧个人模式标记，以便更新时只迁移本工具自己的规则。
    def legacy_exclude_present?(root)
      path = exclude_path(root)
      File.file?(path) && File.readlines(path, chomp: true).include?(LEGACY_EXCLUDE_BEGIN)
    end

    # 本机标记是安装完整性的一部分，不能只依赖全局忽略配置。
    def local_exclude_present?(root)
      path = exclude_path(root)
      File.file?(path) && File.readlines(path, chomp: true).include?(LOCAL_EXCLUDE_BEGIN)
    end

    # 生成精确路径；只排除工作流和 OpenSpec，不屏蔽整个 .codex 或 .agents。
    def local_exclude_patterns(paths)
      patterns = paths.reject { |path| path.start_with?(".ai-workflow/") }.map do |path|
        "/" + path.gsub(/[\\*?\[\]#! ]/) { |char| "\\#{char}" }
      end
      (patterns + ["/.ai-workflow/", "/openspec/", "/.agents/skills/openspec-*/", "/.agents/skills/.openspec-target"]).uniq.sort
    end

    # 从文本移除完整管理块，保留用户自行维护的所有其他规则。
    def without_manager_exclude_blocks(content)
      endings = { LOCAL_EXCLUDE_BEGIN => LOCAL_EXCLUDE_END, LEGACY_EXCLUDE_BEGIN => LEGACY_EXCLUDE_END }
      closing = nil
      content.each_line.each_with_object(String.new) do |line, kept|
        marker = line.chomp
        if closing
          closing = nil if marker == closing
        elsif endings.key?(marker)
          closing = endings.fetch(marker)
        else
          kept << line
        end
      end
    end

    # 安装和更新共用同一排除块，重复执行不会追加重复规则。
    def write_local_exclude(root, paths)
      ensure_exclude_safe!(root)
      path = exclude_path(root)
      content = File.file?(path) ? File.read(path) : ""
      content = without_manager_exclude_blocks(content)
      content += "\n" unless content.empty? || content.end_with?("\n")
      block = ([LOCAL_EXCLUDE_BEGIN] + local_exclude_patterns(paths) + [LOCAL_EXCLUDE_END, ""]).join("\n")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content + block)
    end

    # 完全卸载时清理本工具的规则，不删除用户原有的忽略项。
    def remove_manager_exclude_blocks(root)
      ensure_exclude_safe!(root)
      path = exclude_path(root)
      return unless File.file?(path)
      File.write(path, without_manager_exclude_blocks(File.read(path)))
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
