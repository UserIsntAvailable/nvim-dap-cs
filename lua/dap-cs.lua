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

-- ((method_declaration
--   name: (identifier) @method-name
--   body: (_)) @scope-root)

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
        return { error = "dap-cs: debug session canceled" }
    end

    return selection
end

-- Captures info indicating in what object scope we currently are
-- @return The fully qualified name of { class_name | method_name } | nil
local function get_current_cursor_test_scope()
    local ft = vim.api.nvim_buf_get_option(0, "filetype")
    if ft ~= "cs" then
        return { error = "dap-cs: can only debug cs files, not " .. ft }
    end

    local cs_query = vim.treesitter.parse_query(ts_parsers.ft_to_lang(ft), test_query)
    local node = ts_utils.get_node_at_cursor()

    local method_identifier
    while node do
        local iter = cs_query:iter_captures(node, 0)
        local capture_ID, capture_node = iter()

        if capture_node == node then
            if cs_query.captures[capture_ID] == "method-root" then
                while cs_query.captures[capture_ID] ~= "method-name" do
                    capture_ID, capture_node = iter()
                end

                method_identifier = query.get_node_text(capture_node, 0)
            end

            if cs_query.captures[capture_ID] == "class-root" then
                while capture_node == node do
                    capture_ID, capture_node = iter()
                end

                local class_identifier = query.get_node_text(capture_node, 0)

                -- stylua: ignore
                return method_identifier
                    and string.format("%s.%s", class_identifier, method_identifier)
                    or class_identifier
                -- stylua: end
            end
        end

        node = node:parent()
    end

    return { error = "dap-cs: non-valid test scope found" }
end

local function setup_adapter(dap)
    -- TODO: Remote dap server
    dap.adapters.coreclr = {
        type = "executable",
        command = "netcoredbg",
        args = { "--interpreter=vscode" },
        enrich_config = function(config, on_config)
            local error = config.program.error or config.dotnet_extra_args.error or nil

            if error then
                return vim.notify(error, vim.log.levels.ERROR)
            end

            if config.request == "attach" and not config.processId then
                local args = config.dotnet_extra_args or {}
                table.insert(args, get_current_project_path())
                config.processId = utils.launch_dotnet({ args = args })
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
        },
        {
            type = "coreclr",
            name = "Debug Test",
            request = "attach",
            dotnet_extra_args = function()
                local test_filter = get_current_cursor_test_scope()

                if test_filter.error then
                    return test_filter.error
                end

                return { "--filter", string.format("FullyQualifiedName=%s", test_filter) }
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

return M
