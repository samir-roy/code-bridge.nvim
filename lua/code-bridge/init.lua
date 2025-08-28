-- code bridge neovim plugin
local M = {}

-- Default configuration
local config = {
  tmux = {
    target_mode = 'window_name', -- 'window_name', 'current_window', 'find_process'
    window_name = 'claude',      -- window name to search for when target_mode = 'window_name'
    process_name = 'claude',     -- process name to search for when target_mode = 'current_window' or 'find_process'
    switch_to_target = true,     -- whether to switch to the target after sending
  },
  interactive = {
    use_telescope = true,
  },
}

-- Track the chat buffer and window during the session
local chat_buffer = nil
local chat_window = nil
local running_process = nil

-- Build context string with filename and range
local function build_context(opts)
  if opts.use_all_buffers then
    -- Get all loaded buffers that are files
    local buffers = {}
    local current_file = vim.fn.expand('%')
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
        local buf_name = vim.api.nvim_buf_get_name(buf)
        local relative_name = vim.fn.fnamemodify(buf_name, ':~:.')
        if relative_name ~= '' and
            vim.fn.filereadable(buf_name) == 1 and
            not relative_name:match('^term://') and
            not relative_name:match('^%[')
        then
          -- If this is the current file and we have a visual selection, include the range
          if relative_name == current_file and opts.range == 2 then
            table.insert(buffers, '@' .. relative_name .. '#L' .. opts.line1 .. '-' .. opts.line2)
          else
            table.insert(buffers, '@' .. relative_name)
          end
        end
      end
    end
    return table.concat(buffers, ' ')
  else
    -- Single file context
    local relative_file = vim.fn.expand('%')
    if relative_file ~= '' then
      if opts.range == 2 then
        -- Visual mode - use the range from command
        return '@' .. relative_file .. '#L' .. opts.line1 .. '-' .. opts.line2
      else
        -- Normal mode - just file name, no line number
        return '@' .. relative_file
      end
    end
  end
  return ''
end

-- Build git diff context
local function build_git_diff_context(staged_only)
  local cmd = staged_only and 'git diff --cached' or 'git diff HEAD'
  local diff_output = vim.fn.system(cmd .. ' 2>/dev/null')

  if vim.v.shell_error ~= 0 or diff_output == '' then
    return nil, staged_only and "no staged changes" or "no git changes found"
  end

  -- Add a header to clarify what kind of diff this is
  local header = staged_only and "# Staged Changes (git diff --cached)\n" or "# Git Changes (git diff HEAD)\n"
  return header .. diff_output, nil
end

