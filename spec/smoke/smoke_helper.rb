require "fileutils"
require "json"
require "net/http"
require "open3"
require "socket"
require "pathname"
require "tmpdir"
require "uri"

module Smoke
  REPO_ROOT = File.expand_path("../..", __dir__).freeze
  FIXTURES_ROOT = File.join(REPO_ROOT, "spec/fixtures/smoke_apps").freeze
  COMPANIONS_ROOT = File.join(REPO_ROOT, "spec/fixtures/smoke_companions").freeze
  PLUGIN_ROOT = File.join(REPO_ROOT, "bundler-hyperdrive").freeze
  TMP_ROOT = File.join(REPO_ROOT, "spec/tmp/smoke").freeze
  # Shared bundle cache across scenarios so only the first install pays the
  # full network cost; subsequent scenarios reuse the resolved gems.
  BUNDLE_PATH = File.join(REPO_ROOT, "spec/tmp/smoke-bundle").freeze

  # A rubygems outage or a throttled runner is not a hyperdrive failure, so a
  # fetch that reads as transient is retried once before the run is failed.
  TRANSIENT_BUNDLE_FAILURE = /
    Could\ not\ fetch | Network\ error | Gem::RemoteFetcher | FetchError |
    Net::(Open|Read)Timeout | Errno::(ECONNRESET|ETIMEDOUT|ECONNREFUSED) |
    SSL_connect | Connection\ reset | Too\ many\ requests | Retrying\ fetcher
  /xi

  @tmp_dirs = []

  module_function

  # Every scenario directory is tracked so a passing example can take its own
  # copies with it; a failed one keeps them for post-mortem.
  def track_tmp_dir(dir)
    @tmp_dirs << dir
    dir
  end

  def reset_tmp_dirs!
    @tmp_dirs = []
  end

  def cleanup_tmp_dirs!
    @tmp_dirs.each { |dir| FileUtils.rm_rf(dir) }
    reset_tmp_dirs!
  end

  def copy_fixture(name)
    src = File.join(FIXTURES_ROOT, name)
    raise "unknown fixture: #{name}" unless Dir.exist?(src)

    FileUtils.mkdir_p(TMP_ROOT)
    dest = Dir.mktmpdir("#{name}-", TMP_ROOT)
    # cp -a so executable bits on bin/* survive.
    sh!("cp", "-a", "#{src}/.", dest)
    track_tmp_dir(dest)
  end

  # A standalone copy of a companion gem, outside any app: the shape a
  # companion repo's own tooling runs against.
  def copy_companion(gem_name)
    src = File.join(COMPANIONS_ROOT, gem_name)
    raise "unknown companion: #{gem_name}" unless Dir.exist?(src)

    FileUtils.mkdir_p(TMP_ROOT)
    dest = File.join(Dir.mktmpdir("#{gem_name}-", TMP_ROOT), gem_name)
    FileUtils.mkdir_p(dest)
    sh!("cp", "-a", "#{src}/.", dest)
    track_tmp_dir(File.dirname(dest))
    dest
  end

  # Registering the plugin in every fixture makes each smoke `bundle install`
  # a standing check that the hook never breaks an install.
  def add_path_gem!(app_dir)
    gemfile = File.join(app_dir, "Gemfile")
    lines = %(gem "rails-hyperdrive", path: #{REPO_ROOT.inspect}\n) +
            %(plugin "bundler-hyperdrive", path: #{PLUGIN_ROOT.inspect}\n)
    File.open(gemfile, "a") { |f| f.write(lines) }
  end

  def add_companion_gem!(app_dir, gem_name)
    path = File.join(COMPANIONS_ROOT, gem_name)
    raise "unknown companion: #{gem_name}" unless Dir.exist?(path)

    add_gemfile_line!(app_dir, gem_name, path)
  end

  # A per-app copy of a companion, so a scenario can change what the gem ships
  # without touching the checked-in fixture.
  def vendor_companion!(app_dir, gem_name, into: "vendor/#{gem_name}")
    src = File.join(COMPANIONS_ROOT, gem_name)
    raise "unknown companion: #{gem_name}" unless Dir.exist?(src)

    dest = File.join(app_dir, into)
    FileUtils.mkdir_p(dest)
    sh!("cp", "-a", "#{src}/.", dest)
    add_gemfile_line!(app_dir, gem_name, dest)
    dest
  end

  # A gem carrying no hyperdrive signal at all: no manifest, no metadata, just
  # a top-level skills.sh skill.
  def write_plain_gem!(app_dir, name:, skill:)
    dir = File.join(app_dir, "vendor", name)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    FileUtils.mkdir_p(File.join(dir, "skills", skill))

    File.write(File.join(dir, "#{name}.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name        = #{name.inspect}
        spec.version     = "0.1.0"
        spec.authors     = ["Smoke Fixture"]
        spec.email       = ["smoke@example.com"]
        spec.summary     = "Smoke-test gem shipping a skills.sh skill with no hyperdrive signal."
        spec.homepage    = "https://example.com/#{name}"
        spec.license     = "MIT"
        spec.files       = Dir["lib/**/*", "skills/**/*"]
        spec.require_paths = ["lib"]
      end
    RUBY
    File.write(File.join(dir, "lib", "#{name}.rb"), "module #{name.split(/[-_]/).map(&:capitalize).join}; end\n")
    File.write(File.join(dir, "skills", skill, "SKILL.md"), <<~MD)
      ---
      name: #{skill}
      description: A skills.sh skill shipped by a gem that never opted in.
      ---

      # #{skill}

      Installed only when the app names this gem in enabled:.
    MD

    add_gemfile_line!(app_dir, name, dir)
    dir
  end

  def add_gemfile_line!(app_dir, gem_name, path)
    File.open(File.join(app_dir, "Gemfile"), "a") do |f|
      f.write(%(gem #{gem_name.inspect}, path: #{path.inspect}\n))
    end
    path
  end

  # Bundler.with_unbundled_env scrubs parent-process bundler vars so the
  # subprocess resolves the app's own Gemfile.
  def bundle_install!(app_dir, env = {})
    FileUtils.mkdir_p(BUNDLE_PATH)
    out, status = run_bundle_install(app_dir, env)
    if !status.success? && out.match?(TRANSIENT_BUNDLE_FAILURE)
      sleep 5
      out, status = run_bundle_install(app_dir, env)
    end
    raise "bundle install failed:\n#{out}" unless status.success?
    out
  end

  def run_bundle_install(app_dir, env)
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir).merge(env),
        "bundle", "install",
        chdir: app_dir
      )
    end
  end

  # chdir: names the cwd the subprocess runs in; the rails binary is resolved
  # relative to it, so a run from a subdirectory exercises the real invocation.
  def run_hyperdrive_init!(app_dir, *flags, chdir: app_dir)
    rails_bin = Pathname.new(File.join(app_dir, "bin/rails")).relative_path_from(Pathname.new(chdir)).to_s
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir),
        "bundle", "exec", rails_bin, "hyperdrive:init", *flags,
        chdir: chdir
      )
    end
  end

  def run_hyperdrive_sync!(app_dir, *flags)
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir),
        "bundle", "exec", "bin/rails", "hyperdrive:sync", *flags,
        chdir: app_dir
      )
    end
  end

  # The command never raises, so a non-success status is itself a failure.
  def run_hyperdrive_discover!(app_dir, *flags)
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir),
        "bundle", "exec", "bin/rails", "hyperdrive:discover", *flags,
        chdir: app_dir
      )
    end
  end

  def run_ruby!(app_dir, snippet, env = {})
    Bundler.with_unbundled_env do
      Open3.capture2e(
        env_for(app_dir).merge(env),
        "bundle", "exec", "ruby", "-e", snippet,
        chdir: app_dir
      )
    end
  end

  # A companion repo has no app bundle: the tasks run against this checkout's
  # lib on the load path and nothing else.
  def run_rake_in_companion!(dir, task)
    Bundler.with_unbundled_env do
      Open3.capture2e(
        { "BUNDLE_GEMFILE" => nil },
        "ruby", "-I", File.join(REPO_ROOT, "lib"), "-S", "rake", task,
        chdir: dir
      )
    end
  end

  # The caller owns the returned pid and must pass it to stop_server!.
  # A port picked and released is only free until something else claims it, and
  # a bound socket cannot be handed to `rails server`, so the race is retried.
  def boot_server!(app_dir, env: {})
    log = File.join(app_dir, "server.log")
    last_log = nil
    3.times do
      port = pick_free_port
      File.write(log, "")
      pid = Bundler.with_unbundled_env do
        Process.spawn(
          env_for(app_dir).merge(env),
          "bundle", "exec", "bin/rails", "server",
          "-p", port.to_s, "-b", "127.0.0.1",
          chdir: app_dir,
          out: log,
          err: [:child, :out]
        )
      end

      case wait_for_port(port, timeout: 30, pid: pid)
      when true
        return [pid, port]
      when :exited
        last_log = File.read(log)
        raise "server exited during boot; log:\n#{last_log}" unless last_log.match?(/EADDRINUSE|Address already in use/)
      else
        stop_server!(pid)
        raise "server never opened port #{port}; log:\n#{File.read(log)}"
      end
    end
    raise "server lost the port race three times; log:\n#{last_log}"
  end

  def stop_server!(pid)
    return unless pid
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  end

  # Returns [status, body] so a caller can assert on a refusal.
  def mcp_post(port, method, params = {}, mount: "/_hyperdrive", origin: "http://localhost")
    uri = URI("http://127.0.0.1:#{port}#{mount}/mcp")
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json, text/event-stream"
    req["Origin"] = origin if origin
    req.body = JSON.dump({jsonrpc: "2.0", id: rand(1_000_000), method: method, params: params})
    res = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |h| h.request(req) }
    [res.code.to_i, res.body]
  end

  def mcp_call(port, method, params = {}, mount: "/_hyperdrive", origin: "http://localhost")
    status, body = mcp_post(port, method, params, mount: mount, origin: origin)
    raise "MCP #{method} returned #{status}: #{body}" unless status == 200
    JSON.parse(body)
  end

  # Bundler runs app subprocesses with GEM_PATH scoped to BUNDLE_PATH's ruby
  # scope, so this is the one gem home an ancestor lookup can see.
  def gem_home
    File.join(BUNDLE_PATH, Gem.ruby_engine, RbConfig::CONFIG["ruby_version"])
  end

  def remove_from_gem_home!(gem_name, version)
    FileUtils.rm_rf(File.join(gem_home, "gems", "#{gem_name}-#{version}"))
    FileUtils.rm_rf(File.join(gem_home, "doc", "#{gem_name}-#{version}"))
    FileUtils.rm_f(File.join(gem_home, "specifications", "#{gem_name}-#{version}.gemspec"))
    FileUtils.rm_f(File.join(gem_home, "cache", "#{gem_name}-#{version}.gem"))
  end

  def env_for(app_dir)
    {
      "BUNDLE_GEMFILE" => File.join(app_dir, "Gemfile"),
      "BUNDLE_PATH" => BUNDLE_PATH,
      "RAILS_ENV" => "development",
      # Smoke subprocesses simulate a developer machine: a CI variable
      # inherited from the runner would trip the auto-install environment
      # guard, and an inherited frozen/deployment flag would make the
      # subprocess bundle refuse the appended path gems.
      "CI" => nil,
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

  # Returns true once the port answers, :exited if the child died first, false
  # on timeout.
  def wait_for_port(port, timeout:, pid: nil)
    deadline = Time.now + timeout
    while Time.now < deadline
      return :exited if pid && Process.waitpid(pid, Process::WNOHANG)
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

RSpec.configure do |config|
  # Config-level around hooks are outermost, so a group's own around has
  # already stopped its server by the time this cleans up. The shared bundle
  # cache lives outside TMP_ROOT and is never touched.
  config.around(:each, :smoke) do |ex|
    Smoke.reset_tmp_dirs!
    ex.run
    Smoke.cleanup_tmp_dirs! unless ex.example.exception
  end
end
