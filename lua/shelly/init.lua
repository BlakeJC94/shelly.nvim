local M = {}

-- Store the marked terminal info
local marked_terminal = { buf = nil, job_id = nil, win = nil }

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
}

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

local function get_split_cmd(config)
    local opts = eval_opts(config.split)
    local pos = (opts.position == "left" or opts.position == "top") and "topleft" or "botright"
    local dir = opts.direction == "vertical" and " vertical" or ""
    return pos .. dir .. " " .. opts.size .. "split"
end

local function create_win(config, buf)
    vim.cmd(get_split_cmd(config))
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    for opt, val in pairs(config.wo) do
        vim.wo[win][opt] = val
    end
    return win
end

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

local function is_shell_process(job_id)
    local process = get_terminal_process(job_id)
    local process_parts = vim.fn.split(process, "/")
    local process_head = process_parts[#process_parts]
    return process_head == "sh" or process_head == "bash" or process_head == "zsh"
end

-- Extract text from a range (used by both visual selection and operator motions)
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

local function send_text_to_terminal(text)
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

    if not marked_terminal.job_id then
        vim.notify("Terminal job ID not found.", vim.log.levels.ERROR)
        return
    end

    -- Auto-detect IPython mode
    if is_ipython(marked_terminal.buf) then
        -- Use IPython's %cpaste mode for multi-line code
        vim.api.nvim_chan_send(marked_terminal.job_id, "%cpaste -q\n")
        vim.defer_fn(function()
            vim.api.nvim_chan_send(marked_terminal.job_id, text .. "\n")
            vim.api.nvim_chan_send(marked_terminal.job_id, "\x04") -- Ctrl-D to end paste mode
        end, 50)
    else
        vim.api.nvim_chan_send(marked_terminal.job_id, text .. "\n")
    end
end

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

    -- Safety check: prevent sending text from terminal buffer to itself
    if vim.bo.buftype == "terminal" then
        vim.notify("Cannot send text from a terminal buffer to itself.", vim.log.levels.ERROR)
        return
    end

    -- Safety check: prevent sending text to shell processes
    if is_shell_process(marked_terminal.job_id) then
        vim.notify(
            "Cannot send text: active process is a shell (sh/bash/zsh). Start a REPL first.",
            vim.log.levels.ERROR
        )
        return
    end

    send_text_to_terminal(text)
end

local function is_cell_delimiter(line)
    return string.match(line, "^%s*[#%-%-]%s+%%%%") or string.match(line, "^%s*In%[%d+%]") or string.match(line, "^```")
end

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

    -- Safety check: prevent sending text from terminal buffer to itself
    if vim.bo.buftype == "terminal" then
        vim.notify("Cannot send text from a terminal buffer to itself.", vim.log.levels.ERROR)
        return
    end

    -- Safety check: prevent sending text to shell processes
    if is_shell_process(marked_terminal.job_id) then
        vim.notify(
            "Cannot send text: active process is a shell (sh/bash/zsh). Start a REPL first.",
            vim.log.levels.ERROR
        )
        return
    end

    send_text_to_terminal(text)

    -- Jump to the next cell if it exists
    if next_cell_start then
        vim.api.nvim_win_set_cursor(0, { next_cell_start, 0 })
    end
end

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
        -- Safety check: prevent sending text from terminal buffer to itself
        if vim.bo.buftype == "terminal" then
            vim.notify("Cannot send text from a terminal buffer to itself.", vim.log.levels.ERROR)
            return
        end

        -- Safety check: prevent sending text to shell processes
        if is_shell_process(marked_terminal.job_id) then
            vim.notify(
                "Cannot send text: active process is a shell (sh/bash/zsh). Start a REPL first.",
                vim.log.levels.ERROR
            )
            return
        end

        send_text_to_terminal(text)
    end
end

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
    vim.api.nvim_set_current_win(term.win)
    vim.cmd.startinsert()
end

M.toggle = function()
    local term = marked_terminal
    local cmd = eval_opts(CONFIG.cmd) or vim.o.shell
    local cwd = eval_opts(CONFIG.cwd) or vim.fn.getcwd()
    local buf_ready = term.buf and vim.api.nvim_buf_is_valid(term.buf)

    -- Create buffer if needed
    if not buf_ready then
        term.buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_option(term.buf, "buflisted", false)
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

    -- Toggle window
    if term.win and vim.api.nvim_win_is_valid(term.win) then
        vim.api.nvim_win_close(term.win, true)
        term.win = nil
    else
        local prev_win = vim.api.nvim_get_current_win()
        term.win = create_win(CONFIG, term.buf)

        -- Start terminal if buffer is new
        if not buf_ready then
            local job_id = vim.fn.jobstart(cmd, { cwd = cwd, term = true })
            if job_id == 0 then
                vim.notify("shelly: Invalid arguments for terminal command", vim.log.levels.ERROR)
                return
            elseif job_id == -1 then
                vim.notify("shelly: Terminal command not executable: " .. cmd, vim.log.levels.ERROR)
                return
            end
            term.job_id = job_id
        else
            term.job_id = vim.b[term.buf].terminal_job_id
        end

        -- This enables the terminal to auto-scroll
        vim.cmd.norm("G")

        if vim.api.nvim_win_is_valid(prev_win) then
            vim.api.nvim_set_current_win(prev_win)
        end
    end
end

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
    send_text_to_terminal(text)
end

M.send_line = function()
    send_text_to_terminal(vim.api.nvim_get_current_line())
end

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
            opts = { desc = "Send current cell (between # %%, -- %%, In[n], or ``` markers) to the marked terminal" },
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