-- Build recently added files context
local function build_recent_files_context(limit)
  limit = limit or 10
  local files = {}

  -- Check if we're in a git repository
  vim.fn.system('git rev-parse --git-dir 2>/dev/null')
  local in_git_repo = vim.v.shell_error == 0

  if in_git_repo then
    -- First, get pending changes (staged and unstaged files)
    local pending_cmd = 'git diff --name-only HEAD 2>/dev/null'
    local pending_files = vim.fn.system(pending_cmd)

    if vim.v.shell_error == 0 and pending_files ~= '' then
      for line in pending_files:gmatch("[^\n]+") do
        if line ~= '' and vim.fn.filereadable(line) == 1 then
          table.insert(files, '@' .. line)
        end
      end
    end

    -- Then, get recently modified files from git history (if we need more)
    local remaining = limit - #files
    if remaining > 0 then
      local git_cmd = 'git log --name-only --pretty=format: --since="1 week ago" | sort | uniq | head -' .. remaining
      local git_recent = vim.fn.system(git_cmd .. ' 2>/dev/null')

      if vim.v.shell_error == 0 and git_recent ~= '' then
        for line in git_recent:gmatch("[^\n]+") do
          if line ~= '' and vim.fn.filereadable(line) == 1 then
            -- Avoid duplicates from pending changes
            local file_path = '@' .. line
            local already_added = false
            for _, existing in ipairs(files) do
              if existing == file_path then
                already_added = true
                break
              end
            end
            if not already_added and #files < limit then
              table.insert(files, file_path)
            end
          end
        end
      end
    end
  else
    -- Fallback: use Vim's recent files when not in git repo
    local vim_recent = vim.v.oldfiles or {}
    local cwd = vim.fn.getcwd()

    for _, file_path in ipairs(vim_recent) do
      if #files >= limit then break end
      -- Only include files from current working directory and that exist
      if file_path:sub(1, #cwd) == cwd and vim.fn.filereadable(file_path) == 1 then
        local relative_path = vim.fn.fnamemodify(file_path, ':~:.')
        table.insert(files, '@' .. relative_path)
      end
    end
  end

  if #files == 0 then
    local context = in_git_repo and "git repository" or "vim session"
    return nil, "no recent files found in " .. context
  end

  local header = in_git_repo and "# Recent Git Files (including pending changes)\n" or "# Recent Vim Files\n"
  return header .. table.concat(files, ' '), nil
end

-- Check if a tmux pane is running claude process
local function is_claude_process(pane_id)
  -- Get the full command line of the process in the pane
  local cmd = vim.fn.system('tmux display -p -t ' .. pane_id .. ' "#{pane_pid}" 2>/dev/null')
  if vim.v.shell_error ~= 0 then
    return false
  end

  local pid = cmd:gsub("%s+", "")
  if not pid or pid == "" then
    return false
  end

  -- Find child processes of the pane's main process (usually shell)
  local children_cmd = 'pgrep -P ' .. pid .. ' 2>/dev/null'
  local children = vim.fn.system(children_cmd)
  if vim.v.shell_error ~= 0 then
    return false
  end

  -- Check each child process
  for child_pid in children:gmatch("%d+") do
    local ps_cmd = 'ps -p ' .. child_pid .. ' -o args= 2>/dev/null'
    local args = vim.fn.system(ps_cmd)
    if vim.v.shell_error == 0 then
      if args:match(config.tmux.process_name) then
        return true
      end
    end
  end

  -- Fallback: check the parent process itself
  local parent_ps_cmd = 'ps -p ' .. pid .. ' -o args= 2>/dev/null'
  local parent_args = vim.fn.system(parent_ps_cmd)
  if vim.v.shell_error == 0 then
    if parent_args:match(config.tmux.process_name) then
      return true
    end
  end

  return false
end

-- Find pane running process in given panes info
local function find_pane_with_process(panes_info)
  -- Look for exact process name match
  for line in panes_info:gmatch("[^\n]+") do
    local pane_id, command = line:match("^(%S+)%s*(.*)$")
    if command and command:match(config.tmux.process_name) then
      return pane_id
    end
  end

  -- If find_node_process is enabled, look for node process with matching name
  if config.tmux.find_node_process then
    for line in panes_info:gmatch("[^\n]+") do
      local pane_id, command = line:match("^(%S+)%s*(.*)$")
      if command and command == "node" and is_claude_process(pane_id) then
        return pane_id
      end
    end
  end

  return nil
end

-- Find tmux target based on configuration
local function find_tmux_target()
  if config.tmux.target_mode == 'current_window' then
    -- Find pane with agent process in current window only
    local panes_info = vim.fn.system('tmux list-panes -F "#{pane_id} #{pane_current_command}" 2>/dev/null')
    if vim.v.shell_error ~= 0 then
      return nil, "not in tmux session"
    end

    local pane_id = find_pane_with_process(panes_info)
    if pane_id then
      return pane_id, nil
    end

    return nil, "no pane running " .. config.tmux.process_name .. " in current window"
  elseif config.tmux.target_mode == 'find_process' then
    -- Find pane with agent process
    local panes_info = vim.fn.system('tmux list-panes -a -F "#{pane_id} #{pane_current_command}" 2>/dev/null')
    if vim.v.shell_error ~= 0 then
      return nil, "not in tmux session"
    end

    local pane_id = find_pane_with_process(panes_info)
    if pane_id then
      return pane_id, nil
    end

    return nil, "no pane running " .. config.tmux.process_name
  else -- 'window_name' (default)
    -- Check if agent window exists
    vim.fn.system('tmux list-windows -F "#{window_name}" 2>/dev/null | grep -x ' .. config.tmux.window_name)
    if vim.v.shell_error == 0 then
      return config.tmux.window_name, nil
    else
      return nil, "no window named '" .. config.tmux.window_name .. "'"
    end
  end
end

-- Create interactive prompt input
local function create_prompt_input(initial_content, callback)
  -- Check if telescope is available
  --- @diagnostic disable-next-line: unused-local
  local has_telescope, telescope = pcall(require, 'telescope')
  if config.interactive.use_telescope and has_telescope then
    -- Use telescope input
    vim.ui.input({
      prompt = 'Agent Prompt: ',
      default = initial_content,
      completion = nil,
    }, function(input)
      if input and input ~= "" then
        callback(input)
      else
        print("prompt cancelled")
      end
    end)
  else
    -- Create a new buffer for prompt editing
    local buf = vim.api.nvim_create_buf(false, true)

    -- Calculate popup dimensions and position
    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.6)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    -- Create floating window
    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = width,
      height = height,
      row = row,
      col = col,
      style = 'minimal',
      border = 'rounded',
      title = ' Edit Prompt ',
      title_pos = 'center',
    })

    -- Set buffer options
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'text'
    vim.api.nvim_buf_set_name(buf, 'Prompt Editor')
    vim.b[buf].is_code_bridge_buffer = true

    -- Set initial content
    local lines = vim.split(initial_content, '\n')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Position cursor at end
    vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })

    -- Add instructions at the top
    local instructions = {
      "-- Edit your prompt below and press <C-s> to send, <C-c> to cancel --",
      "-- Context will be sent to the agent via tmux --",
      "",
    }
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, instructions)
    vim.api.nvim_win_set_cursor(win, { #instructions + #lines, #lines[#lines] })

    -- Set up keymaps for this buffer
    local opts = { buffer = buf, silent = true, nowait = true }

    local send_prompt = function()
      local content_lines = vim.api.nvim_buf_get_lines(buf, #instructions, -1, false)
      local final_content = table.concat(content_lines, '\n')
      vim.api.nvim_win_close(win, false)
      callback(final_content)
      print("prompt sent")
    end

    local cancel_prompt = function()
      vim.api.nvim_win_close(win, false)
      print("prompt cancelled")
    end

    vim.keymap.set('n', '<leader>s', send_prompt, opts)
    vim.keymap.set('n', '<C-s>', send_prompt, opts)
    vim.keymap.set('n', '<C-c>', cancel_prompt, opts)

    -- Also work in insert mode
    vim.keymap.set('i', '<C-s>', '<Esc><C-s>', opts)
    vim.keymap.set('i', '<C-c>', '<Esc><C-c>', opts)
  end
end

-- Escape message for tmux send-key with multi-line content and special characters
local function escape_for_tmux(message)
  -- Write to a temporary file and use tmux load-buffer + paste-buffer
  local temp_file = vim.fn.tempname()
  local file = io.open(temp_file, 'w')
  if file then
    file:write(message)
    file:close()
    return temp_file
  end
  return nil
end

-- Send message to tmux target
local function send_to_tmux_target(message)
  -- Check shell error and fallback to clipboard if needed
  local function check_shell_error(error_message)
    if vim.v.shell_error == 0 then
      return false
    end
    print(error_message .. ", copied to clipboard")
    return true
  end

  -- Always copy to clipboard (helpful in case claude code vim mode is not in insert mode)
  vim.fn.setreg('+', message)

  -- Check if we're in a tmux session
  vim.fn.system('tmux display-message -p "#{session_name}" 2>/dev/null')
  if check_shell_error("no tmux session") then return end

  -- Find tmux target
  local target, error_msg = find_tmux_target()
  if not target then
    print(error_msg .. ", copied to clipboard")
    return
  end

  -- For complex content (multi-line, special chars), use tmux buffer approach
  if message:find('\n') or message:find('[\'"`$\\]') then
    local temp_file = escape_for_tmux(message)
    if temp_file then
      -- Load message into tmux buffer, then paste it
      local cmd = string.format('tmux load-buffer "%s" \\; paste-buffer -t %s \\; delete-buffer', temp_file, target)
      vim.fn.system(cmd)
      -- Clean up temp file
      vim.fn.delete(temp_file)
      if check_shell_error("failed to send to " .. target) then return end
    else
      print("failed to create temp file, copied to clipboard")
      return
    end
  else
    -- Simple single-line content can use send-keys
    vim.fn.system('tmux send-keys -t ' .. target .. ' ' .. vim.fn.shellescape(message) .. ' Enter')
    if check_shell_error("failed to send to " .. target) then return end
  end

  -- Switch to target if configured
  if config.tmux.switch_to_target then
    local switch_cmd
    if config.tmux.target_mode == 'window_name' then
      switch_cmd = 'tmux select-window -t ' .. target
    else
      switch_cmd = 'tmux select-pane -t ' .. target
    end

    -- For pane targets, get the window info first and switch to window
    if config.tmux.target_mode == 'find_process' then
      local window_info = vim.fn.system('tmux list-panes -a -F "#{pane_id} #{window_id}" 2>/dev/null | grep "^' ..
        target .. ' "')
      if vim.v.shell_error == 0 and window_info ~= "" then
        local window_id = window_info:match("%S+%s+(%S+)")
        if window_id then
          vim.fn.system('tmux select-window -t ' .. window_id)
        end
      end
    end

    vim.fn.system(switch_cmd)
    if vim.v.shell_error ~= 0 then
      print("sent to " .. target .. " but failed to switch - please check manually")
    end
  else
    print("sent message to " .. target)
  end
end

local function send_to_tmux_wrapper(opts, context, error_msg)
  if vim.b.is_code_bridge_buffer == true then
    print("not available in prompt editor")
    return
  end
  if not context or context == '' then
    print(error_msg)
  elseif opts.interactive_prompt then
    create_prompt_input(context, send_to_tmux_target)
  else
    send_to_tmux_target(context)
  end
end

-- Send filename and position to tmux claude target (or copy to clipboard if unavailable)
M.send_to_claude_tmux = function(opts)
  local context = build_context(opts)
  send_to_tmux_wrapper(opts, context, "no file context available")
end

-- Send git diff to tmux claude target
M.send_git_diff_to_tmux = function(opts)
  local context, error_msg = build_git_diff_context(opts.staged_only)
  send_to_tmux_wrapper(opts, context, error_msg)
end

-- Send recently added files to tmux claude target
M.send_recent_files_to_tmux = function(opts)
  local context, error_msg = build_recent_files_context(opts.max_recent_files)
  send_to_tmux_wrapper(opts, context, error_msg)
end

-- Query Claude Code using its CLI option and show results in chat pane
M.claude_query = function(opts)
  if vim.b.is_code_bridge_buffer == true then
    print("not available in prompt editor")
    return
  end

  local include_context = opts.args ~= 'no-context'
  local context = include_context and build_context(opts) or ''
  local thinking_message = '## Thinking...'

  -- Check if chat is already thinking
  if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
    local current_lines = vim.api.nvim_buf_get_lines(chat_buffer, 0, -1, false)
    if #current_lines > 0 and current_lines[#current_lines] == thinking_message then
      print("please wait - thinking...")
      return
    end
  end

  -- Prompt for user input
  local message = vim.fn.input('chat: ')
  if message == '' then
    return
  end

  -- Combine context and message
  local full_message = context ~= '' and (context .. ' ' .. message) or message

  -- Track the original window to return to it later
  local original_win = vim.api.nvim_get_current_win()
  local is_reuse = false
  local buf

  -- Check if chat buffer and window exist
  if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
    if chat_window and vim.api.nvim_win_is_valid(chat_window) then
      -- Window exists, just switch to it
      vim.api.nvim_set_current_win(chat_window)
      buf = chat_buffer
      is_reuse = true
    else
      -- Buffer exists but window doesn't, create new window
      vim.cmd('rightbelow vsplit')
      vim.api.nvim_win_set_buf(0, chat_buffer)
      chat_window = vim.api.nvim_get_current_win()
      buf = chat_buffer
      is_reuse = true
      vim.bo[chat_buffer].bufhidden = 'wipe'
    end
  else
    -- Create new buffer and split window
    vim.cmd('rightbelow vsplit')
    vim.cmd('enew')

    -- Save in local variables for reuse
    buf = vim.api.nvim_get_current_buf()
    chat_buffer = buf
    chat_window = vim.api.nvim_get_current_win()

    -- Set buffer options
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_name(buf, 'Chat')
    vim.wo.wrap = true
    vim.wo.linebreak = true

    -- Set up autocommand to clean up when buffer is wiped
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      callback = function()
        -- Terminate running process if exists
        if running_process then
          running_process:kill()
          running_process = nil
        end
        chat_buffer = nil
        chat_window = nil
      end
    })
  end

  -- Prepare the query lines
  local query_lines = { '# Query', full_message, '', thinking_message }

  -- Add a separator if continuing an existing chat
  if is_reuse then
    local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local separator = { '', '-------------------------------------', '' }
    vim.list_extend(current_lines, separator)
    vim.list_extend(current_lines, query_lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_lines)
    local buf_window = vim.fn.bufwinid(buf)
    if buf_window ~= -1 then
      vim.api.nvim_win_set_cursor(buf_window, { #current_lines, 0 })
    end
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, query_lines)
  end

  -- Return focus to original window
  vim.api.nvim_set_current_win(original_win)

  -- Set command based on new or existing chat
  local cmd_args = is_reuse and { config.tmux.process_name, '-c', '-p', full_message } or
      { config.tmux.process_name, '-p', full_message }

  -- Execute the command asynchronously
  running_process = vim.system(cmd_args, {}, function(result)
    vim.schedule(function()
      running_process = nil

      if vim.api.nvim_buf_is_valid(buf) then
        local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        -- Find and replace the last waiting message
        for i = #current_lines, 1, -1 do
          if current_lines[i] == thinking_message then
            current_lines[i] = '# Response'
            break
          end
        end

        -- Check for errors
        local output_text = result.stdout or 'No output received'
        if result.stderr and result.stderr ~= '' then
          output_text = 'Error: ' .. result.stderr
        end

        -- Add the response
        local lines = vim.split(output_text, '\n')
        vim.list_extend(current_lines, lines)

        -- Update the buffer
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_lines)

        -- Scroll to bottom if window is valid
        if chat_window and vim.api.nvim_win_is_valid(chat_window) then
          vim.api.nvim_win_set_cursor(chat_window, { #current_lines, 0 })
        end
      end
    end)
  end)
end

-- Hide chat buffer without clearing it
M.hide_chat = function()
  if chat_window and vim.api.nvim_win_is_valid(chat_window) then
    -- Change bufhidden to prevent wiping when window closes
    if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
      vim.bo[chat_buffer].bufhidden = 'hide'
    end
    vim.api.nvim_win_close(chat_window, false)
    chat_window = nil
  end
end

-- Show chat buffer if it exists
M.show_chat = function()
  if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
    if chat_window and vim.api.nvim_win_is_valid(chat_window) then
      -- Window exists, just focus on it
      vim.api.nvim_set_current_win(chat_window)
    else
      -- Buffer exists but window doesn't, create new window
      vim.cmd('rightbelow vsplit')
      vim.api.nvim_win_set_buf(0, chat_buffer)
      chat_window = vim.api.nvim_get_current_win()
      vim.wo.wrap = true
      vim.wo.linebreak = true
      vim.bo[chat_buffer].bufhidden = 'wipe'
      -- Scroll to bottom
      local lines = vim.api.nvim_buf_get_lines(chat_buffer, 0, -1, false)
      vim.api.nvim_win_set_cursor(chat_window, { #lines, 0 })
    end
  else
    print("no chat buffer to show")
  end
end

-- Wipe chat buffer and clear it
M.wipe_chat = function()
  -- Cancel running query
  if running_process then
    running_process:kill()
    running_process = nil
  end
  -- Close the chat window and buffer if it exists
  if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
    vim.api.nvim_buf_delete(chat_buffer, { force = true })
    chat_buffer = nil
    chat_window = nil
  end
end

-- Cancel running queries
M.cancel_query = function()
  if running_process then
    running_process:kill()
    running_process = nil

    -- Update the buffer to remove thinking message
    if chat_buffer and vim.api.nvim_buf_is_valid(chat_buffer) then
      local current_lines = vim.api.nvim_buf_get_lines(chat_buffer, 0, -1, false)
      for i = #current_lines, 1, -1 do
        if current_lines[i] == '## Thinking...' then
          current_lines[i] = '# Cancelled'
          break
        end
      end
      vim.api.nvim_buf_set_lines(chat_buffer, 0, -1, false, current_lines)
    end
  else
    print("no running query to cancel")
  end
end

-- Setup function for plugin initialization
M.setup = function(user_config)
  -- Merge user config with defaults
  if user_config then
    config = vim.tbl_deep_extend('force', config, user_config)
  end

  -- Tmux bridge commands
  vim.api.nvim_create_user_command('CodeBridgeTmux', M.send_to_claude_tmux, { range = true })
  vim.api.nvim_create_user_command('CodeBridgeTmuxAll', function(opts)
    opts.use_all_buffers = true
    M.send_to_claude_tmux(opts)
  end, { range = true })
  vim.api.nvim_create_user_command('CodeBridgeTmuxInteractive', function(opts)
    opts.interactive_prompt = true
    M.send_to_claude_tmux(opts)
  end, { range = true })
  vim.api.nvim_create_user_command('CodeBridgeTmuxAllInteractive', function(opts)
    opts.use_all_buffers = true
    opts.interactive_prompt = true
    M.send_to_claude_tmux(opts)
  end, { range = true })

  -- Git diff commands
  vim.api.nvim_create_user_command('CodeBridgeTmuxDiff', function(opts)
    opts.staged_only = false
    M.send_git_diff_to_tmux(opts)
  end, {})
  vim.api.nvim_create_user_command('CodeBridgeTmuxDiffStaged', function(opts)
    opts.staged_only = true
    M.send_git_diff_to_tmux(opts)
  end, {})

  -- Recent files commands
  vim.api.nvim_create_user_command('CodeBridgeTmuxRecent', function(opts)
    opts.max_recent_files = 10
    M.send_recent_files_to_tmux(opts)
  end, {})
  vim.api.nvim_create_user_command('CodeBridgeTmuxRecentInteractive', function(opts)
    opts.interactive_prompt = true
    opts.max_recent_files = 10
    M.send_recent_files_to_tmux(opts)
  end, {})

  -- Interactive chat commands
  vim.api.nvim_create_user_command('CodeBridgeQuery', M.claude_query, { range = true })
  vim.api.nvim_create_user_command('CodeBridgeChat', function(opts)
    opts.args = 'no-context'
    M.claude_query(opts)
  end, { range = true })
  vim.api.nvim_create_user_command('CodeBridgeHide', M.hide_chat, {})
  vim.api.nvim_create_user_command('CodeBridgeShow', M.show_chat, {})
  vim.api.nvim_create_user_command('CodeBridgeWipe', M.wipe_chat, {})
  vim.api.nvim_create_user_command('CodeBridgeCancelQuery', M.cancel_query, {})
end

return M
