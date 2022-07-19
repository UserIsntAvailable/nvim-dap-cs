local M = {}

--- Launchs a dotnet process
--- @param opts table libuv spawn opts [ https://github.com/luvit/luv/blob/master/docs.md#uvspawnpath-options-on_exit ]
--- @return integer handle handle
function M.launch_dotnet(opts)
    local handle
    local pid_or_error
    local stdout = vim.loop.new_pipe(false)
    local stderr = vim.loop.new_pipe(false)

    local default_opts = {
        stdio = { nil, stdout, stderr },
        -- It seems that you can't run it wihout this
        env = { "DOTNET_CLI_HOME=" .. vim.fn.expand("$HOME"), unpack(opts.env) },
    }

    opts = vim.tbl_deep_extend("keep", default_opts, opts)

    handle, pid_or_error = vim.loop.spawn("dotnet", opts, function(exit_code)
        stdout:close()
        stderr:close()
        handle:close()

        if exit_code ~= 0 then
            vim.notify("dap-cs: dotnet exited with code " .. exit_code, vim.log.levels.ERROR)
        end
    end)

    assert(handle, "dap-cs: error running dotnet: " .. tostring(pid_or_error))

    return pid_or_error, stdout, stderr
end

--- Launchs a dotnet test process on debug mode
function M.launch_dotnet_test_debug(args, cwd, on_waiting_for_debugger)
    local _, stdout, stderr = M.launch_dotnet({
        env = {
            "VSTEST_HOST_DEBUG=1",
            "VSTEST_CONNECTION_TIMEOUT=10",
        },
        cwd = cwd or vim.fn.getcwd(),
        args = { "test", unpack(args) },
    })

    local read = function(err, data, on_valid_data)
        assert(not err, err)
        if data then
            vim.schedule(function()
                if on_valid_data then
                    on_valid_data(data)
                end
                require("dap.repl").append(data)
            end)
        end
    end

    local started
    stdout:read_start(function(err, data)
        read(err, data, function(valid_data)
            if not started then
                local match = string.match(tostring(valid_data), "Process Id: ([0-9]+),")
                if match then
                    -- FIX: Why processId is giving json parsing error?
                    on_waiting_for_debugger(tonumber(match))
                    started = true
                end
            end
        end)
    end)

    stderr:read_start(read)
end

return M
