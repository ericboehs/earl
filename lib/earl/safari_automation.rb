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
  # Each DOM method returns a status string from the inner JS and raises
  # SafariAutomation::Error if the expected elements are not found.
  module SafariAutomation
    # Raised when Safari/osascript automation fails (element not found, process error).
    class Error < StandardError; end

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

    def fill_token_name(name)
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        var val = #{name.to_json};
        var esc = val.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
        safari.doJavaScript(
          "(function() {" +
          "  var el = document.getElementById('user_programmatic_access_name') || document.querySelector('input[name*=programmatic_access]');" +
          "  if (!el) return 'NOT_FOUND:token_name_input';" +
          "  el.value = '" + esc + "'; el.dispatchEvent(new Event('input', {bubbles: true}));" +
          "  return 'OK';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "token name input field")
    end

    # GitHub's expiration UI: a button opens a [role=menuitemradio] menu with presets
    # (7, 30, 60, 90 days, Custom, No expiration). For custom days, select "Custom"
    # to reveal a hidden date input, then set the date.
    def set_expiration(days)
      select_custom_expiration
      sleep 0.5
      set_expiration_date(days)
    end

    def select_custom_expiration
      # Click the expiration button to open the menu
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var btns = document.querySelectorAll('button');" +
          "  for (var i = 0; i < btns.length; i++) {" +
          "    var t = btns[i].textContent.trim();" +
          "    if (t.indexOf('days') !== -1 && t.indexOf('expir') === -1) {" +
          "      btns[i].click(); return 'OK';" +
          "    }" +
          "  }" +
          "  return 'NOT_FOUND:expiration_button';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "expiration dropdown button")
      sleep 0.5

      # Select "Custom" from the menu
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var items = document.querySelectorAll('[role=menuitemradio]');" +
          "  for (var i = 0; i < items.length; i++) {" +
          "    if (items[i].textContent.trim() === 'Custom') {" +
          "      items[i].click(); return 'OK';" +
          "    }" +
          "  }" +
          "  return 'NOT_FOUND:custom_expiration_option';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "'Custom' expiration option")
    end

    def set_expiration_date(days)
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var input = document.querySelector('input[type=date]');" +
          "  if (!input) return 'NOT_FOUND:expiration_date_input';" +
          "  var d = new Date(); d.setDate(d.getDate() + #{days.to_i});" +
          "  var val = d.toISOString().split('T')[0];" +
          "  if (input.max && val > input.max) val = input.max;" +
          "  input.value = val;" +
          "  input.dispatchEvent(new Event('input', {bubbles: true}));" +
          "  input.dispatchEvent(new Event('change', {bubbles: true}));" +
          "  return 'OK';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "expiration date input")
    end

    # GitHub's repo picker uses a dialog overlay: click "Only select repositories"
    # radio, then a "Select repositories" button opens a dialog with a search filter
    # and [role=option] buttons. The filter matches repo name only (not owner/repo).
    # Each step is a separate execute_js call for reliable error detection.
    def select_repository(repo)
      click_select_repositories_radio
      open_repository_dialog
      filter_and_select_repo(repo)
      close_repository_dialog
      verify_repository_selected!(repo)
    end

    def click_select_repositories_radio
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var radio = document.querySelector('input[value=selected][name=install_target]');" +
          "  if (!radio) return 'NOT_FOUND:select_repos_radio';" +
          "  radio.click();" +
          "  return 'OK';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "'Only select repositories' radio button")
      sleep 0.5
    end

    def open_repository_dialog
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var buttons = document.querySelectorAll('button');" +
          "  for (var i = 0; i < buttons.length; i++) {" +
          "    if (buttons[i].textContent.trim().indexOf('Select repositor') !== -1) {" +
          "      buttons[i].click(); return 'OK';" +
          "    }" +
          "  }" +
          "  return 'NOT_FOUND:select_repos_button';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "'Select repositories' button")
      sleep 0.5
    end

    def filter_and_select_repo(repo)
      repo_name = repo.include?("/") ? repo.split("/", 2).last : repo
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        var searchTerm = #{repo_name.to_json};
        var fullRepo = #{repo.to_json};
        var escSearch = searchTerm.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
        var escFull = fullRepo.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
        safari.doJavaScript(
          "(function() {" +
          "  var dialog = document.querySelector('dialog[open]');" +
          "  if (!dialog) return 'NOT_FOUND:repo_dialog';" +
          "  var search = dialog.querySelector('input[name=filter], input[type=search]');" +
          "  if (!search) return 'NOT_FOUND:repo_search_input';" +
          "  search.value = '" + escSearch + "';" +
          "  search.dispatchEvent(new Event('input', {bubbles: true}));" +
          "  return 'OK';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "repository search dialog")
      sleep 1
      click_repo_option(repo)
    end

    def click_repo_option(repo)
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        var fullRepo = #{repo.to_json};
        var escFull = fullRepo.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
        safari.doJavaScript(
          "(function() {" +
          "  var dialog = document.querySelector('dialog[open]');" +
          "  if (!dialog) return 'NOT_FOUND:repo_dialog';" +
          "  var options = dialog.querySelectorAll('[role=option]');" +
          "  for (var i = 0; i < options.length; i++) {" +
          "    if (options[i].textContent.indexOf('" + escFull + "') !== -1) {" +
          "      options[i].click(); return 'OK';" +
          "    }" +
          "  }" +
          "  return 'NOT_FOUND:repo_option';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "repository '#{repo}' in search results")
    end

    def close_repository_dialog
      execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var dialog = document.querySelector('dialog[open]');" +
          "  if (!dialog) return 'OK';" +
          "  var closeBtn = dialog.querySelector('button[aria-label=Close]');" +
          "  if (closeBtn) { closeBtn.click(); return 'OK'; }" +
          "  return 'OK';" +
          "})()",
          {in: tab}
        );
      JS
      sleep 1
    end

    # GitHub's permissions UI: click "Add permissions" to expand a [role=option] list,
    # click a permission to add it (defaults to "Read-only"), then optionally click the
    # "Access:Read-only" button (aria-haspopup=true) and select "Read and write".
    def set_permissions(permissions)
      permissions.each do |perm_name, level|
        display_name = perm_name.tr("_", " ")
        expand_add_permissions
        add_permission_option(display_name)
        set_permission_level(display_name) if level == "write"
        sleep 1
      end
    end

    def expand_add_permissions
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var expandables = document.querySelectorAll('[aria-expanded]');" +
          "  for (var i = 0; i < expandables.length; i++) {" +
          "    if (expandables[i].textContent.trim().indexOf('Add permissions') !== -1) {" +
          "      if (expandables[i].getAttribute('aria-expanded') === 'false') expandables[i].click();" +
          "      return 'OK';" +
          "    }" +
          "  }" +
          "  return 'NOT_FOUND:add_permissions_button';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "'Add permissions' button")
      sleep 0.5
    end

    def add_permission_option(display_name)
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        var permName = #{display_name.to_json};
        var escPerm = permName.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
        safari.doJavaScript(
          "(function() {" +
          "  var options = document.querySelectorAll('[role=option]');" +
          "  for (var i = 0; i < options.length; i++) {" +
          "    var t = options[i].textContent.trim().toLowerCase();" +
          "    if (t === '" + escPerm.toLowerCase() + "' || t.indexOf('" + escPerm.toLowerCase() + "') === 0) {" +
          "      options[i].click(); return 'OK';" +
          "    }" +
          "  }" +
          "  return 'NOT_FOUND:permission_option';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "permission '#{display_name}' in Add permissions list")
      sleep 0.5
    end

    def set_permission_level(display_name)
      # Click the "Access:Read-only" button for this permission to open the level menu
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var btns = document.querySelectorAll('button[aria-haspopup=true]');" +
          "  for (var i = 0; i < btns.length; i++) {" +
          "    if (btns[i].textContent.indexOf('Read-only') !== -1) {" +
          "      btns[i].click(); return 'OK';" +
          "    }" +
          "  }" +
          "  return 'NOT_FOUND:access_level_button';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "access level button for '#{display_name}'")
      sleep 0.5

      # Select "Read and write" from the menu
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var items = document.querySelectorAll('[role=menuitem], [role=menuitemradio]');" +
          "  for (var i = 0; i < items.length; i++) {" +
          "    if (items[i].textContent.trim() === 'Read and write') {" +
          "      items[i].click(); return 'OK';" +
          "    }" +
          "  }" +
          "  return 'NOT_FOUND:read_and_write_option';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "'Read and write' option for '#{display_name}'")
    end

    # Submits the PAT creation form. The form uses Turbo to load a confirmation
    # dialog into turbo-frame#fg_pat_confirmation_dialog. We click the form's
    # submit button, then poll until the confirmation frame is populated.
    def click_generate
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var btn = document.querySelector('.js-integrations-install-form-submit');" +
          "  if (!btn) return 'NOT_FOUND:generate_button';" +
          "  btn.click(); return 'OK';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "Generate token button")
      wait_for_confirmation_frame
    end

    # After clicking Generate, Turbo loads a confirmation dialog (with a
    # confirm=1 hidden field) into a turbo-frame. The dialog may not auto-open
    # via showModal() in the osascript context, so we open it explicitly, then
    # click the submit button *inside* the dialog to finalize token creation.
    def confirm_generation
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        safari.doJavaScript(
          "(function() {" +
          "  var dialog = document.getElementById('confirm-fg-pat');" +
          "  if (!dialog) return 'NOT_FOUND:confirmation_dialog';" +
          "  if (!dialog.open) dialog.showModal();" +
          "  var btn = dialog.querySelector('button[type=submit]');" +
          "  if (!btn) return 'NOT_FOUND:confirmation_submit';" +
          "  btn.click(); return 'OK';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "generation confirmation button")
      sleep 3
    end

    def wait_for_confirmation_frame
      8.times do
        sleep 1
        loaded = execute_js <<~JS
          var safari = Application("Safari");
          var tab = safari.windows[0].currentTab;
          safari.doJavaScript(
            "document.getElementById('confirm-fg-pat') ? 'LOADED' : 'WAITING'",
            {in: tab}
          );
        JS
        return if loaded.strip == "LOADED"
      end
      raise Error, "Confirmation dialog did not load after clicking Generate"
    end

    def extract_token
      10.times do
        sleep 1
        output = execute_js <<~JS
          var safari = Application("Safari");
          var tab = safari.windows[0].currentTab;
          safari.doJavaScript(
            "(function() {" +
            "  var token = document.querySelector('#new-access-token, [id*=token-value], code, .token-code, input[readonly][value^=github_pat_]');" +
            "  if (token) return token.value || token.textContent || '';" +
            "  var all = document.body.innerText;" +
            "  var match = all.match(/github_pat_[A-Za-z0-9_]+/);" +
            "  return match ? match[0] : '';" +
            "})()",
            {in: tab}
          );
        JS
        token = output.strip
        return token unless token.empty?
      end
      ""
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

    # Verifies a repository was actually selected after the dialog-based selection flow.
    # Critical: if repository selection fails silently, the PAT gets "All repositories"
    # scope instead of the requested single-repo scope — a security escalation.
    # After the dialog closes, the page shows "Selected 1 repository." text and the
    # repo name below the "Only select repositories" radio.
    def verify_repository_selected!(repo)
      output = execute_js <<~JS
        var safari = Application("Safari");
        var tab = safari.windows[0].currentTab;
        var repoName = #{repo.to_json};
        var esc = repoName.replace(/\\\\/g, "\\\\\\\\").replace(/'/g, "\\\\'");
        safari.doJavaScript(
          "(function() {" +
          "  var page = document.body.innerText;" +
          "  if (page.indexOf('" + esc + "') !== -1 && (page.indexOf('1 repository') !== -1 || page.indexOf('Selected') !== -1)) return 'OK';" +
          "  return 'NOT_FOUND:repository_selection';" +
          "})()",
          {in: tab}
        );
      JS
      check_result!(output, "repository '#{repo}' selection (token would scope to ALL repos)")
    end
  end
end
