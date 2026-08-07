require "digest"

module Rails
  module Hyperdrive
    # Installed files are byte-identical to their install-ready body, so an
    # unedited file's disk hash reproduces the lock's source_sha exactly.
    module DriftVerdict
      STATES = %i[current outdated edited missing orphaned].freeze

      module_function

      # The install-ready body's hash — what the lock records as source_sha.
      def body_sha(content)
        Digest::SHA256.hexdigest(content.to_s)
      end

      def disk_sha(file)
        body_sha(File.binread(file))
      end

      # A file counts as unedited when its bytes still hash to what the lock
      # recorded at install time, not to what the gem ships now.
      def unedited?(file, lock_entry:)
        disk_sha(file) == lock_entry.source_sha
      end

      # gem_sha nil means the bundle no longer offers this destination.
      def verdict(file:, lock_entry:, gem_sha:)
        return File.exist?(file) ? :orphaned : :missing if gem_sha.nil?
        return :missing unless File.exist?(file)
        return :edited if lock_entry.nil?
        return :edited if disk_sha(file) != lock_entry.source_sha
        lock_entry.source_sha == gem_sha ? :current : :outdated
      end
    end
  end
end
