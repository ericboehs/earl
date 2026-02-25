# frozen_string_literal: true

require "open3"

module Earl
  # Automates Safari via osascript (JavaScript for Automation) to interact with
  # web pages. Used by GithubPatHandler to create fine-grained PATs on github.com.
  #
  # Dynamic string values that appear inside doJavaScript() are declared as JXA
  # variables and escaped into single-quoted JS literals to avoid double escaping
  # (Ruby heredoc -> JXA string -> inner JS string). Numeric values are
  # interpolated directly since they need no quoting.
  #
  # Most DOM methods return an 'OK'/'NOT_FOUND:...' status string from inner JS
  # and raise SafariAutomation::Error if the expected element is not found.
  module SafariAutomation
    # Raised when Safari/osascript automation fails (element not found, process error).
    class Error < StandardError; end

    # Standard JS escaping for JXA variables: escapes backslashes and single quotes.
    JS_ESCAPE_LINES = <<~'JS'.chomp
      var esc = val.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
    JS

    module_function

    def navigate(url)
      execute_js <<~JS
        var safari = Application("Safari");
        safari.activate();
        var win = safari.windows[0];
        if (!win) { safari.Document().make(); win = safari.windows[0]; }
        win.currentTab.url = #{url.to_json};
      JS
    end

    # Shared helper: wraps an inner JS expression in doJavaScript on the active tab.
    def execute_do_js(inner_js)
      execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript("#{inner_js}", {in: tab});
      JS
    end

    # Executes doJavaScript with JXA variable declarations prepended.
    # Vars are set in the JXA scope (outside doJavaScript), body runs inside the browser.
    def execute_do_js_with_vars(vars, body)
      execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        #{vars}
        safari.doJavaScript(#{body}, {in: tab});
      JS
    end

    def execute_js(script)
      output, status = Open3.capture2e("osascript", "-l", "JavaScript", "-e", script)
      raise Error, "osascript failed (exit #{status.exitstatus}): #{output}" unless status.success?

      output
    end

    def check_result!(output, element_description)
      return unless output.strip.start_with?("NOT_FOUND")

      raise Error, "Could not find #{element_description} on page"
    end

    # Builds JXA variable declarations for a single escaped value.
    def escape_vars(value, var_name: "val")
      <<~JS.chomp
        var #{var_name} = #{value.to_json};
        var esc = #{var_name}.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
      JS
    end

    # Navigation flow: fills form fields.
    module NavigationHelpers
      module_function

      def fill_token_name(name)
        vars = SafariAutomation.escape_vars(name)
        body = token_name_body
        output = SafariAutomation.execute_do_js_with_vars(vars, body)
        SafariAutomation.check_result!(output, "token name input field")
      end

      def token_name_body
        <<~BODY.chomp
          "(function() {" +
          "  var el = document.getElementById('user_programmatic_access_name')" +
          " || document.querySelector('input[name*=programmatic_access]');" +
          "  if (!el) return 'NOT_FOUND:token_name_input';" +
          "  el.value = '" + esc + "'; el.dispatchEvent(new Event('input', {bubbles: true}));" +
          "  return 'OK';" +
          "})()"
        BODY
      end
    end

    include NavigationHelpers

    # Expiration flow: click button, select Custom, set date.
    module ExpirationHelpers
      module_function

      def apply_expiration(days)
        select_custom_expiration
        sleep 0.5
        apply_expiration_date(days)
      end

      def select_custom_expiration
        click_expiration_button
        sleep 0.5
        click_custom_option
      end

      def click_expiration_button
        output = SafariAutomation.execute_do_js(expiration_button_body)
        SafariAutomation.check_result!(output, "expiration dropdown button")
      end

      def click_custom_option
        output = SafariAutomation.execute_do_js(custom_option_body)
        SafariAutomation.check_result!(output, "'Custom' expiration option")
      end

      def apply_expiration_date(days)
        output = SafariAutomation.execute_do_js(date_input_body(days))
        SafariAutomation.check_result!(output, "expiration date input")
      end

      def expiration_button_body
        "(function() {  " \
          "var btns = document.querySelectorAll('button');  " \
          "for (var i = 0; i < btns.length; i++) {    " \
          "var t = btns[i].textContent.trim();    " \
          "if (t.indexOf('days') !== -1 && t.indexOf('expir') === -1) { btns[i].click(); return 'OK'; }  " \
          "}  " \
          "return 'NOT_FOUND:expiration_button';" \
          "})()"
      end

      def custom_option_body
        "(function() {  " \
          "var items = document.querySelectorAll('[role=menuitemradio]');  " \
          "for (var i = 0; i < items.length; i++) {    " \
          "if (items[i].textContent.trim() === 'Custom') { items[i].click(); return 'OK'; }  " \
          "}  " \
          "return 'NOT_FOUND:custom_expiration_option';" \
          "})()"
      end

      def date_input_body(days)
        "(function() {  " \
          "var input = document.querySelector('input[type=date]');  " \
          "if (!input) return 'NOT_FOUND:expiration_date_input';  " \
          "var d = new Date(); d.setDate(d.getDate() + #{days.to_i});  " \
          "var val = d.toISOString().split('T')[0];  " \
          "if (input.max && val > input.max) val = input.max;  " \
          "input.value = val;#{date_input_events}  " \
          "return 'OK';" \
          "})()"
      end

      def date_input_events
        "  input.dispatchEvent(new Event('input', {bubbles: true}));  " \
          "input.dispatchEvent(new Event('change', {bubbles: true}));"
      end
    end

    include ExpirationHelpers

    alias set_expiration apply_expiration
    module_function :set_expiration

    # Repository selection flow: click radio, open dialog, filter, select, close.
    module RepositoryRadioHelpers
      module_function

      def click_select_repositories_radio
        output = SafariAutomation.execute_do_js(select_repos_radio_body)
        SafariAutomation.check_result!(output, "'Only select repositories' radio button")
        sleep 0.5
      end

      def open_repository_dialog
        output = SafariAutomation.execute_do_js(open_repo_dialog_body)
        SafariAutomation.check_result!(output, "'Select repositories' button")
        sleep 0.5
      end

      def close_repository_dialog
        output = SafariAutomation.execute_do_js(close_dialog_body)
        SafariAutomation.check_result!(output, "repository dialog close button")
        sleep 1
      end

      def select_repos_radio_body
        "(function() {  " \
          "var radio = document.querySelector('input[value=selected][name=install_target]');  " \
          "if (!radio) return 'NOT_FOUND:select_repos_radio';  " \
          "radio.click(); return 'OK';" \
          "})()"
      end

      def open_repo_dialog_body
        "(function() {  " \
          "var buttons = document.querySelectorAll('button');  " \
          "for (var i = 0; i < buttons.length; i++) {    " \
          "if (buttons[i].textContent.trim().indexOf('Select repositor') !== -1) {      " \
          "buttons[i].click(); return 'OK'; }  " \
          "}  " \
          "return 'NOT_FOUND:select_repos_button';" \
          "})()"
      end

      def close_dialog_body
        "(function() {  " \
          "var dialog = document.querySelector('dialog[open]');  " \
          "if (!dialog) return 'OK';  " \
          "var closeBtn = dialog.querySelector('button[aria-label=Close]');  " \
          "if (closeBtn) { closeBtn.click(); return 'OK'; }  " \
          "return 'NOT_FOUND:dialog_close_button';" \
          "})()"
      end
    end

    include RepositoryRadioHelpers

    # Repository search and selection within the dialog.
    module RepositorySearchHelpers
      module_function

      def select_repository(repo)
        RepositoryRadioHelpers.click_select_repositories_radio
        RepositoryRadioHelpers.open_repository_dialog
        filter_and_select_repo(repo)
        RepositoryRadioHelpers.close_repository_dialog
        verify_repository_selected!(repo)
      end

      def filter_and_select_repo(repo)
        repo_name = repo.include?("/") ? repo.split("/", 2).last : repo
        filter_repo_search(repo_name)
        sleep 1
        click_repo_option(repo)
      end

      def filter_repo_search(repo_name)
        vars = SafariAutomation.escape_vars(repo_name, var_name: "searchTerm")
        body = repo_filter_body
        output = SafariAutomation.execute_do_js_with_vars(vars, body)
        SafariAutomation.check_result!(output, "repository search dialog")
      end

      def click_repo_option(repo)
        vars = SafariAutomation.escape_vars(repo, var_name: "fullRepo")
        body = repo_option_body
        output = SafariAutomation.execute_do_js_with_vars(vars, body)
        SafariAutomation.check_result!(output, "repository '#{repo}' in search results")
      end

      def verify_repository_selected!(repo)
        vars = SafariAutomation.escape_vars(repo, var_name: "repoName")
        body = verify_repo_body
        output = SafariAutomation.execute_do_js_with_vars(vars, body)
        SafariAutomation.check_result!(output, "repository '#{repo}' selection (token would scope to ALL repos)")
      end

      def repo_filter_body
        '"(function() {" +' \
          '"  var dialog = document.querySelector(\'dialog[open]\');" +' \
          '"  if (!dialog) return \'NOT_FOUND:repo_dialog\';" +' \
          '"  var search = dialog.querySelector(\'input[name=filter], input[type=search]\');" +' \
          '"  if (!search) return \'NOT_FOUND:repo_search_input\';" +' \
          '"  search.value = \'" + esc + "\';" +' \
          '"  search.dispatchEvent(new Event(\'input\', {bubbles: true}));" +' \
          '"  return \'OK\';" +' \
          '"  })()"'
      end

      def repo_option_body
        '"(function() {" +' \
          '"  var dialog = document.querySelector(\'dialog[open]\');" +' \
          '"  if (!dialog) return \'NOT_FOUND:repo_dialog\';" +' \
          '"  var options = dialog.querySelectorAll(\'[role=option]\');" +' \
          '"  for (var i = 0; i < options.length; i++) {" +' \
          '"    if (options[i].textContent.indexOf(\'" + esc + "\') !== -1) {" +' \
          '"      options[i].click(); return \'OK\'; }" +' \
          '"  }" +' \
          '"  return \'NOT_FOUND:repo_option\';" +' \
          '"  })()"'
      end

      def verify_repo_body
        <<~BODY.chomp
          "(function() {" +
          "  var page = document.body.innerText;" +
          "  if (page.indexOf('" + esc + "') !== -1 && " +
          "    (page.indexOf('1 repository') !== -1 || " +
          "     page.indexOf('Selected') !== -1)) return 'OK';" +
          "  return 'NOT_FOUND:repository_selection';" +
          "})()"
        BODY
      end
    end

    include RepositorySearchHelpers

    # Permission flow: expand panel, select permission, optionally set write level.
    module PermissionExpandHelpers
      module_function

      def apply_permissions(permissions)
        permissions.each do |perm_name, level|
          display_name = perm_name.tr("_", " ")
          expand_add_permissions
          add_permission_option(display_name)
          PermissionLevelHelpers.upgrade_permission_level(display_name) if level == "write"
          sleep 1
        end
      end

      def expand_add_permissions
        output = SafariAutomation.execute_do_js(expand_permissions_body)
        SafariAutomation.check_result!(output, "'Add permissions' button")
        sleep 0.5
      end

      def add_permission_option(display_name)
        vars = SafariAutomation.escape_vars(display_name, var_name: "permName")
        output = SafariAutomation.execute_do_js_with_vars(vars, add_perm_body)
        SafariAutomation.check_result!(output, "permission '#{display_name}' in Add permissions list")
        sleep 0.5
      end

      def expand_permissions_body
        "(function() {  " \
          "var expandables = document.querySelectorAll('[aria-expanded]');  " \
          "for (var i = 0; i < expandables.length; i++) {    " \
          "if (expandables[i].textContent.trim().indexOf('Add permissions') !== -1) {      " \
          "if (expandables[i].getAttribute('aria-expanded') === 'false') expandables[i].click();      " \
          "return 'OK'; }  " \
          "}  " \
          "return 'NOT_FOUND:add_permissions_button';" \
          "})()"
      end

      def add_perm_body
        '"(function() {" +' \
          '"  var options = document.querySelectorAll(\'[role=option]\');" +' \
          '"  for (var i = 0; i < options.length; i++) {" +' \
          '"    var t = options[i].textContent.trim().toLowerCase();" +' \
          '"    if (t === \'" + esc.toLowerCase() + "\' || " +' \
          '"        t.indexOf(\'" + esc.toLowerCase() + "\') === 0) {" +' \
          '"      options[i].click(); return \'OK\'; }" +' \
          '"  }" +' \
          '"  return \'NOT_FOUND:permission_option\';" +' \
          '"  })()"'
      end
    end

    include PermissionExpandHelpers

    alias set_permissions apply_permissions
    module_function :set_permissions

    # Permission level upgrade flow: click access button, select "Read and write".
    module PermissionLevelHelpers
      module_function

      def upgrade_permission_level(display_name)
        click_access_level_button(display_name)
        sleep 0.5
        select_read_write_option(display_name)
      end

      def click_access_level_button(display_name)
        vars = SafariAutomation.escape_vars(display_name, var_name: "permName")
        output = SafariAutomation.execute_do_js_with_vars(vars, access_level_body)
        SafariAutomation.check_result!(output, "access level button for '#{display_name}'")
      end

      def select_read_write_option(display_name)
        output = SafariAutomation.execute_do_js(read_write_body)
        SafariAutomation.check_result!(output, "'Read and write' option for '#{display_name}'")
      end

      def access_level_body
        '"(function() {" +' \
          '"  var btns = document.querySelectorAll(\'button[aria-haspopup=true]\');" +' \
          '"  for (var i = btns.length - 1; i >= 0; i--) {" +' \
          '"    if (btns[i].textContent.indexOf(\'Read-only\') === -1) continue;" +' \
          '"    var row = btns[i].closest(\'li, [class*=Box-row]\') || btns[i].parentElement.parentElement;" +' \
          '"    if (row && row.textContent.toLowerCase().indexOf(\'" + esc.toLowerCase() + "\') !== -1) {" +' \
          '"      btns[i].click(); return \'OK\'; }" +' \
          '"  }" +' \
          '"  return \'NOT_FOUND:access_level_button\';" +' \
          '"  })()"'
      end

      def read_write_body
        "(function() {  " \
          "var items = document.querySelectorAll('[role=menuitem], [role=menuitemradio]');  " \
          "for (var i = 0; i < items.length; i++) {    " \
          "if (items[i].textContent.trim() === 'Read and write') { items[i].click(); return 'OK'; }  " \
          "}  " \
          "return 'NOT_FOUND:read_and_write_option';" \
          "})()"
      end
    end

    include PermissionLevelHelpers

    # Generation and token extraction flow.
    module GenerationHelpers
      module_function

      def click_generate
        output = SafariAutomation.execute_do_js(generate_button_body)
        SafariAutomation.check_result!(output, "Generate token button")
        wait_for_confirmation_frame
      end

      def confirm_generation
        output = SafariAutomation.execute_do_js(confirm_dialog_body)
        SafariAutomation.check_result!(output, "generation confirmation button")
        sleep 3
      end

      def wait_for_confirmation_frame
        8.times do
          sleep 1
          loaded = SafariAutomation.execute_do_js(confirmation_check_body)
          return if loaded.strip == "LOADED"
        end
        raise Error, "Confirmation dialog did not load after clicking Generate"
      end

      def extract_token
        poll_for_token
      end

      def poll_for_token
        10.times do
          sleep 1
          token = attempt_token_extraction
          return token unless token.empty?
        end
        raise Error, "Token not found on page after 10 attempts"
      end

      def attempt_token_extraction
        output = SafariAutomation.execute_do_js(token_extraction_body)
        output.strip
      end

      def generate_button_body
        "(function() {  " \
          "var btn = document.querySelector('.js-integrations-install-form-submit');  " \
          "if (!btn) return 'NOT_FOUND:generate_button';  " \
          "btn.click(); return 'OK';" \
          "})()"
      end

      def confirm_dialog_body
        "(function() {  " \
          "var dialog = document.getElementById('confirm-fg-pat');  " \
          "if (!dialog) return 'NOT_FOUND:confirmation_dialog';  " \
          "if (!dialog.open) dialog.showModal();  " \
          "var btn = dialog.querySelector('button[type=submit]');  " \
          "if (!btn) return 'NOT_FOUND:confirmation_submit';  " \
          "btn.click(); return 'OK';" \
          "})()"
      end

      def confirmation_check_body
        "document.getElementById('confirm-fg-pat') ? 'LOADED' : 'WAITING'"
      end

      def token_extraction_body
        "(function() {  " \
          "var sel = '#new-access-token, [id*=token-value], .token-code, input[readonly][value^=github_pat_]';  " \
          "var token = document.querySelector(sel);  " \
          "if (token) return token.value || token.textContent || '';  " \
          "var match = document.body.innerText.match(/github_pat_[A-Za-z0-9_]+/);  " \
          "return match ? match[0] : '';" \
          "})()"
      end
    end

    include GenerationHelpers
  end
end
