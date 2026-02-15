local M = {}

-- Default configuration
M.config = {
  server_url = "http://localhost:8081",
  language = "en-US",
  -- Severity mapping for different issue types
  severity = {
    typographical = vim.diagnostic.severity.HINT,
    grammar = vim.diagnostic.severity.WARN,
    misspelling = vim.diagnostic.severity.ERROR,
    style = vim.diagnostic.severity.INFO,
    default = vim.diagnostic.severity.WARN,
  },
}

-- Namespace for diagnostics
M.ns = vim.api.nvim_create_namespace("languagetool")

-- Store matches for applying fixes later
M.matches = {}

--- Setup the plugin with user configuration
---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Create user commands
  vim.api.nvim_create_user_command("LTCheck", function(cmd_opts)
    if cmd_opts.range > 0 then
      M.check_range(cmd_opts.line1, cmd_opts.line2)
    else
      M.check_current_line()
    end
  end, { range = true, desc = "Check text with LanguageTool" })

  vim.api.nvim_create_user_command("LTCheckBuffer", function()
    M.check_buffer()
  end, { desc = "Check entire buffer with LanguageTool" })

  vim.api.nvim_create_user_command("LTFix", function()
    M.show_fixes_at_cursor()
  end, { desc = "Show fixes for issue at cursor" })

  vim.api.nvim_create_user_command("LTClear", function()
    M.clear_diagnostics()
  end, { desc = "Clear LanguageTool diagnostics" })
end

--- URL encode a string
---@param str string
---@return string
local function url_encode(str)
  if str then
    -- Don't convert \n to \r\n - keep original newlines for offset consistency
    str = string.gsub(str, "([^%w _%%%-%.~\n])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    str = string.gsub(str, " ", "+")
    str = string.gsub(str, "\n", "%%0A")
  end
  return str
end

--- Make an async request to LanguageTool API
---@param text string The text to check
---@param callback fun(matches: table|nil, err: string|nil)
local function check_text_async(text, callback)
  local url = M.config.server_url .. "/v2/check"
  local data = "language=" .. url_encode(M.config.language) .. "&text=" .. url_encode(text)

  vim.system(
    { "curl", "-s", "--data", data, url },
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        callback(nil, "curl failed with code " .. result.code)
        return
      end

      local ok, response = pcall(vim.json.decode, result.stdout)
      if not ok then
        callback(nil, "Failed to parse JSON response")
        return
      end

      if response.matches then
        callback(response.matches, nil)
      else
        callback({}, nil)
      end
    end)
  )
end

--- Make an async request to LanguageTool API for an entire file
---@param path string The path of the file we want to check
---@param callback fun(matches: table|nil, err: string|nil)
local function check_file_async(path, callback)
  local url = M.config.server_url .. "/v2/check"
  local language_data = "language=" .. url_encode(M.config.language)
  vim.system(
    { "curl", "-s", "--data", language_data, "--data-urlencode", "text@"..path, url },
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        callback(nil, "curl failed with code " .. result.code)
        return
      end

      local ok, response = pcall(vim.json.decode, result.stdout)
      if not ok then
                print(result.stdout)
        callback(nil, response)
        return
      end

      if response.matches then
        callback(response.matches, nil)
      else
        callback({}, nil)
      end
    end)
  )

end

--- Convert LanguageTool issue type to vim diagnostic severity
---@param match table
---@return integer
local function get_severity(match)
  local issue_type = match.rule and match.rule.issueType
  if issue_type and M.config.severity[issue_type] then
    return M.config.severity[issue_type]
  end

  -- Check category for additional hints
  local category = match.rule and match.rule.category and match.rule.category.id
  if category then
    category = category:lower()
    if category:find("spell") or category:find("typo") then
      return vim.diagnostic.severity.ERROR
    elseif category:find("grammar") then
      return vim.diagnostic.severity.WARN
    elseif category:find("style") then
      return vim.diagnostic.severity.INFO
    elseif category:find("casing") or category:find("typography") then
      return vim.diagnostic.severity.HINT
    end
  end

  return M.config.severity.default
