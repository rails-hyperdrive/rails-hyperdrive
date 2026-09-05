require "yaml"
require "rails/hyperdrive/install_layout"

module Rails
  module Hyperdrive
    # The hand-owned settings file: which artifacts never to install, and which
    # gems to treat as companions. Fail-open — a malformed part warns and reads
    # as absent, and nothing raises.
    class ConfigFile
      DISABLED_KEYS = { skill: "skills", guideline: "guidelines", agent: "agents", command: "commands" }.freeze

      attr_reader :path, :warnings, :resolve_command, :resolve_prompt

      def self.load(path)
        new(path).tap(&:read)
      end

      def initialize(path)
        @path = path.to_s
        @disabled = empty_disabled
        @enabled = []
        @warnings = []
      end

      def exist?
        File.file?(@path)
      end

      def read
        return self unless File.file?(@path)

        data = YAML.safe_load(File.read(@path))
        return self if data.nil?
        return warn_and_empty("root is not a map; reading it as empty") unless data.is_a?(Hash)

        read_disabled(data["disabled"])
        read_enabled(data["enabled"])
        read_resolve(data["resolve"])
        self
      rescue StandardError => e
        warn_and_empty("could not be parsed (#{first_line(e.message)}); reading it as empty")
      end

      def disabled?(type, name)
        Array(@disabled[type.to_sym]).include?(name.to_s)
      end

      def enabled_gems
        @enabled
      end

      private

      def read_disabled(raw)
        return if raw.nil?
        return report("disabled: must be a map of kind to list; ignoring it") unless raw.is_a?(Hash)

        DISABLED_KEYS.each do |type, key|
          value = raw[key]
          next if value.nil?
          unless value.is_a?(Array)
            report("disabled: #{key}: must be a list of names; ignoring it")
            next
          end
          @disabled[type] = normalize(value)
        end
      end

      def read_resolve(raw)
        return if raw.nil?
        return report("resolve: must be a map; ignoring it") unless raw.is_a?(Hash)

        @resolve_command = read_resolve_command(raw["command"])
        @resolve_prompt = read_resolve_prompt(raw["prompt"])
      end

      def read_resolve_command(value)
        return nil if value.nil?
        return value.strip if value.is_a?(String) && !value.strip.empty?

        report("resolve: command: must be a non-empty string; ignoring it")
        nil
      end

      # The prompt is read relative to the app root; a path that escapes it is
      # refused.
      def read_resolve_prompt(value)
        return nil if value.nil?
        unless value.is_a?(String) && !value.strip.empty?
          report("resolve: prompt: must be a non-empty string; ignoring it")
          return nil
        end

        prompt = value.strip
        if prompt.split("/").include?("..") || prompt.start_with?("/")
          report("resolve: prompt: must be a path inside the app; ignoring it")
          return nil
        end
        prompt
      end

      def read_enabled(raw)
        return if raw.nil?
        return report("enabled: must be a list of gem names; ignoring it") unless raw.is_a?(Array)

        @enabled = normalize(raw)
      end

      def normalize(list)
        list.map { |name| name.to_s.strip }.reject(&:empty?).uniq
      end

      def warn_and_empty(message)
        report(message)
        @disabled = empty_disabled
        @enabled = []
        @resolve_command = nil
        @resolve_prompt = nil
        self
      end

      def report(message)
        @warnings << "#{InstallLayout::CONFIG_PATH} #{message}"
      end

      def first_line(message)
        message.to_s.lines.first.to_s.strip
      end

      def empty_disabled
        DISABLED_KEYS.keys.each_with_object({}) { |type, h| h[type] = [] }
      end
    end
  end
end
