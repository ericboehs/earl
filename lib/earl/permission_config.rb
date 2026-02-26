# frozen_string_literal: true

module Earl
  # Shared MCP config enrichment for optional env vars like PEARL_BIN.
  # Used by SessionManager to add extra env vars to McpConfig objects.
  module PermissionConfig
    private

    def merge_mcp_config_env(mcp_config)
      pearl_bin = ENV.fetch("PEARL_BIN", nil)
      return mcp_config unless pearl_bin

      enriched_env = mcp_config.env.merge("PEARL_BIN" => pearl_bin)
      ClaudeSession::McpConfig.new(env: enriched_env, skip_permissions: mcp_config.skip_permissions)
    end
  end
end
