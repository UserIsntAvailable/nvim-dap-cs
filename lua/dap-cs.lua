local query = require("vim.treesitter.query")
local ts_utils = require("nvim-treesitter.ts_utils")
local utils = require("utils")

local M = {}

-- TODO: feat: add more test frameworks
local tests_query = [[
((class_declaration
  name: (identifier) @class_name
   body: (declaration_list
     (method_declaration
       (attribute_list
         (attribute
           name: (identifier) @attribute_name))
       name: (identifier) @method_name)))
  (#match? @attribute_name "^(Fact|Theory)(Attribute)?$"))
]]

-- TODO: Put this on utils
local function launch_dotnet(args)
    local handle
    local pid_or_error
    local stdout = vim.loop.new_pipe(false)
    local spawn_opts = {
        stdio = { nil, stdout },
        env = {
            ["VSTEST_HOST_DEBUG"] = "1",
            ["VSTEST_CONNECTION_TIMEOUT"] = "10",
        },
        args = args,
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

local function get_current_project_path()
    return vim.fn.expand("%:p:h")
end

local function get_current_project_dll()
    local scan = utils.require_module("plenary").scandir

    -- FIX: People could move their bin folder elsewhere or change the name of the assembly, but
    -- that is outside of my scope ( Maybe I could parse the .csproj as a V2? )
    local bufdir = get_current_project_path()
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

-- returns treesitter capture info indicating what tests we should filter
-- TODO: Change name ASAP
local function get_test_current_context()
    local ft = vim.api.nvim_buf_get_option(0, "filetype")
    assert(ft == "cs", "dap-cs: can only debug cs files, not " .. ft)

    local parsed_query = vim.treesitter.parse_query(ft, tests_query)
    local current_node = ts_utils.get_node_at_cursor()

    while current_node do
        local iter = parsed_query:iter_captures(current_node, 0)
        local capture_ID, capture_node = iter()

        if capture_node == current_node then
            if parsed_query.captures[capture_ID] == "class_name" then
                return "class_name"
            end
            if parsed_query.captures[capture_ID] == "method_name" then
                return "method_name"
            end
        end

        current_node = current_node:parent()
    end

    return nil
end

local function setup_adapter(dap)
    -- TODO: Remote dap server
    dap.adapters.coreclr = {
        type = "executable",
        command = "netcoredbg",
        args = { "--interpreter=vscode" },
        enrich_config = function(config, on_config)
            if config.request == "attach" and not config.processId then
                local config_copy = vim.deepcopy(config)
                local args = config.dotnet_extra_args or {}

                table.insert(args, get_current_project_path)
                config_copy.processId = launch_dotnet(args)

                on_config(config_copy)
            end
        end,
    }
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
            program = get_current_project_dll,
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
            dotnet_extra_args = function()
                local current_node_context = get_test_current_context()

                -- FIX: Message LOL
                assert(current_node_context, "") -- I don't think I have more options to stop the flow of this

                return { "--filter", current_node_context }
            end,
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

-- TODO: config: be able to change location of dotnet and netcoredbg executables
-- TODO: config: don't build when running tests ( --no-build )
-- TODO: config: if current file is not test, run the previous successful one
-- TODO: error-handling: check if the actual dotnet sdk is installed
-- TODO: error-handling: check if the dotnet sdk matches the current project

function M.setup(opts)
    local dap = utils.require_module("dap")
    -- TODO: Should I really be doing this?
    utils.require_executables({ "netcoredbg" })

    setup_adapter(dap)
    setup_configuration(dap)
end

return M
