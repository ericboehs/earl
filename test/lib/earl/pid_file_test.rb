# frozen_string_literal: true

require "test_helper"

module Earl
  class PidFileTest < Minitest::Test
    setup do
      @tmpdir = Dir.mktmpdir
      Earl.instance_variable_set(:@config_root, @tmpdir)
    end

    teardown do
      Earl.instance_variable_set(:@config_root, nil)
      FileUtils.rm_rf(@tmpdir)
    end

    test "path is config_root/earl.pid" do
      assert_equal File.join(@tmpdir, "earl.pid"), PidFile.path
    end

    test "check! does nothing when no PID file exists" do
      assert_nothing_raised { PidFile.check! }
    end

    test "check! does nothing when PID file is empty" do
      File.write(PidFile.path, "")
      assert_nothing_raised { PidFile.check! }
    end

    test "check! does nothing when PID file contains zero" do
      File.write(PidFile.path, "0")
      assert_nothing_raised { PidFile.check! }
    end

    test "check! removes stale PID file and continues" do
      File.write(PidFile.path, "999999999")
      assert_nothing_raised { PidFile.check! }
    end

    test "check! aborts when process is alive" do
      File.write(PidFile.path, Process.pid.to_s)
      error = assert_raises(SystemExit) { capture_io { PidFile.check! } }
      assert_equal 1, error.status
    end

    test "check! aborts with EPERM" do
      File.write(PidFile.path, "42")
      original_kill = Process.method(:kill)
      stub_singleton(Process, :kill) { |*| raise Errno::EPERM }
      error = assert_raises(SystemExit) { capture_io { PidFile.check! } }
      assert_equal 1, error.status
    ensure
      stub_singleton(Process, :kill) { |*args| original_kill.call(*args) }
    end

    test "write! creates PID file with current process ID" do
      PidFile.write!
      assert_equal Process.pid.to_s, File.read(PidFile.path)
    end

    test "cleanup! removes PID file" do
      PidFile.write!
      assert File.exist?(PidFile.path)
      PidFile.cleanup!
      assert_not File.exist?(PidFile.path)
    end

    test "cleanup! is safe when file does not exist" do
      assert_nothing_raised { PidFile.cleanup! }
    end
  end
end
