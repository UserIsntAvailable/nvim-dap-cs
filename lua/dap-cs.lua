local query = require("vim.treesitter.query")

local M = {}

-- TODO: feat: add more test frameworks
local single_test_query = [[
(method_declaration
  (attribute_list
        (attribute
              name: (identifier) @attribute_name))
  name: (identifier) @test_name
  (#match? @attribute_name "^(Fact|Theory)(Attribute)?$"))
]]

local function require_module(module_name)
    local status_ok, module = pcall(require, module_name)
    assert(status_ok, string.format("dap-cs: '%s' plugin dependency is missing", module_name))
    return module
end

local function require_executables(executables)
    for _, executable in ipairs(executables) do
        assert(
            vim.fn.executable(executable) == 1 and true or false,
            string.format("dap-cs: '%s' executable dependency is missing", executable)
        )
    end
end

local function launch_dotnet(opts)
    local dotnet_args = {}

    if opts.test_filter then
        table.insert(dotnet_args, "--filter")
        table.insert(dotnet_args, opts.test_filter)
    end

    if opts.no_build then
        table.insert(dotnet_args, "--no-build")
    end

    local handle
    local pid_or_error
    local stdout = vim.loop.new_pipe(false)
    local spawn_opts = {
        stdio = { nil, stdout },
        env = {
            ["VSTEST_HOST_DEBUG"] = "1",
            ["VSTEST_CONNECTION_TIMEOUT"] = "10",
        },
        args = dotnet_args,
        detached = true,
        hide = true,
    }

    handle, pid_or_error = vim.loop.spawn("dotnet", spawn_opts, function(exit_code)
        stdout:close()
        handle:close()

        if exit_code ~= 0 then
            ---@diagnostic disable-next-line: redundant-parameter
            vim.notify("dap-cs: dotnet exited with code " .. exit_code, "ERROR")
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

local function setup_adapter(dap)
    -- TODO: Remote dap server
    dap.adapters.coreclr = {
        type = "executable",
        command = "netcoredbg",
        args = { "--interpreter=vscode" },
    }
end

local function get_current_file_project_dlls()
    local scan = require_module("plenary").scandir

    -- FIX: People could move their bin folder elsewhere or change the name of the assembly, but
    -- that is outside of my scope ( Maybe I could parse the .csproj as a V2? )
    local bufdir = vim.fn.expand("%:p:h")
    local dirname = vim.fn.expand("%:p:h:t")
    local dlls = scan.scan_dir(bufdir .. "/bin", { depth = 3, search_pattern = dirname .. ".dll" })

    if #dlls == 1 then
        return dlls[1]
    end

    local selection = require("dap.ui").pick_one_sync(
        dlls,
        "What dll you want to debug?",
        function(dll)
            return string.gsub(dll, bufdir, ".")
        end
    )

    if selection == nil then
        ---@diagnostic disable-next-line: redundant-parameter
        vim.notify("dap-cs: Debug session canceled", "WARN")
    end

    return selection
end

local function setup_configuration(dap)
    dap.configurations.cs = {
        -- TODO:
        -- Debug ( Select project [ Can find tests projects ] )
        -- .NET Framework
        -- Attach to Remote Process
        {
            type = "coreclr",
            name = "Debug Project",
            request = "launch",
            program = get_current_file_project_dlls,
        },
        {
            type = "coreclr",
            name = "Debug Tests",
            request = "attach",
        },
        {
            type = "coreclr",
            name = "Debug Test",
            request = "attach",
        },
        {
            type = "coreclr",
            name = "Attach to Process",
            request = "attach",
            -- TODO: PR to change to vim.ui.select or just implement myself
            processId = require("dap.utils").pick_process,
        },
    }
end

local function get_closest_test()
    local ft = vim.api.nvim_buf_get_option(0, "filetype")
    assert(ft == "cs", "dap-cs: can only debug cs files, not " .. ft)

    local parser = vim.treesitter.get_parser(0)
    local root = (parser:parse()[1]):root()
    local parsed_query = vim.treesitter.parse_query(ft, single_test_query)

    for _, match, _ in parsed_query:iter_matches(root, 0, 0, vim.api.nvim_win_get_cursor(0)[1]) do
        print(match)
    end

    return ""
end

-- TODO: config: be able to change location of dotnet and netcoredbg executables
-- TODO: config: don't build when running tests ( --no-build )
-- TODO: config: if current file is not test, run the last one
-- TODO: error_handling: check if the actual dotnet sdk is installed
-- TODO: error_handling: check if the dotnet sdk matches the current project
function M.setup(opts)
    local dap = require_module("dap")
    require_executables({ "netcoredbg" })

    setup_adapter(dap)
    setup_configuration(dap)
end

-- Debug:
--  Single Test
--  Single File Tests

-- TODO: config: override --no-build global flag
function M.debug_test(opts) end

return M
