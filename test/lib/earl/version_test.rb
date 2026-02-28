# frozen_string_literal: true

require "test_helper"

module Earl
  class VersionTest < Minitest::Test
    test "VERSION is defined" do
      assert_not_nil Earl::VERSION
    end

    test "VERSION is a string" do
      assert_kind_of String, Earl::VERSION
    end

    test "VERSION follows semver format" do
      assert_match(/\A\d+\.\d+\.\d+/, Earl::VERSION)
    end
  end
end
