# Developer Tools

This directory contains scripts to help developers and AI assistants maintain code quality and run tests efficiently.

## Key Scripts

### `ci`
Comprehensive CI pipeline that runs all checks and tests in sequence:
RuboCop, Reek, Bundler audit, Semgrep, Actionlint, Minitest, and coverage reporting.

### `coverage`
Generates test coverage reports to help identify untested code.

### `watch-ci`
Monitors GitHub Actions CI status for the current branch, exiting on pass or fail.

### `rubocop`
Wrapper that explicitly sets the config path for consistent behavior.

### `claude-context` / `claude-usage`
Helpers spawned by `!context` and `!usage` bot commands.
