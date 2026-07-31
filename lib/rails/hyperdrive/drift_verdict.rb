require "digest"
require "rails/hyperdrive/audit_header"

module Rails
  module Hyperdrive
    # The lock's source_sha is computed over the install-ready body before any
    # header injection, so hashing an installed file's comparable bytes
    # (disk_sha) reproduces it exactly for an unedited file.
    module DriftVerdict
      STATES = %i[current outdated edited missing orphaned].freeze

      module_function

      # The install-ready body's hash — what the lock records as source_sha.
      def body_sha(content)
        Digest::SHA256.hexdigest(content.to_s)
      end

      # AuditHeader.strip's line matching can raise on binary content, so
      # skill_support files compare as raw bytes.
      def disk_sha(file, kind:)
        return body_sha(File.binread(file)) if kind.to_s == "skill_support"
        body_sha(AuditHeader.strip(File.read(file)))
      end

      # A file counts as unedited when its comparable bytes still hash to what
      # the lock recorded at install time, not to what the gem ships now.
      def unedited?(file, lock_entry:)
        disk_sha(file, kind: lock_entry.kind) == lock_entry.source_sha
      end

      # gem_sha nil means the bundle no longer offers this destination.
      def verdict(file:, kind:, lock_entry:, gem_sha:)
        return File.exist?(file) ? :orphaned : :missing if gem_sha.nil?
        return :missing unless File.exist?(file)
        return :edited if lock_entry.nil?
        return :edited if disk_sha(file, kind: kind) != lock_entry.source_sha
        lock_entry.source_sha == gem_sha ? :current : :outdated
      end
    end
  end
end
