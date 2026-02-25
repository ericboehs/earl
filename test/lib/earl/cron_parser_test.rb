# frozen_string_literal: true

require "test_helper"

module Earl
  class CronParserTest < Minitest::Test
    test "matches every minute with * * * * *" do
      parser = Earl::CronParser.new("* * * * *")
      assert parser.matches?(Time.new(2026, 2, 14, 9, 30, 0))
      assert parser.matches?(Time.new(2026, 1, 1, 0, 0, 0))
    end

    test "matches specific minute and hour" do
      parser = Earl::CronParser.new("30 9 * * *")
      assert parser.matches?(Time.new(2026, 2, 14, 9, 30, 0))
      assert_not parser.matches?(Time.new(2026, 2, 14, 9, 31, 0))
      assert_not parser.matches?(Time.new(2026, 2, 14, 10, 30, 0))
    end

    test "matches weekdays only with 1-5" do
      parser = Earl::CronParser.new("0 9 * * 1-5")
      # Friday
      assert parser.matches?(Time.new(2026, 2, 13, 9, 0, 0))
      # Saturday
      assert_not parser.matches?(Time.new(2026, 2, 14, 9, 0, 0))
      # Sunday
      assert_not parser.matches?(Time.new(2026, 2, 15, 9, 0, 0))
      # Monday
      assert parser.matches?(Time.new(2026, 2, 16, 9, 0, 0))
    end

    test "matches step values with */15" do
      parser = Earl::CronParser.new("*/15 * * * *")
      assert parser.matches?(Time.new(2026, 2, 14, 9, 0, 0))
      assert parser.matches?(Time.new(2026, 2, 14, 9, 15, 0))
      assert parser.matches?(Time.new(2026, 2, 14, 9, 30, 0))
      assert parser.matches?(Time.new(2026, 2, 14, 9, 45, 0))
      assert_not parser.matches?(Time.new(2026, 2, 14, 9, 10, 0))
    end

    test "matches list values with 1,3,5" do
      parser = Earl::CronParser.new("0 0 * * 1,3,5")
      # Monday
      assert parser.matches?(Time.new(2026, 2, 16, 0, 0, 0))
      # Wednesday
      assert parser.matches?(Time.new(2026, 2, 18, 0, 0, 0))
      # Friday
      assert parser.matches?(Time.new(2026, 2, 13, 0, 0, 0))
      # Tuesday
      assert_not parser.matches?(Time.new(2026, 2, 17, 0, 0, 0))
    end

    test "matches specific day of month" do
      parser = Earl::CronParser.new("0 0 15 * *")
      assert parser.matches?(Time.new(2026, 2, 15, 0, 0, 0))
      assert_not parser.matches?(Time.new(2026, 2, 14, 0, 0, 0))
    end

    test "matches specific month" do
      parser = Earl::CronParser.new("0 0 1 6 *")
      assert parser.matches?(Time.new(2026, 6, 1, 0, 0, 0))
      assert_not parser.matches?(Time.new(2026, 7, 1, 0, 0, 0))
    end

    test "matches range with step (1-5/2)" do
      parser = Earl::CronParser.new("0 0 * * 1-5/2")
      # Monday (1)
      assert parser.matches?(Time.new(2026, 2, 16, 0, 0, 0))
      # Wednesday (3)
      assert parser.matches?(Time.new(2026, 2, 18, 0, 0, 0))
      # Friday (5)
      assert parser.matches?(Time.new(2026, 2, 13, 0, 0, 0))
      # Tuesday (2)
      assert_not parser.matches?(Time.new(2026, 2, 17, 0, 0, 0))
    end

    test "next_occurrence finds next matching time" do
      parser = Earl::CronParser.new("30 9 * * *")
      from = Time.new(2026, 2, 14, 9, 0, 0)
      result = parser.next_occurrence(from: from)
      assert_equal Time.new(2026, 2, 14, 9, 30, 0), result
    end

    test "next_occurrence skips current minute" do
      parser = Earl::CronParser.new("0 10 * * *")
      from = Time.new(2026, 2, 14, 10, 0, 0)
      result = parser.next_occurrence(from: from)
      # Should find next day at 10:00, not current time
      assert_equal Time.new(2026, 2, 15, 10, 0, 0), result
    end

    test "next_occurrence returns nil for impossible expression" do
      # Day 31 of February will never match
      parser = Earl::CronParser.new("0 0 31 2 *")
      from = Time.new(2026, 1, 1, 0, 0, 0)
      result = parser.next_occurrence(from: from)
      assert_nil result
    end

    test "next_occurrence advances to next week for weekday-only cron" do
      parser = Earl::CronParser.new("0 9 * * 1-5")
      # Saturday 9am
      from = Time.new(2026, 2, 14, 9, 0, 0)
      result = parser.next_occurrence(from: from)
      # Should be Monday 9am
      assert_equal Time.new(2026, 2, 16, 9, 0, 0), result
    end

    test "raises on invalid expression with wrong field count" do
      assert_raises(ArgumentError) { Earl::CronParser.new("* * *") }
      assert_raises(ArgumentError) { Earl::CronParser.new("* * * * * *") }
    end

    test "raises on invalid field syntax" do
      assert_raises(ArgumentError) { Earl::CronParser.new("abc * * * *") }
      assert_raises(ArgumentError) { Earl::CronParser.new("* * * * foo") }
    end

    test "raises on zero step" do
      assert_raises(ArgumentError) { Earl::CronParser.new("*/0 * * * *") }
    end

    test "raises on zero step in range expression" do
      assert_raises(ArgumentError) { Earl::CronParser.new("1-5/0 * * * *") }
    end

    test "complex expression: 0,30 9-17 * * 1-5" do
      parser = Earl::CronParser.new("0,30 9-17 * * 1-5")
      # Monday 9:00
      assert parser.matches?(Time.new(2026, 2, 16, 9, 0, 0))
      # Monday 12:30
      assert parser.matches?(Time.new(2026, 2, 16, 12, 30, 0))
      # Monday 18:00 (out of range)
      assert_not parser.matches?(Time.new(2026, 2, 16, 18, 0, 0))
      # Saturday 9:00
      assert_not parser.matches?(Time.new(2026, 2, 14, 9, 0, 0))
    end
  end
end