end

--- Convert a byte offset in concatenated text to line/col position
---@param offset integer byte offset in the concatenated text
---@param lines string[] the original lines
---@return integer line 0-indexed line number
---@return integer col 0-indexed column (byte offset within line)
local function offset_to_position(offset, lines)
  local remaining = offset
  for line_idx, line in ipairs(lines) do
    local line_len = #line
    if remaining <= line_len then
      return line_idx - 1, remaining
    end
    -- +1 for the newline character between lines
    remaining = remaining - line_len - 1
  end
  -- Past end of text, return end of last line
  local last_line = lines[#lines] or ""
  return #lines - 1, #last_line
end

--- Convert LanguageTool matches to vim diagnostics
---@param matches table
---@param start_line integer 0-indexed line where the checked text starts
---@param lines string[] The lines that were checked
---@return table[] diagnostics
local function matches_to_diagnostics(matches, start_line, lines)
  local diagnostics = {}

  for _, match in ipairs(matches) do
    local start_line_rel, start_col = offset_to_position(match.offset, lines)
    local end_line_rel, end_col = offset_to_position(match.offset + match.length, lines)

    local diag = {
      lnum = start_line + start_line_rel,
      col = start_col,
      end_lnum = start_line + end_line_rel,
      end_col = end_col,
      message = match.message,
      severity = get_severity(match),
      source = "languagetool",
      user_data = {
        match = match,
        start_line = start_line,
      },
    }

    -- Add rule info if available
    if match.rule then
      diag.code = match.rule.id
    end

    table.insert(diagnostics, diag)
  end

  return diagnostics
end

--- Store matches for a buffer for later fix application
---@param bufnr integer
---@param matches table[]
---@param start_line integer
local function store_matches(bufnr, matches, start_line)
  if not M.matches[bufnr] then
    M.matches[bufnr] = {}
  end

  for _, match in ipairs(matches) do
    table.insert(M.matches[bufnr], {
      match = match,
      start_line = start_line,
    })
  end
end

--- Clear stored matches for a buffer
---@param bufnr integer
local function clear_matches(bufnr)
  M.matches[bufnr] = {}
end

--- Check the current line
function M.check_current_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_idx = cursor[1] - 1 -- 0-indexed
  local line = vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)[1]

  if not line or line == "" then
    vim.notify("Empty line", vim.log.levels.INFO)
    return
  end

  vim.notify("Checking with LanguageTool...", vim.log.levels.INFO)

  check_text_async(line, function(matches, err)
    if err then
      vim.notify("LanguageTool error: " .. err, vim.log.levels.ERROR)
      return
    end

    if #matches == 0 then
      vim.notify("No issues found", vim.log.levels.INFO)
      return
    end

    -- Clear previous diagnostics for this line
    local existing = vim.diagnostic.get(bufnr, { namespace = M.ns })
    local filtered = vim.tbl_filter(function(d)
      return d.lnum ~= line_idx
    end, existing)
    vim.diagnostic.set(M.ns, bufnr, filtered, {})

    -- Add new diagnostics
    local diagnostics = matches_to_diagnostics(matches, line_idx, { line })
    local all_diagnostics = vim.list_extend(filtered, diagnostics)
    vim.diagnostic.set(M.ns, bufnr, all_diagnostics, {})

    -- Store matches
    store_matches(bufnr, matches, line_idx)

    vim.notify(string.format("Found %d issue(s)", #matches), vim.log.levels.INFO)
  end)
end

--- Check a range of lines
---@param line1 integer 1-indexed start line
---@param line2 integer 1-indexed end line
function M.check_range(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = line1 - 1 -- 0-indexed
  local end_line = line2
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)

  if #lines == 0 then
    vim.notify("No text selected", vim.log.levels.INFO)
    return
  end

  local text = table.concat(lines, "\n")

  vim.notify("Checking with LanguageTool...", vim.log.levels.INFO)

  check_text_async(text, function(matches, err)
    if err then
      vim.notify("LanguageTool error: " .. err, vim.log.levels.ERROR)
      return
    end

    if #matches == 0 then
      vim.notify("No issues found", vim.log.levels.INFO)
      return
    end

    -- Clear previous diagnostics for this range
    local existing = vim.diagnostic.get(bufnr, { namespace = M.ns })
    local filtered = vim.tbl_filter(function(d)
      return d.lnum < start_line or d.lnum >= end_line
    end, existing)
    vim.diagnostic.set(M.ns, bufnr, filtered, {})

    -- Add new diagnostics
    local diagnostics = matches_to_diagnostics(matches, start_line, lines)
    local all_diagnostics = vim.list_extend(filtered, diagnostics)
    vim.diagnostic.set(M.ns, bufnr, all_diagnostics, {})

    -- Store matches
    store_matches(bufnr, matches, start_line)

    vim.notify(string.format("Found %d issue(s)", #matches), vim.log.levels.INFO)
  end)
end

--- Check the entire buffer
function M.check_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  if #lines == 0 then
    vim.notify("Empty buffer", vim.log.levels.INFO)
    return
  end

  local text = table.concat(lines, "\n")

  vim.notify("Checking buffer with LanguageTool...", vim.log.levels.INFO)

  check_file_async(vim.api.nvim_buf_get_name(0), function(matches, err)
    if err then
      vim.notify("LanguageTool error: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Clear all previous diagnostics
    M.clear_diagnostics()
    clear_matches(bufnr)

    if #matches == 0 then
      vim.notify("No issues found", vim.log.levels.INFO)
      return
    end

    -- Add new diagnostics
    local diagnostics = matches_to_diagnostics(matches, 0, lines)
    vim.diagnostic.set(M.ns, bufnr, diagnostics, {})

    -- Store matches
    store_matches(bufnr, matches, 0)

    vim.notify(string.format("Found %d issue(s)", #matches), vim.log.levels.INFO)
  end)
end

--- Clear all LanguageTool diagnostics from current buffer
function M.clear_diagnostics()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.diagnostic.reset(M.ns, bufnr)
  clear_matches(bufnr)
end

--- Get the diagnostic at cursor position
---@return table|nil diagnostic
local function get_diagnostic_at_cursor()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1] - 1
  local col = cursor[2]

  local diagnostics = vim.diagnostic.get(0, {
    namespace = M.ns,
    lnum = line,
  })

  for _, diag in ipairs(diagnostics) do
    if col >= diag.col and col < diag.end_col then
      return diag
    end
  end

  -- If cursor is not exactly on a diagnostic, return the first one on the line
  return diagnostics[1]
end

--- Show available fixes for the issue at cursor
function M.show_fixes_at_cursor()
  local diag = get_diagnostic_at_cursor()

  if not diag then
    vim.notify("No LanguageTool issue at cursor", vim.log.levels.INFO)
    return
  end

  local match = diag.user_data and diag.user_data.match
  if not match then
    vim.notify("No fix data available", vim.log.levels.WARN)
    return
  end

  local replacements = match.replacements or {}
  if #replacements == 0 then
    vim.notify("No replacements available for this issue", vim.log.levels.INFO)
    return
  end

  -- Build the items for selection
  local items = {}
  for _, replacement in ipairs(replacements) do
    table.insert(items, replacement.value)
  end

  -- Show selection UI
  vim.ui.select(items, {
    prompt = "Select replacement:",
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not choice then
      return -- User cancelled
    end

    -- Apply the fix
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_text(
      bufnr,
      diag.lnum,
      diag.col,
      diag.end_lnum,
      diag.end_col,
      { choice }
    )

    -- Remove the diagnostic
    local existing = vim.diagnostic.get(bufnr, { namespace = M.ns })
    local filtered = vim.tbl_filter(function(d)
      return not (d.lnum == diag.lnum and d.col == diag.col)
    end, existing)
    vim.diagnostic.set(M.ns, bufnr, filtered, {})

    vim.notify("Applied fix: " .. choice, vim.log.levels.INFO)
  end)
end

return M
