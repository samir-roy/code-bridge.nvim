# code-bridge.nvim

A Neovim plugin that provides seamless integration between Neovim and Claude Code or other similar terminal
based coding agent like OpenCode, allowing you to send file context and queries directly to the agent from 
within your Neovim either via CLI or tmux. Messages can be sent to the agent in another tmux terminal or to
a chat buffer split within Neovim.

The goal of this plugin is not to provide the full IDE experience that Claude Code offers. This plugin
aims to make it easy to chat with claude code without running a terminal inside Neovim, and to interact
with a Claude Code session already running in agent mode in another terminal via tmux (or clipboard).

<img src="code-bridge-demo.gif" alt="code-bridge-demo" width="400">

## Features

- **Context Sharing**: Send current file, all open buffers, or line ranges to Claude Code
- **Tmux Integration**: Flexible targeting - window name, current window, or process search
- **Interactive Chat**: Query Claude Code with persistent chat buffer
- **Interactive Prompts**: Edit context and add questions before sending (uses Telescope if available)
- **Git Integration**: Send git diffs and recently changed files as context
- **Visual Mode Support**: Send selected line ranges as context
- **Fallback Support**: Copies context to clipboard when tmux is unavailable

## Requirements

- [Neovim](https://neovim.io/) 0.7+
- [Claude Code CLI](https://github.com/anthropics/claude-code) installed and configured
- [tmux](https://github.com/tmux/tmux) (optional, for automatic window switching)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "samir-roy/code-bridge.nvim",
  config = function()
    require('code-bridge').setup({
      tmux = {
        target_mode = 'window_name',     -- 'window_name', 'current_window', 'find_process'
        window_name = 'claude',          -- used when target_mode = 'window_name'
        process_name = 'claude',         -- used when target_mode = 'current_window' or 'find_process'
        switch_to_target = true,         -- whether to switch to target after sending
      },
      interactive = {
        use_telescope = true,            -- use telescope for interactive prompts (default: true)
      }
    })
  end
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "samir-roy/code-bridge.nvim",
  config = function()
    require('code-bridge').setup()
  end
}
```

### Manual Installation

Clone this repository to your Neovim configuration directory:
```bash
git clone https://github.com/samir-roy/code-bridge.nvim ~/.config/nvim/pack/plugins/start/code-bridge.nvim
```

Then add to your `init.lua`:
```lua
require('code-bridge').setup()
```

## Usage

The plugin provides extensive commands for different workflows:

### Basic File Context Commands

#### `:CodeBridgeTmux`
Send current file context to the agent via tmux. Works in normal and visual mode.

```vim
:CodeBridgeTmux
:'<,'>CodeBridgeTmux  " with visual selection
```

#### `:CodeBridgeTmuxAll`
Send all open buffers as context. In visual mode, includes your selection from current file plus all other buffers.

**Context Format:**
- Normal mode: `@filename.ext`
- Visual mode: `@filename.ext#L1-5`

### Advanced File Context Commands

#### `:CodeBridgeTmuxInteractive`
Edit the context prompt before sending (uses Telescope input if available).

#### `:CodeBridgeTmuxAllInteractive`
Edit all-buffers context prompt before sending.

#### `:CodeBridgeTmuxDiff`
Send current git changes (unstaged) to the agent.

#### `:CodeBridgeTmuxDiffStaged`
Send staged changes only to the agent.

#### `:CodeBridgeTmuxRecent`
Send recently modified files. In git repos: prioritizes pending changes + recent commits. Outside git: uses Vim's recent files.

#### `:CodeBridgeTmuxRecentInteractive`
Edit recent files context before sending.

### Chat Interface Commands

#### `:CodeBridgeQuery`

Opens an interactive chat with the coding agent inside Neovim itself. A persistent markdown buffer for the conversation
is opened in a split pane. Your message along with the file context is sent to the agent and the response is
shown in the conversation buffer. Subsequent messages are part of the same chat thread as long as the chat pane
is kept open. Closing the pane clears the chat history.

#### `:CodeBridgeChat`

Similar to `:CodeBridgeQuery` but without file context - useful for general questions.

#### `:CodeBridgeHide`

Hides the chat buffer window without clearing the chat history. The chat buffer remains in memory and can be reopened
with the next query or with the show command.

#### `:CodeBridgeShow`

Shows the chat buffer window if it exists but is hidden.

#### `:CodeBridgeWipe`

Clears the chat history and closes the chat. This also cancels any running queries.

#### `:CodeBridgeCancelQuery`

Cancels any currently running query.

## Tmux Integration (Optional)

For optimal experience, set up a tmux session with a window named "claude":

```bash
# Create or attach to tmux session
tmux new-session -d -s coding

# Create claude window
tmux new-window -t coding -n claude

# Start Claude Code in the claude window
tmux send-keys -t coding:claude 'claude' Enter
```

The plugin will:
1. Check if you're in a tmux session
2. Find the claude target based on your configuration:
   - **window_name**: Look for a window named "claude"
   - **current_window**: Search for claude process in current window only
   - **find_process**: Search all panes across all windows for claude process
3. Send the context and optionally switch to the target
4. Fall back to clipboard if tmux is unavailable or target not found

## Key Bindings (Optional)

Add these to your configuration for quick access:

```lua
-- Basic tmux commands
vim.keymap.set("n", "<leader>ct", ":CodeBridgeTmux<CR>", { desc = "Send file to claude" })
vim.keymap.set("v", "<leader>ct", ":CodeBridgeTmux<CR>", { desc = "Send selection to claude" })
vim.keymap.set("n", "<leader>ca", ":CodeBridgeTmuxAll<CR>", { desc = "Send all buffers to claude" })

-- Advanced tmux commands
vim.keymap.set("n", "<leader>ci", ":CodeBridgeTmuxInteractive<CR>", { desc = "Interactive prompt to claude" })
vim.keymap.set("n", "<leader>cd", ":CodeBridgeTmuxDiff<CR>", { desc = "Send git diff to claude" })
vim.keymap.set("n", "<leader>cr", ":CodeBridgeTmuxRecent<CR>", { desc = "Send recent files to claude" })

-- Chat interface
vim.keymap.set("n", "<leader>cq", ":CodeBridgeQuery<CR>", { desc = "Query claude with context" })
vim.keymap.set("v", "<leader>cq", ":CodeBridgeQuery<CR>", { desc = "Query claude with selection" })
vim.keymap.set("n", "<leader>cc", ":CodeBridgeChat<CR>", { desc = "Chat with claude" })
vim.keymap.set("n", "<leader>ch", ":CodeBridgeHide<CR>", { desc = "Hide chat window" })
vim.keymap.set("n", "<leader>cs", ":CodeBridgeShow<CR>", { desc = "Show chat window" })
vim.keymap.set("n", "<leader>cx", ":CodeBridgeWipe<CR>", { desc = "Wipe chat and clear history" })
vim.keymap.set("n", "<leader>ck", ":CodeBridgeCancelQuery<CR>", { desc = "Cancel running query" })
```

## Configuration

The plugin works out of the box with no configuration required. The following options are available:

- `target_mode`: How to find claude (`'window_name'`, `'current_window'`, `'find_process'`)
- `window_name`: Window name to search for when using `'window_name'` mode (default: `'claude'`)
- `process_name`: Process name to search for when using `'current_window'` or `'find_process'` mode (default: `'claude'`)
- `switch_to_target`: Whether to switch to the target after sending context (default: `true`)
- `use_telescope`: Use Telescope for interactive prompts when available (default: `true`)

### Examples

The plugin can be configured with various tmux targeting modes:

**`'window_name'` (default)**: Search for a tmux window by name
```lua
require('code-bridge').setup({
  tmux = {
    target_mode = 'window_name',
    window_name = 'claude',  -- window name to search for
  },
  interactive = {
    use_telescope = true,    -- use telescope for interactive prompts
  }
})
```

**`'current_window'`**: Search for claude process in the current tmux window
```lua
require('code-bridge').setup({
  tmux = {
    target_mode = 'current_window',
    process_name = 'claude',
    switch_to_target = true,  -- switch to claude pane after sending
  }
})
```

**`'find_process'`**: Find any pane running a claude process
```lua
require('code-bridge').setup({
  tmux = {
    target_mode = 'find_process',
    process_name = 'claude',  -- process name to search for
  }
})
```

## Example Workflows

### Interactive Chat Workflow
1. Open a file in Neovim
2. Select some lines in visual mode
3. Run `:CodeBridgeQuery`
4. Type your question about the selected code
5. View Claude's response in the chat buffer
6. Continue the conversation with follow-up queries

### Code Review Workflow
1. Make changes to your code
2. Run `:CodeBridgeTmuxDiff` to send git changes to Claude
3. Claude analyzes your changes and provides feedback

### Multi-file Analysis
1. Open several related files in Neovim
2. Select important code in current file (visual mode)
3. Run `:CodeBridgeTmuxAllInteractive`
4. Add question like "How do these components work together?"
5. Claude gets context from all files plus your selection

### Recent Work Context
1. Working on a project over time
2. Run `:CodeBridgeTmuxRecent` to send recent changes
3. Ask your question like "Summarize recent changes"

## Command Context Summary

| Command | Purpose | Context |
|---------|---------|----------|
| `:CodeBridgeTmux` | Basic file sending | Current file/selection |
| `:CodeBridgeTmuxAll` | Multi-file analysis | All open buffers |
| `:CodeBridgeTmuxInteractive` | Edit prompt first | Current file + your question |
| `:CodeBridgeTmuxAllInteractive` | Edit multi-file prompt | All buffers + your question |
| `:CodeBridgeTmuxDiff` | Code review | Git changes (unstaged) |
| `:CodeBridgeTmuxDiffStaged` | Staged review | Git changes (staged) |
| `:CodeBridgeTmuxRecent` | Recent context | Recent files + pending changes |
| `:CodeBridgeTmuxRecentInteractive` | Edit recent context | Recent files + your question |
| `:CodeBridgeQuery` | Interactive chat | File context + chat UI |
| `:CodeBridgeChat` | Simple chat | Chat UI only |

## License

Licensed under the GNU General Public License v2.0. See [LICENSE](LICENSE) for details.

## Contributing

Issues and pull requests are welcome! Please ensure your contributions align with the project's goals
of providing a Neovim-Claude integration that does not open a terminal inside Neovim and continue
using existing Claude Code session in another terminal.
