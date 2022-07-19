local M = {}

--- Launchs a new dotnet process
---@param opts table { env, args }
function M.launch_dotnet(opts, on_launch)
    local handle
    local pid_or_error
    local stdout = vim.loop.new_pipe(false)
    local stderr = vim.loop.new_pipe(false)
    local spawn_opts = {
        stdio = { nil, stdout, stderr },
        env = opts.env or {
            "DOTNET_CLI_HOME=~",
            "VSTEST_HOST_DEBUG=1",
            "VSTEST_CONNECTION_TIMEOUT=20",
        },
        cwd = opts.cwd or "",
        args = opts.args or {},
        detached = true,
        hide = true,
    }

    handle, pid_or_error = vim.loop.spawn("dotnet", spawn_opts, function(exit_code)
        stdout:close()
        stderr:close()
        handle:close()

        if exit_code ~= 0 then
            vim.notify("dap-cs: dotnet exited with code " .. exit_code, vim.log.levels.ERROR)
        end
    end)

    assert(handle, "dap-cs: error running dotnet: " .. tostring(pid_or_error))

    stdout:read_start(function(err, data)
        assert(not err, err)
        if data then
            vim.schedule(function()
                if tostring(data) == "Waiting for debugger attach..." then
                    on_launch(pid_or_error)
                end
                require("dap.repl").append(data)
            end)
        end
    end)

    stderr:read_start(function(err, data)
        assert(not err, err)
        if data then
            vim.schedule(function()
                require("dap.repl").append(data)
            end)
        end
    end)
end

return M
