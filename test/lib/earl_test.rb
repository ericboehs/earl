require "test_helper"

class EarlTest < ActiveSupport::TestCase
  teardown do
    Earl.logger = nil
    Earl.instance_variable_set(:@env, nil)
    Earl.instance_variable_set(:@config_root, nil)
  end

  # --- Environment detection ---

  test "env defaults to production" do
    ENV.delete("EARL_ENV")
    Earl.instance_variable_set(:@env, nil)
    assert_equal "production", Earl.env
  end

  test "env reads EARL_ENV" do
    Earl.instance_variable_set(:@env, nil)
    ENV["EARL_ENV"] = "development"
    assert_equal "development", Earl.env
  ensure
    ENV.delete("EARL_ENV")
  end

  test "development? returns true when EARL_ENV is development" do
    Earl.instance_variable_set(:@env, nil)
    ENV["EARL_ENV"] = "development"
    assert Earl.development?
  ensure
    ENV.delete("EARL_ENV")
  end

  test "development? returns false when EARL_ENV is production" do
    Earl.instance_variable_set(:@env, nil)
    ENV["EARL_ENV"] = "production"
    assert_not Earl.development?
  ensure
    ENV.delete("EARL_ENV")
  end

  test "config_root uses earl-dev dir in development" do
    Earl.instance_variable_set(:@env, nil)
    Earl.instance_variable_set(:@config_root, nil)
    ENV["EARL_ENV"] = "development"
    assert_equal File.join(Dir.home, ".config", "earl-dev"), Earl.config_root
  ensure
    ENV.delete("EARL_ENV")
  end

  test "config_root uses earl dir in production" do
    Earl.instance_variable_set(:@env, nil)
    Earl.instance_variable_set(:@config_root, nil)
    ENV["EARL_ENV"] = "production"
    assert_equal File.join(Dir.home, ".config", "earl"), Earl.config_root
  ensure
    ENV.delete("EARL_ENV")
  end

  test "env raises on invalid EARL_ENV" do
    Earl.instance_variable_set(:@env, nil)
    ENV["EARL_ENV"] = "staging"
    assert_raises(ArgumentError) { Earl.env }
  ensure
    ENV.delete("EARL_ENV")
  end

  test "development? returns false when EARL_ENV is unset" do
    Earl.instance_variable_set(:@env, nil)
    ENV.delete("EARL_ENV")
    assert_not Earl.development?
  end

  test "config_root defaults to production path when EARL_ENV is unset" do
    Earl.instance_variable_set(:@env, nil)
    Earl.instance_variable_set(:@config_root, nil)
    ENV.delete("EARL_ENV")
    assert_equal File.join(Dir.home, ".config", "earl"), Earl.config_root
  end

  # --- Integration: downstream classes derive paths from config_root ---

  test "SessionStore.default_path derives from Earl.config_root" do
    Earl.instance_variable_set(:@env, nil)
    Earl.instance_variable_set(:@config_root, nil)
    Earl::SessionStore.instance_variable_set(:@default_path, nil)
    ENV["EARL_ENV"] = "development"

    expected = File.join(Dir.home, ".config", "earl-dev", "sessions.json")
    assert_equal expected, Earl::SessionStore.default_path
  ensure
    ENV.delete("EARL_ENV")
    Earl::SessionStore.instance_variable_set(:@default_path, nil)
  end

  test "logger returns a Logger instance" do
    assert_instance_of Logger, Earl.logger
  end

  test "logger is memoized" do
    assert_same Earl.logger, Earl.logger
  end

  test "logger can be set" do
    custom = Logger.new(File::NULL)
    Earl.logger = custom
    assert_same custom, Earl.logger
  end

  test "logger formats with timestamp and severity" do
    output = StringIO.new
    Earl.logger = Logger.new(output, level: Logger::INFO)
    Earl.logger.formatter = proc do |severity, datetime, _progname, msg|
      "#{datetime.strftime('%H:%M:%S')} [#{severity}] #{msg}\n"
    end

    Earl.logger.info "test message"
    assert_match(/\d{2}:\d{2}:\d{2} \[INFO\] test message/, output.string)
  end
end
