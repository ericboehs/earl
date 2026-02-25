# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch

  minimum_coverage line: 90, branch: 80

  add_filter "/test/"
  add_filter "/bin/"
  add_filter "/exe/"

  add_group "Libraries", "lib/"

  track_files "lib/**/*.rb"

  formatter SimpleCov::Formatter::MultiFormatter.new([
                                                       SimpleCov::Formatter::HTMLFormatter
                                                     ])
end

require "bundler/setup"
require "minitest/autorun"

require_relative "../lib/earl"

# Provide Rails-like declarative test DSL for Minitest::Test
module DeclarativeTests
  def test(name, &)
    define_method("test_#{name.gsub(/\s+/, "_")}", &)
  end

  def setup(&block)
    define_method(:setup) { super(); instance_exec(&block) }
  end

  def teardown(&block)
    define_method(:teardown) { instance_exec(&block); super() }
  end
end

class Minitest::Test
  extend DeclarativeTests

  alias assert_not refute
  alias assert_not_nil refute_nil
  alias assert_not_equal refute_equal
  alias assert_not_includes refute_includes
  alias assert_not_empty refute_empty
  alias assert_not_same refute_same

  def assert_nothing_raised
    yield
  end
end
