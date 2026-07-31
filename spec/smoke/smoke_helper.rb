require "fileutils"
require "json"
require "net/http"
require "open3"
require "socket"
require "tmpdir"
require "uri"

# Smoke helper — shared utilities for end-to-end tests that exercise the
# `hyperdrive:init` CLI and the `/_hyperdrive/mcp` HTTP endpoint against a real Rails
# app subprocess.
#
# Smoke specs are tagged `:smoke` and excluded by default; run with
# `bundle exec rspec --tag smoke`.
module Smoke
  REPO_ROOT = File.expand_path("../..", __dir__).freeze
  FIXTURES_ROOT = File.join(REPO_ROOT, "spec/fixtures/smoke_apps").freeze
  # Fixture-only companion gems (real path gems, each shipping hyperdrive
  # skills/guidelines) used to exercise the install pipeline end-to-end.
  COMPANIONS_ROOT = File.join(REPO_ROOT, "spec/fixtures/smoke_companions").freeze
  TMP_ROOT = File.join(REPO_ROOT, "spec/tmp/smoke").freeze
  # Shared bundle cache across scenarios so only the first install pays the
  # full network cost; subsequent scenarios reuse the resolved gems.
  BUNDLE_PATH = File.join(REPO_ROOT, "spec/tmp/smoke-bundle").freeze

  module_function

  # Copy a fixture into a fresh tmpdir and return its absolute path.
  def copy_fixture(name)
    src = File.join(FIXTURES_ROOT, name)
    raise "unknown fixture: #{name}" unless Dir.exist?(src)

    FileUtils.mkdir_p(TMP_ROOT)
    dest = Dir.mktmpdir("#{name}-", TMP_ROOT)
    # cp -a so executable bits on bin/* survive.
    sh!("cp", "-a", "#{src}/.", dest)
    dest
  end

  # Append `gem "rails-hyperdrive", path: REPO_ROOT` to the Gemfile so the
  # subprocess resolves against the working tree of this gem.
  def add_path_gem!(app_dir)
    gemfile = File.join(app_dir, "Gemfile")
    line = %(gem "rails-hyperdrive", path: #{REPO_ROOT.inspect}\n)
    File.open(gemfile, "a") { |f| f.write(line) }
  end

  # Append a fixture companion gem (e.g. "rails-hyperdrive-alpha") as a path
  # gem so the subprocess bundle resolves it and the installer discovers its
  # shipped skills/guidelines.
  def add_companion_gem!(app_dir, gem_name)
    path = File.join(COMPANIONS_ROOT, gem_name)
    raise "unknown companion: #{gem_name}" unless Dir.exist?(path)

    gemfile = File.join(app_dir, "Gemfile")
    line = %(gem #{gem_name.inspect}, path: #{path.inspect}\n)
    File.open(gemfile, "a") { |f| f.write(line) }
  end

  # Run `bundle install` against the app, sharing BUNDLE_PATH across calls.
  # Bundler.with_unbundled_env scrubs parent-process bundler vars so the
  # subprocess resolves the app's own Gemfile.
  def bundle_install!(app_dir)
    FileUtils.mkdir_p(BUNDLE_PATH)
    Bundler.with_unbundled_env do
      out, status = Open3.capture2e(
        env_for(app_dir),
        "bundle", "install",
        chdir: app_dir
      )
      raise "bundle install failed:\n#{out}" unless status.success?
    end
  end

  # Run `bin/rails hyperdrive:init` against the app. The `--` separator is
  # required because Rails' command runner parses `--flag` itself unless
  # told to stop. Returns [stdout_plus_stderr, status].
  def run_hyperdrive_init!(app_dir, *flags)
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir),
        "bundle", "exec", "bin/rails", "hyperdrive:init", "--", *flags,
        chdir: app_dir
      )
    end
  end

  # Run `bin/rails hyperdrive:update` against the app — same pipeline as init
  # but force-overwrites locally-modified files. Returns [stdout_plus_stderr,
  # status].
  def run_hyperdrive_update!(app_dir, *flags)
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir),
        "bundle", "exec", "bin/rails", "hyperdrive:update", "--", *flags,
        chdir: app_dir
      )
    end
  end

  # Run `bin/rails hyperdrive:discover` against the app. Same `--` plumbing
  # as init. Returns [stdout_plus_stderr, status]. Read-only and networked —
  # the command never raises, so a non-success status is itself a failure.
  def run_hyperdrive_discover!(app_dir, *flags)
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir),
        "bundle", "exec", "bin/rails", "hyperdrive:discover", "--", *flags,
        chdir: app_dir
      )
    end
  end

  # Run a Ruby snippet against the app's bundle with no Rails application
  # booted. Returns [stdout_plus_stderr, status].
  def run_ruby!(app_dir, snippet, env = {})
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir).merge(env),
        "bundle", "exec", "ruby", "-e", snippet,
        chdir: app_dir
      )
    end
  end

  # Boot `bin/rails server` in the background on a random port. Returns
  # [pid, port]. Caller is responsible for killing the pid via stop_server!.
  def boot_server!(app_dir)
    port = pick_free_port
    pid = nil
    Bundler.with_unbundled_env do
      pid = Process.spawn(
        env_for(app_dir),
        "bundle", "exec", "bin/rails", "server",
        "-p", port.to_s, "-b", "127.0.0.1",
        chdir: app_dir,
        out: File.join(app_dir, "server.log"),
        err: [:child, :out]
      )
    end
    wait_for_port(port, timeout: 30) or begin
      stop_server!(pid)
      raise "server never opened port #{port}; log:\n#{File.read(File.join(app_dir, 'server.log'))}"
    end
    [pid, port]
  end

  def stop_server!(pid)
    return unless pid
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  end

  # JSON-RPC POST to the MCP endpoint. Returns the parsed result, or raises
  # with the error payload.
  def mcp_call(port, method, params = {}, mount: "/_hyperdrive")
    uri = URI("http://127.0.0.1:#{port}#{mount}/mcp")
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json, text/event-stream"
    req["Origin"] = "http://localhost"
    req.body = JSON.dump({jsonrpc: "2.0", id: rand(1_000_000), method: method, params: params})
    res = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |h| h.request(req) }
    raise "MCP #{method} returned #{res.code}: #{res.body}" unless res.code.to_i == 200
    JSON.parse(res.body)
  end

  # ---------- internals ----------

  def env_for(app_dir)
    {
      "BUNDLE_GEMFILE" => File.join(app_dir, "Gemfile"),
      "BUNDLE_PATH" => BUNDLE_PATH,
      "RAILS_ENV" => "development",
      # Bundler config sometimes contains a frozen flag from the parent
      # repo. Unset to be safe.
      "BUNDLE_FROZEN" => nil,
      "BUNDLE_DEPLOYMENT" => nil
    }
  end

  def pick_free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_for_port(port, timeout:)
    deadline = Time.now + timeout
    while Time.now < deadline
      begin
        TCPSocket.new("127.0.0.1", port).close
        return true
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        sleep 0.2
      end
    end
    false
  end

  def sh!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "command failed (#{cmd.join(' ')}):\n#{out}" unless status.success?
    out
  end
end
