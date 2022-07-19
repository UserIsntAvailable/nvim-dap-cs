local query = require("vim.treesitter.query")
local ts_parsers = require("nvim-treesitter.parsers")
local ts_utils = require("nvim-treesitter.ts_utils")
local utils = require("dap-cs.utils")

local M = {}

-- TODO: feat: add more test frameworks
local test_query = [[
((class_declaration
  name: (identifier) @class-name
  body: (declaration_list
    (method_declaration
      (attribute_list
        (attribute
          name: (identifier) @attribute-name))))) @class-root
  (#match? @attribute-name "^(Fact|Theory)(Attribute)?$"))

((method_declaration
  (attribute_list
    (attribute
      name: (identifier) @attribute-name))
  name: (identifier) @method-name
  body: (_)) @method-root
  (#match? @attribute-name "^(Fact|Theory)(Attribute)?$"))
]]

local function require_module(module_name)
    local status_ok, module = pcall(require, module_name)
    assert(status_ok, string.format("dap-cs: '%s' plugin dependency is missing", module_name))
    return module
end

local function get_current_project_path()
    return vim.fn.expand("%:p:h")
end

local function select_project_dll()
    local scan = require_module("plenary").scandir

    -- FIX: People could move their bin folder elsewhere or change the name of the assembly, but
    -- that is outside of my scope ( Maybe I could parse the .csproj as a V2? )
    local bufdir = get_current_project_path()
    local dirname = vim.fn.expand("%:p:h:t")
    local dlls = scan.scan_dir(bufdir .. "/bin", { depth = 3, search_pattern = dirname .. ".dll" })

    if #dlls == 0 then
        vim.notify(
            "dap-cs: no dll was found ( maybe you forgot to compile the project? )",
            vim.log.levels.WARN
        )
        return
    elseif #dlls == 1 then
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
        vim.notify("dap-cs: selection canceled", vim.log.levels.WARN)
    end

    return selection
end

-- Captures info indicating in what object scope we currently are
-- @return The fully qualified name of { class_name | method_name } | nil
local function get_current_cursor_test_scope()
    local ft = vim.api.nvim_buf_get_option(0, "filetype")
    if ft ~= "cs" then
        vim.notify("dap-cs: can only debug cs files, not " .. ft, vim.log.levels.ERROR)
        return
    end

    local cs_query = vim.treesitter.parse_query(ts_parsers.ft_to_lang(ft), test_query)
    local node = ts_utils.get_node_at_cursor()

    local method_name
    while node do
        local iter = cs_query:iter_captures(node, 0)
        local capture_ID, capture_node = iter()

        if capture_node == node then
            if cs_query.captures[capture_ID] == "method-root" then
                while cs_query.captures[capture_ID] ~= "method-name" do
                    capture_ID, capture_node = iter()
                end

                method_name = query.get_node_text(capture_node, 0)
            end

            if cs_query.captures[capture_ID] == "class-root" then
                while capture_node == node do
                    capture_ID, capture_node = iter()
                end

                local class_name = query.get_node_text(capture_node, 0)

                return method_name and string.format("%s.%s", class_name, method_name) or class_name
            end
        end

        node = node:parent()
    end

    vim.notify("dap-cs: non-valid test scope found", vim.log.levels.ERROR)
end

local function setup_adapter(dap)
    -- TODO: Remote dap server
    dap.adapters.coreclr = {
        type = "executable",
        command = "netcoredbg",
        args = { "--interpreter=vscode" },
        enrich_config = function(config, on_config)
            if not config.program and not config.dotnet_extra_args then
                return
            end

            if config.request == "attach" and not config.processId then
                utils.launch_dotnet({
                    args = config.dotnet_extra_args,
                    cwd = get_current_project_path(),
                }, function(processId)
                    config.processId = processId
                    on_config(config)
                end)
                return
            end

            on_config(config)
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
            program = select_project_dll,
        },
        {
            type = "coreclr",
            name = "Debug Tests",
            request = "attach",
            dotnet_extra_args = { "test" },
        },
        {
            type = "coreclr",
            name = "Debug Test",
            request = "attach",
            dotnet_extra_args = function()
                local test_filter = get_current_cursor_test_scope()

                if test_filter then
                    return {
                        "test",
                        "--filter",
                        string.format("FullyQualifiedName=%s", test_filter),
                    }
                end
            end,
        },
        {
            type = "coreclr",
            name = "Attach to Process",
            request = "attach",
            processId = require("dap.utils").pick_process,
        },
    }
end

-- TODO: config: be able to change location of dotnet and netcoredbg executables
-- TODO: config: don't build when running tests ( --no-build )
-- TODO: config: if current file is not test, run the previous successful one

function M.setup(--[[ opts ]])
    local dap = require_module("dap")

    setup_adapter(dap)
    setup_configuration(dap)
end

vim.keymap.set("n", "<Leader>ds", function()
    require("dap").continue()
end, { silent = true })

vim.keymap.set("n", "<Leader>db", function()
    require("dap").toggle_breakpoint()
end, { silent = true })

return M
