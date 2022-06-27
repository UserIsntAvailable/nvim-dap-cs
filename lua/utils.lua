local M = {}

function M.require_module(module_name)
    local status_ok, module = pcall(require, module_name)
    assert(status_ok, string.format("dap-cs: '%s' plugin dependency is missing", module_name))
    return module
end

function M.require_executables(executables)
    for _, executable in ipairs(executables) do
        assert(
            vim.fn.executable(executable) == 1 and true or false,
            string.format("dap-cs: '%s' executable dependency is missing", executable)
        )
    end
end

return M
