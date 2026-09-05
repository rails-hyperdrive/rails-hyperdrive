require "open3"
require "shellwords"
require "tmpdir"
require "rails/hyperdrive/ancestor_locator"
require "rails/hyperdrive/drift_verdict"
require "rails/hyperdrive/install_layout"
require "rails/hyperdrive/resolve_prompt"

module Rails
  module Hyperdrive
    # Hands each unresolved <dest>.new sidecar to the user's resolver command,
    # git-mergetool style, and deletes the sidecar when it exits 0. Nothing here
    # writes the lock: the sidecar's absence is the whole resolution signal.
    class SidecarResolver
      TOKENS = %w[LOCAL REMOTE BASE MERGED SOURCE PREVIOUS_SOURCE KIND PROMPT].freeze
      TOKEN_PATTERN = /\$(#{TOKENS.sort_by { |t| -t.length }.join("|")})\b/

      Outcome = Struct.new(:resolved, :unresolved, :skipped, keyword_init: true)

      Candidate = Struct.new(:dest, :sidecar, :kind, :source, :previous_source, :ancestor, :delivered,
        keyword_init: true)

      def initialize(root:, shell:, command:, lock:, sidecars: [], prompt_path: nil, dry_run: false)
        @root = File.expand_path(root.to_s)
        @shell = shell
        @command = command.to_s
        @lock = lock
        @sidecars = Array(sidecars)
        @prompt_path = prompt_path
        @dry_run = dry_run
        @outcome = Outcome.new(resolved: [], unresolved: [], skipped: [])
      end

      def call
        candidates.each { |candidate| process(candidate) }
        @outcome
      end

      private

      def candidates
        written = @sidecars.to_h { |s| [s.dest.to_s, s] }
        list = []
        @lock.each_entry do |entry|
          sidecar = InstallLayout.sidecar_path(entry.path)
          delivered = written[entry.path.to_s]
          # A dry run wrote no sidecar to disk, so this run's deliveries are
          # only knowable from the pipeline result.
          next unless delivered || File.file?(abs(sidecar))

          list << Candidate.new(
            dest: entry.path,
            sidecar: sidecar,
            kind: entry.kind.to_s,
            source: entry.source_label.to_s,
            # A sidecar left over from an earlier run has no struct, so the
            # base comes back from the ancestor the lock recorded with it.
            previous_source: delivered&.previous_source || entry.ancestor_label,
            ancestor: delivered&.ancestor || AncestorLocator.locate_recorded_ancestor(entry),
            delivered: !delivered.nil?
          )
        end
        list
      end

      def process(candidate)
        unless candidate.delivered || pristine?(candidate)
          @outcome.skipped << candidate.dest
          @shell.say_status :warn,
            "#{candidate.sidecar} (sidecar locally modified; resolve or delete it by hand)", :yellow
          return
        end

        tokens = command_tokens
        return unresolved(candidate, "resolve: command: is not a valid command line") if tokens.nil?
        return unresolved(candidate, "resolve: command: names no program") if tokens.empty?

        if @dry_run
          @shell.say_status :resolve, "#{candidate.dest} (would run #{tokens.first})", :yellow
          return
        end

        run(candidate, tokens)
      end

      def command_tokens
        Shellwords.split(@command)
      rescue ArgumentError
        nil
      end

      # A sidecar is machine-written only while it still hashes to the upstream
      # the lock records as delivered; anything else is the user's own work.
      def pristine?(candidate)
        entry = @lock.entry(candidate.dest)
        return false unless entry
        DriftVerdict.disk_sha(abs(candidate.sidecar)) == entry.source_sha
      rescue StandardError
        false
      end

      def run(candidate, tokens)
        Dir.mktmpdir("hyperdrive-resolve") do |dir|
          base = write_base(candidate, dir)
          values = values_for(candidate, base: base)
          argv = substitute(tokens, values, base: base)
          @shell.say_status :resolve, "#{candidate.dest} via #{argv.first}", :blue
          _out, err, status = Open3.capture3(env_for(values), *argv, chdir: @root)
          if status.success?
            # Exit 0 is the tool's assertion that the file is resolved, so the
            # sidecar goes even if the tool never wrote $MERGED.
            resolved(candidate)
          else
            unresolved(candidate, "exit #{status.exitstatus}#{detail(err)}")
          end
        end
      rescue StandardError => e
        unresolved(candidate, first_line(e.message))
      end

      def resolved(candidate)
        @shell.remove_file candidate.sidecar
        @outcome.resolved << candidate.dest
        @shell.say_status :resolved, candidate.dest, :green
      end

      def unresolved(candidate, reason)
        @outcome.unresolved << { dest: candidate.dest, reason: reason }
        @shell.say_status :unresolved, "#{candidate.dest} (#{reason})", :yellow
      end

      def write_base(candidate, dir)
        return nil unless candidate.ancestor

        File.join(dir, "base-#{File.basename(candidate.dest)}").tap do |file|
          File.binwrite(file, candidate.ancestor)
        end
      end

      # Substitution runs per token after the split, so a value holding spaces
      # stays one argument.
      def substitute(tokens, values, base:)
        tokens.each_with_object([]) do |token, argv|
          next if base.nil? && token == "$BASE"
          argv << token.gsub(TOKEN_PATTERN) { values[Regexp.last_match(1)].to_s }
        end
      end

      def env_for(values)
        values.to_h { |name, value| ["HYPERDRIVE_#{name}", value] }
      end

      def values_for(candidate, base:)
        live = abs(candidate.dest)
        values = {
          "LOCAL" => live,
          "REMOTE" => abs(candidate.sidecar),
          # A nil BASE substitutes empty and unsets HYPERDRIVE_BASE in the
          # child, so an outer HYPERDRIVE_BASE can never leak into a run.
          "BASE" => base,
          "MERGED" => live,
          "SOURCE" => candidate.source,
          "PREVIOUS_SOURCE" => candidate.previous_source.to_s,
          "KIND" => candidate.kind
        }
        values["PROMPT"] = prompt(candidate, base: base, values: values)
        values
      end

      def prompt(candidate, base:, values:)
        knobs = {
          local: values["LOCAL"], remote: values["REMOTE"], base: base, merged: values["MERGED"],
          source: candidate.source, previous_source: candidate.previous_source, kind: candidate.kind
        }
        template = user_template
        return ResolvePrompt.render(template, **knobs) if template

        ResolvePrompt.render(ResolvePrompt.default_template, **knobs)
      rescue StandardError => e
        raise unless template
        @shell.say_status :warn,
          "resolve: prompt: #{@prompt_path} could not be rendered (#{first_line(e.message)}); using the default prompt",
          :yellow
        @user_template = false
        ResolvePrompt.render(ResolvePrompt.default_template, **knobs)
      end

      def user_template
        return nil unless @prompt_path
        return nil if @user_template == false

        @user_template ||= File.read(abs(@prompt_path))
      rescue StandardError => e
        @shell.say_status :warn,
          "resolve: prompt: #{@prompt_path} could not be read (#{first_line(e.message)}); using the default prompt",
          :yellow
        @user_template = false
        nil
      end

      def detail(stderr)
        line = first_line(stderr)
        line.empty? ? "" : ": #{line}"
      end

      def first_line(message)
        message.to_s.lines.first.to_s.strip
      end

      def abs(path)
        File.join(@root, path)
      end
    end
  end
end
