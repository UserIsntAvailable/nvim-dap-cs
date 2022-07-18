local M = {}

--- Launchs a new dotnet process
---@param opts table { env, args }
---@return integer ( Process ID ) or error
function M.launch_dotnet(opts)
    local handle
    local pid_or_error
    local stdout = vim.loop.new_pipe(false)
    local spawn_opts = {
        stdio = { nil, stdout },
        env = opts.env or {
            ["VSTEST_HOST_DEBUG"] = "1",
            ["VSTEST_CONNECTION_TIMEOUT"] = "10",
        },
        args = opts.args or {},
        detached = true,
        hide = true,
    }

    handle, pid_or_error = vim.loop.spawn("dotnet", spawn_opts, function(exit_code)
        stdout:close()
        handle:close()

        if exit_code ~= 0 then
            ---@diagnostic disable-next-line: redundant-parameter
            vim.notify("dap-cs: dotnet exited with code " .. exit_code, vim.log.levels.ERROR)
        end
    end)

    assert(handle, "dap-cs: error running dotnet: " .. tostring(pid_or_error))

    stdout:read_start(function(err, data)
        assert(not err, err)
        if data then
            vim.schedule(function()
                require("dap.repl").append(data)
            end)
        end
    end)

    return pid_or_error
end

return M
