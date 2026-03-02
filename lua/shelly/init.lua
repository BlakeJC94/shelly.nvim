--- Shelly: A Neovim terminal plugin for REPL integration
--- Provides functions to interact with terminal buffers, send code, and manage terminal windows
local M = {}

--- Store the marked terminal info
--- @type { buf: number?, job_id: number?, win: number? }
local marked_terminal = {
    buf = nil,
    job_id = nil,
    win = nil,
    split_size = nil,
    split_direction = nil,
}

--- Default configuration for Shelly
--- @type table
local CONFIG = {
    cmd = vim.o.shell,
    cwd = vim.fn.getcwd,
    split = {
        direction = "horizontal",
        size = 16,
        position = "bottom",
    },
    wo = {
        cursorcolumn = false,
        cursorline = false,
        number = false,
        relativenumber = false,
        signcolumn = "no",
        spell = false,
        wrap = false,
    },
    capture_register = "+", -- register to store terminal output after each send
    capture_delay = 500,    -- ms to wait after sending before reading terminal output
    prompt_patterns = {
        "^In %[%d+%]:%s*$", -- IPython prompt
        "^%.%.%.:%s*$",      -- IPython continuation
        "^>>>%s*$",          -- Python / MicroPython prompt
        "^%.%.%.%s*$",       -- Python continuation
        "^>%s*$",            -- Node, R, Lua prompt
        "^:%s*$",            -- Julia prompt
        "%%cpaste",          -- IPython %cpaste command
        "^<EOF>$",            -- IPython %cpaste EOF marker
    },
}

--- Recursively evaluate options, calling functions and traversing tables
--- @param opts any Option value (function, table, or primitive)
--- @return any Evaluated option value
local function eval_opts(opts)
    if type(opts) == "function" then
        return opts()
    end
    if type(opts) == "table" then
        local res = {}
        for k, v in pairs(opts) do
            res[k] = eval_opts(v)
        end
        return res
    end
    return opts
end

--- Get the split size to use when opening the window
--- Returns the last known size from state if the user has resized, otherwise falls back to the config default
--- @return number Split size in lines (horizontal) or columns (vertical)
local function get_split_size()
    if marked_terminal.split_size ~= nil then
        return marked_terminal.split_size
    end
    return eval_opts(CONFIG.split).size
end

--- Get the split direction to use when opening the window
--- Returns the last known direction from state if the user has rotated the split, otherwise falls back to the config default
--- @return string Split direction ("horizontal" or "vertical")
local function get_split_direction()
    if marked_terminal.split_direction ~= nil then
        return marked_terminal.split_direction
    end
    return eval_opts(CONFIG.split).direction
end

--- Generate the Vim split command based on configuration
--- @param config table Configuration containing split settings
--- @return string Vim command string for creating a split
local function get_split_cmd(config)
    local opts = eval_opts(config.split)
    local pos = (opts.position == "left" or opts.position == "top") and "topleft" or "botright"
    local dir = get_split_direction() == "vertical" and " vertical" or ""
    return pos .. dir .. " " .. get_split_size() .. "split"
end

--- Create a new window split and configure window options
--- @param config table Configuration containing split and window settings
--- @param buf number Buffer number to display in the window
--- @return number Window handle
local function create_win(config, buf)
    vim.cmd(get_split_cmd(config))
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    for opt, val in pairs(config.wo) do
        vim.wo[win][opt] = val
    end

    -- persist size and direction whenever this window is resized or rotated
    vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
            if not vim.api.nvim_win_is_valid(win) then
                return true -- delete the autocmd
            end
            -- v:event.windows contains the list of window IDs that were resized
            local resized = vim.v.event.windows or {}
            for _, wid in ipairs(resized) do
                if wid == win then
                    local win_width = vim.api.nvim_win_get_width(win)
                    local win_height = vim.api.nvim_win_get_height(win)
                    -- infer direction: a window spanning the full editor height is a vertical split
                    if win_height >= vim.o.lines - vim.o.cmdheight - 1 then
                        marked_terminal.split_direction = "vertical"
                        marked_terminal.split_size = win_width
                    else
                        marked_terminal.split_direction = "horizontal"
                        marked_terminal.split_size = win_height
                    end
                    break
                end
            end
        end,
    })

    return win
