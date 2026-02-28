# frozen_string_literal: true

require "test_helper"

module Earl
  # Tests for SafariAutomation module (JXA-based Safari browser control).
  class SafariAutomationTest < Minitest::Test
    SLEEP_MODULES = [
      SafariAutomation,
      SafariAutomation::ExpirationHelpers,
      SafariAutomation::RepositoryRadioHelpers,
      SafariAutomation::RepositorySearchHelpers,
      SafariAutomation::PermissionExpandHelpers,
      SafariAutomation::PermissionLevelHelpers,
      SafariAutomation::GenerationHelpers
    ].freeze

    setup do
      Earl.logger = Logger.new(File::NULL)
      @original_capture2e = Open3.method(:capture2e)
      stub_all_sleeps
    end

    teardown do
      Earl.logger = nil
      restore_capture
      restore_all_sleeps
    end

    # -- Core SafariAutomation methods --

    test "navigate calls osascript with URL" do
      stub_osascript("OK\n")
      output = SafariAutomation.navigate("https://example.com")
      assert_equal "OK\n", output
    end

    test "navigate includes URL in script" do
      calls = []
      stub_osascript_with_tracking(calls)
      SafariAutomation.navigate("https://github.com/settings/tokens")
      assert_match(%r{https://github.com/settings/tokens}, calls[0])
    end

    test "execute_js raises on osascript failure" do
      stub_osascript("error: something failed", success: false)
      error = assert_raises(SafariAutomation::Error) { SafariAutomation.execute_js("bad script") }
      assert_match(/osascript failed/, error.message)
    end

    test "execute_js returns output on success" do
      stub_osascript("OK\n")
      assert_equal "OK\n", SafariAutomation.execute_js("var x = 1;")
    end

    test "execute_do_js wraps inner JS in doJavaScript" do
      calls = []
      stub_osascript_with_tracking(calls)
      SafariAutomation.execute_do_js("document.title")
      assert_match(/doJavaScript/, calls[0])
      assert_match(/document\.title/, calls[0])
    end

    test "execute_do_js raises on failure" do
      stub_osascript("error", success: false)
      assert_raises(SafariAutomation::Error) { SafariAutomation.execute_do_js("bad js") }
    end

    test "execute_do_js_with_vars prepends variable declarations" do
      calls = []
      stub_osascript_with_tracking(calls)
      vars = 'var myVar = "test";'
      SafariAutomation.execute_do_js_with_vars(vars, '"alert(myVar)"')
      assert_match(/var myVar = "test";/, calls[0])
      assert_match(/doJavaScript/, calls[0])
    end

    test "check_result! passes on OK output" do
      assert_nothing_raised { SafariAutomation.check_result!("OK\n", "test element") }
    end

    test "check_result! raises on NOT_FOUND output" do
      error = assert_raises(SafariAutomation::Error) do
        SafariAutomation.check_result!("NOT_FOUND:some_element\n", "test element")
      end
      assert_match(/Could not find test element/, error.message)
    end

    test "check_result! passes on non-NOT_FOUND output" do
      assert_nothing_raised { SafariAutomation.check_result!("github_pat_abc123\n", "token") }
    end

    test "escape_vars generates JXA variable declaration with escaping" do
      result = SafariAutomation.escape_vars("my-token")
      assert_match(/var val =/, result)
      assert_match(/replace/, result)
    end

    test "escape_vars uses custom var_name" do
      result = SafariAutomation.escape_vars("test", var_name: "searchTerm")
      assert_match(/var searchTerm =/, result)
    end

    # -- NavigationHelpers --

    test "fill_token_name succeeds with OK result" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::NavigationHelpers.fill_token_name("my-token") }
    end

    test "fill_token_name raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:token_name_input\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::NavigationHelpers.fill_token_name("my-token")
      end
    end

    test "token_name_body returns JS string with input selector" do
      body = SafariAutomation::NavigationHelpers.token_name_body
      assert_includes body, "user_programmatic_access_name"
      assert_includes body, "NOT_FOUND:token_name_input"
    end

    # -- ExpirationHelpers --

    test "apply_expiration calls select_custom_expiration and apply_expiration_date" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::ExpirationHelpers.apply_expiration(30) }
    end

    test "click_expiration_button succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::ExpirationHelpers.click_expiration_button }
    end

    test "click_expiration_button raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:expiration_button\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::ExpirationHelpers.click_expiration_button
      end
    end

    test "click_custom_option succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::ExpirationHelpers.click_custom_option }
    end

    test "click_custom_option raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:custom_expiration_option\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::ExpirationHelpers.click_custom_option
      end
    end

    test "apply_expiration_date succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::ExpirationHelpers.apply_expiration_date(90) }
    end

    test "apply_expiration_date raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:expiration_date_input\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::ExpirationHelpers.apply_expiration_date(90)
      end
    end

    test "expiration_button_body returns JS with days selector" do
      body = SafariAutomation::ExpirationHelpers.expiration_button_body
      assert_includes body, "days"
      assert_includes body, "NOT_FOUND:expiration_button"
    end

    test "custom_option_body returns JS with Custom menu item" do
      body = SafariAutomation::ExpirationHelpers.custom_option_body
      assert_includes body, "Custom"
      assert_includes body, "menuitemradio"
    end

    test "date_input_body includes days parameter" do
      body = SafariAutomation::ExpirationHelpers.date_input_body(30)
      assert_includes body, "30"
      assert_includes body, "input[type=date]"
    end

    test "date_input_events returns event dispatch string" do
      events = SafariAutomation::ExpirationHelpers.date_input_events
      assert_includes events, "dispatchEvent"
      assert_includes events, "change"
    end

    # -- RepositoryRadioHelpers --

    test "click_select_repositories_radio succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::RepositoryRadioHelpers.click_select_repositories_radio }
    end

    test "click_select_repositories_radio raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:select_repos_radio\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::RepositoryRadioHelpers.click_select_repositories_radio
      end
    end

    test "open_repository_dialog succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::RepositoryRadioHelpers.open_repository_dialog }
    end

    test "open_repository_dialog raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:select_repos_button\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::RepositoryRadioHelpers.open_repository_dialog
      end
    end

    test "close_repository_dialog succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::RepositoryRadioHelpers.close_repository_dialog }
    end

    test "close_repository_dialog raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:dialog_close_button\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::RepositoryRadioHelpers.close_repository_dialog
      end
    end

    test "select_repos_radio_body returns JS with radio selector" do
      body = SafariAutomation::RepositoryRadioHelpers.select_repos_radio_body
      assert_includes body, "install_target"
      assert_includes body, "NOT_FOUND:select_repos_radio"
    end

    test "open_repo_dialog_body returns JS with button selector" do
      body = SafariAutomation::RepositoryRadioHelpers.open_repo_dialog_body
      assert_includes body, "Select repositor"
      assert_includes body, "NOT_FOUND:select_repos_button"
    end

    test "close_dialog_body returns JS with dialog close" do
      body = SafariAutomation::RepositoryRadioHelpers.close_dialog_body
      assert_includes body, "dialog[open]"
      assert_includes body, "aria-label=Close"
    end

    # -- RepositorySearchHelpers --

    test "select_repository completes full flow with OK results" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::RepositorySearchHelpers.select_repository("org/repo") }
    end

    test "filter_and_select_repo splits org/repo format" do
      calls = []
      stub_osascript_with_tracking(calls)
      SafariAutomation::RepositorySearchHelpers.filter_and_select_repo("my-org/my-repo")
      combined = calls.join("\n")
      assert_match(/my-repo/, combined)
    end

    test "filter_and_select_repo handles repo without org prefix" do
      calls = []
      stub_osascript_with_tracking(calls)
      SafariAutomation::RepositorySearchHelpers.filter_and_select_repo("my-repo")
      combined = calls.join("\n")
      assert_match(/my-repo/, combined)
    end

    test "verify_repository_selected! raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:repository_selection\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::RepositorySearchHelpers.verify_repository_selected!("org/repo")
      end
    end

    test "verify_repository_selected! passes on OK" do
      stub_osascript("OK\n")
      assert_nothing_raised do
        SafariAutomation::RepositorySearchHelpers.verify_repository_selected!("org/repo")
      end
    end

    test "repo_filter_body returns JS with dialog query" do
      body = SafariAutomation::RepositorySearchHelpers.repo_filter_body
      assert_includes body, "dialog"
      assert_includes body, "NOT_FOUND:repo_dialog"
    end

    test "repo_option_body returns JS with option selector" do
      body = SafariAutomation::RepositorySearchHelpers.repo_option_body
      assert_includes body, "role=option"
      assert_includes body, "NOT_FOUND:repo_option"
    end

    test "verify_repo_body returns JS with selection check" do
      body = SafariAutomation::RepositorySearchHelpers.verify_repo_body
      assert_includes body, "1 repository"
      assert_includes body, "NOT_FOUND:repository_selection"
    end

    # -- PermissionExpandHelpers --

    test "apply_permissions iterates over permissions hash" do
      stub_osascript("OK\n")
      permissions = { "contents" => "read", "metadata" => "read" }
      assert_nothing_raised { SafariAutomation::PermissionExpandHelpers.apply_permissions(permissions) }
    end

    test "apply_permissions calls upgrade for write level" do
      calls = []
      stub_osascript_with_tracking(calls)
      permissions = { "contents" => "write" }
      SafariAutomation::PermissionExpandHelpers.apply_permissions(permissions)
      combined = calls.join("\n")
      assert_match(/Read-only/, combined)
    end

    test "apply_permissions skips upgrade for read level" do
      calls = []
      stub_osascript_with_tracking(calls)
      permissions = { "contents" => "read" }
      SafariAutomation::PermissionExpandHelpers.apply_permissions(permissions)
      combined = calls.join("\n")
      assert_not_includes combined, "Read-only"
    end

    test "expand_add_permissions succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::PermissionExpandHelpers.expand_add_permissions }
    end

    test "expand_add_permissions raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:add_permissions_button\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::PermissionExpandHelpers.expand_add_permissions
      end
    end

    test "add_permission_option succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised do
        SafariAutomation::PermissionExpandHelpers.add_permission_option("contents")
      end
    end

    test "add_permission_option raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:permission_option\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::PermissionExpandHelpers.add_permission_option("contents")
      end
    end

    test "expand_permissions_body returns JS with aria-expanded" do
      body = SafariAutomation::PermissionExpandHelpers.expand_permissions_body
      assert_includes body, "aria-expanded"
      assert_includes body, "Add permissions"
    end

    test "add_perm_body returns JS with role option" do
      body = SafariAutomation::PermissionExpandHelpers.add_perm_body
      assert_includes body, "role=option"
      assert_includes body, "NOT_FOUND:permission_option"
    end

    # -- PermissionLevelHelpers --

    test "upgrade_permission_level clicks and selects" do
      stub_osascript("OK\n")
      assert_nothing_raised do
        SafariAutomation::PermissionLevelHelpers.upgrade_permission_level("contents")
      end
    end

    test "click_access_level_button succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised do
        SafariAutomation::PermissionLevelHelpers.click_access_level_button("contents")
      end
    end

    test "click_access_level_button raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:access_level_button\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::PermissionLevelHelpers.click_access_level_button("contents")
      end
    end

    test "select_read_write_option succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised do
        SafariAutomation::PermissionLevelHelpers.select_read_write_option("contents")
      end
    end

    test "select_read_write_option raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:read_and_write_option\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::PermissionLevelHelpers.select_read_write_option("contents")
      end
    end

    test "access_level_body returns JS with haspopup button" do
      body = SafariAutomation::PermissionLevelHelpers.access_level_body
      assert_includes body, "aria-haspopup=true"
      assert_includes body, "NOT_FOUND:access_level_button"
    end

    test "read_write_body returns JS with Read and write option" do
      body = SafariAutomation::PermissionLevelHelpers.read_write_body
      assert_includes body, "Read and write"
      assert_includes body, "NOT_FOUND:read_and_write_option"
    end

    # -- GenerationHelpers --

    test "click_generate succeeds when confirmation loads" do
      stub_osascript_sequence([
                                { output: "OK\n" },
                                { output: "LOADED\n" }
                              ])
      assert_nothing_raised { SafariAutomation::GenerationHelpers.click_generate }
    end

    test "click_generate raises when generate button not found" do
      stub_osascript("NOT_FOUND:generate_button\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::GenerationHelpers.click_generate
      end
    end

    test "wait_for_confirmation_frame returns on LOADED" do
      stub_osascript("LOADED\n")
      assert_nothing_raised { SafariAutomation::GenerationHelpers.wait_for_confirmation_frame }
    end

    test "wait_for_confirmation_frame raises after timeout" do
      stub_osascript("WAITING\n")
      error = assert_raises(SafariAutomation::Error) do
        SafariAutomation::GenerationHelpers.wait_for_confirmation_frame
      end
      assert_match(/Confirmation dialog did not load/, error.message)
    end

    test "confirm_generation succeeds with OK" do
      stub_osascript("OK\n")
      assert_nothing_raised { SafariAutomation::GenerationHelpers.confirm_generation }
    end

    test "confirm_generation raises on NOT_FOUND" do
      stub_osascript("NOT_FOUND:confirmation_dialog\n")
      assert_raises(SafariAutomation::Error) do
        SafariAutomation::GenerationHelpers.confirm_generation
      end
    end

    test "extract_token returns token on success" do
      stub_osascript("github_pat_abc123XYZ\n")
      token = SafariAutomation::GenerationHelpers.extract_token
      assert_equal "github_pat_abc123XYZ", token
    end

    test "poll_for_token returns token on first success" do
      stub_osascript("github_pat_testtoken\n")
      token = SafariAutomation::GenerationHelpers.poll_for_token
      assert_equal "github_pat_testtoken", token
    end

    test "poll_for_token raises after 10 empty attempts" do
      stub_osascript("\n")
      error = assert_raises(SafariAutomation::Error) do
        SafariAutomation::GenerationHelpers.poll_for_token
      end
      assert_match(/Token not found on page after 10 attempts/, error.message)
    end

    test "poll_for_token succeeds on third attempt" do
      stub_osascript_sequence([
                                { output: "\n" },
                                { output: "\n" },
                                { output: "github_pat_delayed\n" }
                              ])
      token = SafariAutomation::GenerationHelpers.poll_for_token
      assert_equal "github_pat_delayed", token
    end

    test "attempt_token_extraction strips whitespace" do
      stub_osascript("  github_pat_spaces  \n")
      token = SafariAutomation::GenerationHelpers.attempt_token_extraction
      assert_equal "github_pat_spaces", token
    end

    test "attempt_token_extraction returns empty for blank output" do
      stub_osascript("\n")
      token = SafariAutomation::GenerationHelpers.attempt_token_extraction
      assert_equal "", token
    end

    test "generate_button_body returns JS with submit selector" do
      body = SafariAutomation::GenerationHelpers.generate_button_body
      assert_includes body, "js-integrations-install-form-submit"
      assert_includes body, "NOT_FOUND:generate_button"
    end

    test "confirm_dialog_body returns JS with dialog submit" do
      body = SafariAutomation::GenerationHelpers.confirm_dialog_body
      assert_includes body, "confirm-fg-pat"
      assert_includes body, "NOT_FOUND:confirmation_dialog"
    end

    test "confirmation_check_body returns JS checking for dialog" do
      body = SafariAutomation::GenerationHelpers.confirmation_check_body
      assert_includes body, "confirm-fg-pat"
      assert_includes body, "LOADED"
      assert_includes body, "WAITING"
    end

    test "token_extraction_body returns JS with token selectors" do
      body = SafariAutomation::GenerationHelpers.token_extraction_body
      assert_includes body, "new-access-token"
      assert_includes body, "github_pat_"
    end

    # -- Module-level aliases --

    test "set_expiration is aliased to apply_expiration" do
      stub_osascript("OK\n")
      assert SafariAutomation.respond_to?(:set_expiration)
    end

    test "set_permissions is aliased to apply_permissions" do
      stub_osascript("OK\n")
      assert SafariAutomation.respond_to?(:set_permissions)
    end

    private

    def mock_status(success)
      status = Object.new
      stub_singleton(status, :success?) { success }
      stub_singleton(status, :exitstatus) { success ? 0 : 1 }
      status
    end

    def stub_osascript(output, success: true)
      pair = [output, mock_status(success)]
      stub_singleton(Open3, :capture2e) { |*_args| pair }
    end

    def stub_osascript_with_tracking(calls)
      pair_tail = mock_status(true)
      stub_singleton(Open3, :capture2e) do |*args|
        calls << args.last
        ["OK\n", pair_tail]
      end
    end

    def stub_osascript_sequence(responses)
      idx = 0
      builder = method(:mock_status)
      extractor = method(:extract_response)
      stub_singleton(Open3, :capture2e) do |*_args|
        output, ok = extractor.call(responses, idx, builder)
        idx += 1
        [output, ok]
      end
    end

    def extract_response(responses, idx, builder)
      entry = responses[idx] || responses.last
      [entry[:output], builder.call(entry.fetch(:success, true))]
    end

    def restore_capture
      original = @original_capture2e
      stub_singleton(Open3, :capture2e) { |*args| original.call(*args) }
    end

    def stub_all_sleeps
      noop = ->(_) {}
      SLEEP_MODULES.each { |mod| stub_singleton(mod, :sleep, &noop) }
    end

    def restore_all_sleeps
      SLEEP_MODULES.each do |mod|
        klass = mod.singleton_class
        klass.remove_method(:sleep) if klass.method_defined?(:sleep, false)
      end
    end
  end
end
