require "test_helper"

class EarlTest < ActiveSupport::TestCase
  teardown do
    Earl.logger = nil
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
