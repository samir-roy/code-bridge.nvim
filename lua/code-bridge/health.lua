local M = {}

M.check = function()
  vim.health.start("code-bridge.nvim")

  -- Check tmux availability
  vim.fn.system('command -v tmux 2>/dev/null')
  if vim.v.shell_error == 0 then
    vim.health.ok("tmux is available")
  else
    vim.health.warn("tmux not found in PATH", "Install tmux to use CodeBridgeTmux functionality")
  end

  -- Check chat CLI (first configured process name, default claude)
  local cli = require('code-bridge').chat_cli()
  vim.fn.system('command -v ' .. vim.fn.shellescape(cli) .. ' 2>/dev/null')
  if vim.v.shell_error == 0 then
    vim.health.ok(cli .. " CLI is available")

    local version_result = vim.fn.system(vim.fn.shellescape(cli) .. ' --version 2>/dev/null')
    if vim.v.shell_error == 0 then
      vim.health.ok(cli .. " version: " .. vim.trim(version_result))
    else
      vim.health.error("could not get " .. cli .. " version")
    end
  else
    vim.health.error(cli .. " CLI not found in PATH",
      "Install " .. cli .. " to use CodeBridgeQuery and CodeBridgeChat functionality")
  end

  -- Check clipboard functionality
  local test_string = "test"
  vim.fn.setreg('+', test_string)
  local clipboard_result = vim.fn.getreg('+')
  if clipboard_result == test_string then
    vim.health.ok("clipboard functionality works")
  else
    vim.health.warn("clipboard may not be working properly", "Check clipboard configuration")
  end
end

return M