end

--- Detect if the terminal buffer is running IPython
--- @param buf number Buffer number to check
--- @return boolean True if IPython is detected
local function is_ipython(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end

    local lines = vim.api.nvim_buf_get_lines(buf, -10, -1, false)
    for _, line in ipairs(lines) do
        if string.match(line, "In %[%d+%]:") or string.match(line, "IPython") then
            return true
        end
    end
    return false
end

--- Get the name of the process running in the terminal
--- First tries to get the foreground child process, falls back to the terminal process itself
--- @param job_id number? Terminal job ID
--- @return string? Process name or nil if not found
local function get_terminal_process(job_id)
    if not job_id then
        return nil
    end

    local pid = vim.fn.jobpid(job_id)
    if not pid or pid <= 0 then
        return nil
    end

    -- First, try to get the foreground process using pgrep
    -- This finds child processes of the terminal that are NOT the shell itself
    local handle = io.popen(string.format("pgrep -P %d | head -n 1", pid))
    if handle then
        local child_pid = handle:read("*a")
        handle:close()

        if child_pid and child_pid ~= "" then
            child_pid = child_pid:gsub("^%s*(.-)%s*$", "%1")
            -- Get the command name of the child process
            handle = io.popen(string.format("ps -o comm= -p %s", child_pid))
            if handle then
                local result = handle:read("*a")
                handle:close()
                if result and result ~= "" then
                    result = result:gsub("^%s*(.-)%s*$", "%1")
                    return result
                end
            end
        end
    end

    -- Fallback: get the terminal's own process if no children found
    handle = io.popen(string.format("ps -o comm= -p %d", pid))
    if not handle then
        return nil
    end

    local result = handle:read("*a")
    handle:close()

    if not result or result == "" then
        return nil
    end

    result = result:gsub("^%s*(.-)%s*$", "%1")
    return result
end

--- Check if the terminal is running the shell (not a REPL or other program)
--- @param job_id number? Terminal job ID
--- @return boolean True if the process is the shell
local function is_shell_process(job_id)
    local process = get_terminal_process(job_id)
    if not process then
        return false
    end

    -- Extract the basename from the process path
    local process_parts = vim.fn.split(process, "/")
    local process_name = process_parts[#process_parts]

    -- Extract the basename from vim.o.shell (e.g., "/bin/bash" -> "bash")
    local shell_parts = vim.fn.split(vim.o.shell, "/")
    local shell_name = shell_parts[#shell_parts]

    -- Compare the process name with the shell name
    return process_name == shell_name
end

--- Extract text from a range (used by both visual selection and operator motions)
--- @param start_pos table Start position {line, col}
--- @param end_pos table End position {line, col}
--- @param motion_type string Type of motion: "line" or "char"
--- @return string? Extracted text or nil if no text found
local function extract_text_range(start_pos, end_pos, motion_type)
    local lines = vim.api.nvim_buf_get_lines(0, start_pos[1] - 1, end_pos[1], false)

    if #lines == 0 then
        return nil
    end

    -- For line motion, use full lines
    if motion_type == "line" then
        return table.concat(lines, "\n")
    end

    -- For char motion, handle column positions
    if #lines == 1 then
        lines[1] = string.sub(lines[1], start_pos[2] + 1, end_pos[2] + 1)
    else
        -- Multi-line: trim first and last lines
        lines[1] = string.sub(lines[1], start_pos[2] + 1)
        lines[#lines] = string.sub(lines[#lines], 1, end_pos[2] + 1)
    end

    return table.concat(lines, "\n")
end

--- Validate conditions before sending text (safety checks)
--- @return boolean True if conditions are valid for sending text
local function validate_send_conditions()
    -- Safety check: prevent sending text from terminal buffer to itself
    if vim.bo.buftype == "terminal" then
        vim.notify("Cannot send text from a terminal buffer to itself.", vim.log.levels.ERROR)
        return false
    end

    -- Safety check: prevent sending text to shell processes
    if is_shell_process(marked_terminal.job_id) then
        vim.notify("Cannot send text: active process is your shell. Start a REPL first.", vim.log.levels.ERROR)
        return false
    end

    return true
end

--- Strip ANSI/terminal escape sequences from a string
--- @param s string Raw string possibly containing escape codes
--- @return string Cleaned string
local function strip_ansi(s)
    return s:gsub("\27%[[%d;]*[A-Za-z]", "")
end

--- Return true if a line matches any prompt or control pattern from CONFIG
--- @param line string
--- @return boolean
local function is_prompt_line(line)
    for _, pat in ipairs(CONFIG.prompt_patterns) do
        if line:match(pat) then
            return true
        end
    end
    return false
end

--- Capture new terminal output into the configured register
--- Reads lines added to the terminal buffer since line_count_before,
--- removes sent_lines from the top of the captured output (in order, one
--- match at a time), strips prompt/control lines, strips escape codes and
--- trailing blank lines, then stores the result in CONFIG.capture_register.
--- @param buf number Terminal buffer number
--- @param line_count_before number Line count snapshot taken before sending
--- @param sent_lines string[] Individual lines that were sent (used to strip echoed input)
local function capture_terminal_output(buf, line_count_before, sent_lines)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, line_count_before, -1, false)

    -- Strip ANSI escape sequences
    for i, line in ipairs(lines) do
        lines[i] = strip_ansi(line)
    end

    -- Remove sent lines from the top of the captured output in order.
    -- For each sent line, scan from the current top and remove the first match.
    for _, sent in ipairs(sent_lines) do
        for i = 1, #lines do
            if lines[i] == sent then
                table.remove(lines, i)
                break
            end
        end
    end

    -- Remove all prompt and control lines (prompts, %cpaste, EOF markers, etc.)
    local filtered = {}
    for _, line in ipairs(lines) do
        if not is_prompt_line(line) then
            filtered[#filtered + 1] = line
        end
    end
    lines = filtered

    -- Strip trailing blank lines
    while #lines > 0 and lines[#lines]:match("^%s*$") do
        table.remove(lines)
    end

    -- Only overwrite the register when there is something to store
    if #lines > 0 then
        vim.fn.setreg(CONFIG.capture_register, table.concat(lines, "\n"))
    end
end

--- Send text to the marked terminal, auto-detecting IPython mode
--- After a configurable delay the output produced by the command is captured
--- into CONFIG.capture_register (default: unnamed register).
--- @param text string Text to send to the terminal
local function send_text_to_terminal(text)
    if not marked_terminal.buf or not vim.api.nvim_buf_is_valid(marked_terminal.buf) then
        vim.notify("No terminal available. Use :ShellyCycle or M.toggle() to create one first.", vim.log.levels.ERROR)
        return
    end

    if not marked_terminal.job_id then
        vim.notify("Terminal job ID not found.", vim.log.levels.ERROR)
        return
    end

    local buf = marked_terminal.buf

    -- Snapshot the last non-empty line index so that trailing empty lines in
    -- the terminal buffer are not counted; output that fills those lines would
    -- otherwise be skipped by capture_terminal_output.
    local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local line_count_before = #all_lines
    while line_count_before > 0 and all_lines[line_count_before]:match("^%s*$") do
        line_count_before = line_count_before - 1
    end
    line_count_before = line_count_before - 1

    -- Auto-detect IPython mode
    if is_ipython(buf) then
        -- Use IPython's %cpaste mode for multi-line code
        vim.api.nvim_chan_send(marked_terminal.job_id, "%cpaste -q\n")
        vim.defer_fn(function()
            vim.api.nvim_chan_send(marked_terminal.job_id, text .. "\n")
            vim.api.nvim_chan_send(marked_terminal.job_id, "\x04") -- Ctrl-D to end paste mode
        end, 50)
    else
        vim.api.nvim_chan_send(marked_terminal.job_id, text .. "\n")
    end

    local sent_lines = vim.split(text, "\n", { plain = true })
    vim.defer_fn(function()
        capture_terminal_output(buf, line_count_before, sent_lines)
    end, CONFIG.capture_delay)
end

--- Check if a line is a cell delimiter (for cell-based execution)
--- @param line string Line of text to check
--- @return boolean True if line is a cell delimiter
local function is_cell_delimiter(line)
    return string.match(line, "^%s*[#%-%-]%s+%%%%") or string.match(line, "^%s*In%[%d+%]") or string.match(line, "^```")
end

--- Send the current line to the terminal
M.send_line = function()
    if not validate_send_conditions() then
        return
    end

    send_text_to_terminal(vim.api.nvim_get_current_line())
end

--- Send arbitrary text to the terminal (used by :Shelly command)
--- Supports % expansions for file paths
--- @param cmd_opts table Command options containing args field
M.send_to_terminal = function(cmd_opts)
    local text = cmd_opts.args
    local current_file = vim.api.nvim_buf_get_name(0)
    if current_file ~= "" then
        text = text:gsub("()%%%S*", function(pos)
            if pos > 1 and text:sub(pos - 1, pos - 1) == "\\" then
                return nil
            end
            return vim.fn.expand(text:sub(pos))
        end)
    end
    -- Create terminal
    if not marked_terminal.buf or not vim.api.nvim_buf_is_valid(marked_terminal.buf) then
        -- Auto-toggle terminal if no marked terminal is found
        M.toggle()
        vim.defer_fn(function()
            if not marked_terminal.buf or not vim.api.nvim_buf_is_valid(marked_terminal.buf) then
                vim.notify("Failed to create terminal.", vim.log.levels.ERROR)
                return
            end
            send_text_to_terminal(text)
        end, 100)
        return
    end
    send_text_to_terminal(text)
end

--- Send the visual selection to the terminal
M.send_visual_selection = function()
    -- Exit visual mode to update '< and '> marks, then get the selection
    -- This ensures we get the actual selected range regardless of selection direction
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")

    -- Get lines in the visual selection range
    local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)

    if #lines == 0 then
        return
    end

    -- Trim to the selected columns
    if #lines == 1 then
        lines[1] = string.sub(lines[1], start_pos[3], end_pos[3])
    else
        lines[1] = string.sub(lines[1], start_pos[3])
        lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
    end

    local text = table.concat(lines, "\n")

    if not validate_send_conditions() then
        return
    end

    send_text_to_terminal(text)
end

--- Send the current cell to the terminal and jump to next cell
--- Cells are delimited by # %%, -- %%, In[n], or ``` markers
M.send_current_cell = function()
    local current_line = vim.api.nvim_win_get_cursor(0)[1]
    local total_lines = vim.api.nvim_buf_line_count(0)
    local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    -- Find the start of the current cell
    local cell_start = 1
    for i = current_line, 1, -1 do
        if is_cell_delimiter(all_lines[i]) then
            cell_start = i + 1
            break
        end
    end

    -- Find the end of the current cell
    local cell_end = total_lines
    local next_cell_start = nil
    for i = current_line + 1, total_lines do
        if is_cell_delimiter(all_lines[i]) then
            cell_end = i - 1
            next_cell_start = i
            break
        end
    end

    -- Get the cell content
    local cell_lines = vim.api.nvim_buf_get_lines(0, cell_start - 1, cell_end, false)

    -- Remove empty lines at the beginning and end
    while #cell_lines > 0 and cell_lines[1]:match("^%s*$") do
        table.remove(cell_lines, 1)
    end
    while #cell_lines > 0 and cell_lines[#cell_lines]:match("^%s*$") do
        table.remove(cell_lines)
    end

    if #cell_lines == 0 then
        vim.notify("No cell content found", vim.log.levels.WARN)
        return
    end

    local text = table.concat(cell_lines, "\n")

    if not validate_send_conditions() then
        return
    end

    send_text_to_terminal(text)

    -- Jump to the next cell if it exists
    if next_cell_start then
        vim.api.nvim_win_set_cursor(0, { next_cell_start, 0 })
    end
end

--- Send text based on operator motion (for use with operator-pending mode)
--- @param motion_type string Type of motion: "char", "line", or "block"
M.operator_send = function(motion_type)
    if motion_type == "block" then
        vim.notify("Block selection not supported", vim.log.levels.WARN)
        return
    end

    if motion_type ~= "char" and motion_type ~= "line" then
        return
    end

    local start_pos = vim.api.nvim_buf_get_mark(0, "[")
    local end_pos = vim.api.nvim_buf_get_mark(0, "]")
    local text = extract_text_range(start_pos, end_pos, motion_type)

    if text then
        if not validate_send_conditions() then
            return
        end

        send_text_to_terminal(text)
    end
end

--- Cycle between terminal focus states
--- In terminal mode: exit to normal mode and jump to bottom
--- In normal mode (terminal buffer): switch to last active window
--- Elsewhere: focus terminal and enter terminal mode
M.cycle = function()
    local term = marked_terminal
    local current_buf = vim.api.nvim_get_current_buf()
    local mode = vim.api.nvim_get_mode().mode

    if term.buf and current_buf == term.buf then
        if mode == "t" then
            -- Case 1: Terminal mode in marked terminal - exit terminal mode and jump to bottom
            vim.cmd("stopinsert")
            vim.schedule(function()
                vim.cmd.norm("G")
            end)
            return
        else
            -- Case 2: Normal mode in marked terminal - go to last active window
            vim.cmd("wincmd w")
        end
        return
    end

    -- Case 3: Normal mode elsewhere - toggle terminal to visible if needed and start terminal mode
    if not term.win or not vim.api.nvim_win_is_valid(term.win) then
        M.toggle()
    end

    -- Verify window is valid after toggle (could fail if job creation failed)
    if not term.win or not vim.api.nvim_win_is_valid(term.win) then
        vim.notify("Failed to open terminal window.", vim.log.levels.ERROR)
        return
    end

    vim.api.nvim_set_current_win(term.win)
    vim.cmd.startinsert()
end

--- Initialize the terminal buffer and start the shell/REPL process
--- @param buf_ready boolean Whether the buffer already exists and is ready
local init_buffer = function(buf_ready)
    local term = marked_terminal
    local cmd = eval_opts(CONFIG.cmd) or vim.o.shell
    local cwd = eval_opts(CONFIG.cwd) or vim.fn.getcwd()
    buf_ready = buf_ready or false

    if not buf_ready then
        local job_id = vim.fn.jobstart(cmd, { cwd = cwd, term = true })
        if job_id == 0 then
            vim.notify("shelly: Invalid arguments for terminal command", vim.log.levels.ERROR)
            -- Clean up on failure
            if term.win and vim.api.nvim_win_is_valid(term.win) then
                vim.api.nvim_win_close(term.win, true)
            end
            if term.buf and vim.api.nvim_buf_is_valid(term.buf) then
                vim.api.nvim_buf_delete(term.buf, { force = true })
            end
            marked_terminal.buf = nil
            marked_terminal.win = nil
            marked_terminal.job_id = nil
            return
        elseif job_id == -1 then
            vim.notify("shelly: Terminal command not executable: " .. cmd, vim.log.levels.ERROR)
            -- Clean up on failure
            if term.win and vim.api.nvim_win_is_valid(term.win) then
                vim.api.nvim_win_close(term.win, true)
            end
            if term.buf and vim.api.nvim_buf_is_valid(term.buf) then
                vim.api.nvim_buf_delete(term.buf, { force = true })
            end
            marked_terminal.buf = nil
            marked_terminal.win = nil
            marked_terminal.job_id = nil
            return
        end
        term.job_id = job_id
    else
        term.job_id = vim.b[term.buf].terminal_job_id
    end
end

--- Check if the terminal window is currently open
--- @return boolean True if the terminal window is open and valid
local is_open = function()
    local term = marked_terminal
    return term.win and vim.api.nvim_win_is_valid(term.win)
end

--- Toggle the terminal window visibility
M.toggle = function()
    if is_open() then
        M.close()
    else
        M.open()
    end
end

--- Open the terminal window (creates buffer if needed)
M.open = function()
    if is_open() then
        return
    end
    local term = marked_terminal
    local buf_ready = term.buf and vim.api.nvim_buf_is_valid(term.buf)

    if not buf_ready then
        term.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[term.buf].buflisted = false
        vim.api.nvim_buf_set_name(term.buf, "Shelly")

        vim.api.nvim_create_autocmd("BufDelete", {
            buffer = term.buf,
            once = true,
            callback = function()
                marked_terminal.buf = nil
                marked_terminal.job_id = nil
                marked_terminal.win = nil
            end,
        })
    end

    local prev_win = vim.api.nvim_get_current_win()
    term.win = create_win(CONFIG, term.buf)

    init_buffer(buf_ready)

    -- This enables the terminal to auto-scroll
    vim.cmd.norm("G")

    if vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
    end
end

--- Close the terminal window (keeps buffer alive)
M.close = function()
    local term = marked_terminal
    if is_open() then
        vim.api.nvim_win_close(term.win, true)
        term.win = nil
    end
end

--- Setup function to initialize Shelly with user configuration
--- Creates user commands and autocommands
--- @param opts table? Optional configuration table to override defaults
M.setup = function(opts)
    CONFIG = vim.tbl_deep_extend("force", CONFIG, opts or {})

    -- Create user commands
    local commands = {
        {
            name = "Shelly",
            fn = M.send_to_terminal,
            opts = { nargs = "+", desc = "Send arbitrary text to the marked terminal (auto-detects IPython)" },
        },
        {
            name = "ShellyToggle",
            fn = M.toggle,
            opts = { desc = "" },
        },
        {
            name = "ShellyOpen",
            fn = M.open,
            opts = { desc = "" },
        },
        {
            name = "ShellyClose",
            fn = M.close,
            opts = { desc = "" },
        },
        {
            name = "ShellySendLine",
            fn = M.send_line,
            opts = { desc = "Send current line to the marked terminal (auto-detects IPython)" },
        },
        {
            name = "ShellySendSelection",
            fn = M.send_visual_selection,
            opts = { range = true, desc = "Send visual selection to the marked terminal (auto-detects IPython)" },
        },
        {
            name = "ShellySendCell",
            fn = M.send_current_cell,
            opts = { desc = "Send current cell (between # %%, -- %%, In[n], or ``` markers) to the marked terminal" },
        },
        {
            name = "ShellyCycle",
            fn = M.cycle,
            opts = { desc = "Toggle terminal focus and mode" },
        },
    }

    for _, cmd in ipairs(commands) do
        vim.api.nvim_create_user_command(cmd.name, cmd.fn, cmd.opts)
    end

    -- Kill all terminal buffers on exit
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("shelly_cleanup", { clear = true }),
        callback = function()
            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "terminal" then
                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            end
        end,
    })
end

return M
