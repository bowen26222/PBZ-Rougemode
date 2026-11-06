local source = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local mod_directory = assert(source:match('^(.*)/Scripts/main%.lua$'), 'Mod must be installed under Scripts/main.lua')
-- The supported build verifies both raw and CommonJS-wrapped scripts before
-- evaluating them. Adapt only this bundle's pinned records before JS startup.
local adapter_path = mod_directory .. '/ScriptIntegrity.dll'
local status_path = adapter_path .. '.status'
local apply_integrity, adapter_error = package.loadlib(adapter_path, 'pbz_apply_script_integrity')
assert(apply_integrity, 'Cannot load restricted script adapter: ' .. tostring(adapter_error))
local status_file = assert(io.open(status_path, 'wb'), 'Cannot reset script adapter status')
status_file:close()
apply_integrity()
status_file = assert(io.open(status_path, 'rb'), 'Script adapter status is missing')
local adapter_status = status_file:read('*a')
status_file:close()
os.remove(status_path)
assert(adapter_status:match('^ok[\r\n]*$'), 'Restricted script adapter refused: ' .. adapter_status)
print('[PBZRogue] Restricted script integrity adapter ready (15 pinned scripts).\n')
local MenuEntry = require('MenuEntry')
local Native = require('Native')
local Locale = require('Locale')
local Run = require('Run')
local Gm = require('Gm')
local launcher = mod_directory .. '/StartIsolatedGame.ps1'
local pending, run, isolated
local failed_menu, launch_serial = nil, 0
local auto_enter = true

local function quoted_path(path)
    assert(not path:find('[%z\r\n"&|<>^%%!]'), 'Unsupported shell character in installation path')
    return '"' .. path:gsub('/', '\\') .. '"'
end

local function show_error(button, message)
    print('[PBZRogue] Mode entry refused: ' .. tostring(message) .. '\n')
    if Native.valid(button) then
        button:SetButtonText(Native.text(Locale.text('无尽修炼：启动失败（查看 UE4SS 日志）', 'Endless Trials: launch failed (see UE4SS log)')))
        button:SetIsEnabled(true)
    end
end

local function launch_isolated(context, button)
    if pending then return end
    local project = Native.name(Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):GetProjectDirectory()):gsub('\\', '/')
    local game_root = assert(project:match('^(.*)/ProjectPBZ/$'), 'Unexpected native project directory')
    local file = assert(io.open(launcher, 'rb'), 'Isolated launcher is missing')
    file:close()
    launch_serial = launch_serial + 1
    local status_path = mod_directory .. '/launch-status-' .. os.time() .. '-' .. launch_serial .. '.txt'
    local command = 'start "" /b powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File '
        .. quoted_path(launcher) .. ' -GameRoot ' .. quoted_path(game_root)
        .. ' -WaitForGameExit -ReadyFile ' .. quoted_path(status_path)
        .. ' -Language ' .. Locale.language()
    local ok, _, code = os.execute(command)
    assert(ok and (code == nil or code == 0), 'Failed to start isolated-profile preparation')
    pending = {context = context, button = button, started = os.time(), status_path = status_path}
    if Native.valid(button) then
        button:SetIsEnabled(false)
        button:SetButtonText(Native.text(Locale.text('无尽修炼：准备重启游戏（独立存档）…', 'Endless Trials: preparing to restart (isolated save)...')))
    end
end

local function cancel_pending(message)
    local file = assert(io.open(pending.status_path .. '.cancel', 'wb'), 'Cannot cancel pending launcher')
    file:write('cancelled'); file:close()
    show_error(pending.button, message)
    pending = nil
end

local function update_pending()
    local file = io.open(pending.status_path, 'rb')
    if file then
        local state, detail = file:read('*l'), file:read('*a')
        file:close()
        if state == 'ready' then
            if not Native.valid(pending.context) then cancel_pending('World changed before profile switch'); return end
            if not pending.quitting then
                pending.quitting = true
                print('[PBZRogue] Isolated profile prepared: ' .. detail .. '\n')
                Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):QuitGame(
                    pending.context, Native.controller(pending.context), 0, false)
            end
            return
        elseif state == 'error' then
            show_error(pending.button, detail)
            pending = nil
            return
        end
    end
    if os.time() - pending.started > 30 then cancel_pending('Independent launcher readiness timed out') end
end

-- Keep Lua execution on the game thread. The pinned loader does not serialize
-- async enqueueing against execution of callbacks on its shared hook Lua state.
LoopInGameThreadWithDelay(250, function()
    if pending then
        local ok, message = pcall(update_pending)
        if not ok then show_error(pending and pending.button, message) end
        return
    end
    local dispatched, result = xpcall(MenuEntry.dispatch_pending, debug.traceback)
    if not dispatched then show_error(nil, result); return end
    if result then return end
    if isolated == nil then isolated = Run.is_isolated_process() end
    local menu = FindFirstOf('WB_StartMenu_V2_C')
    if isolated and run and run.returned_to_menu then
        local ok, message = xpcall(function() run:tick(run.instance) end, debug.traceback)
        if not ok then run:fail(message) end
    end
    if isolated and run and run.phase ~= 'menu' then
        local gm_ok, gm_message = pcall(Gm.tick, run)
        if not gm_ok then print('[PBZRogue] GM bridge error: ' .. tostring(gm_message) .. '\n') end
    end
    if isolated and run and run.phase ~= 'menu' then
        local context = run.instance or (Native.valid(menu) and menu) or FindFirstOf('PBZGameInstance')
        local ok, message = xpcall(function() run:tick(context) end, debug.traceback)
        if not ok then
            local displayed, display_error = pcall(run.fail, run, message)
            if not displayed then print('[PBZRogue] Failure display: ' .. tostring(display_error) .. '\n') end
        end
        return
    end
    if not Native.valid(menu) or not menu:IsActivated() then return end
    if failed_menu == menu:GetAddress() then return end
    local ok, message = pcall(function()
        if isolated then
            run = run or Run.new(mod_directory)
            local button
            button = MenuEntry.install(menu, function(active_menu)
                if run.phase ~= 'menu' then return end
                local entered, message = pcall(run.returned_to_menu and run.resume_from_menu or run.begin, run, active_menu)
                if not entered then show_error(button, message) end
            end)
            if run.phase == 'menu' then
                local resume = run.returned_to_menu and run.saves:has_checkpoint()
                    or (not run.returned_to_menu and require('RunSave').is_resume())
                button:SetButtonText(Native.text(resume and Locale.text('无尽修炼 · 继续独立存档', 'Endless Trials · Resume Isolated Save') or Locale.text('无尽修炼 · 独立新局', 'Endless Trials · New Isolated Run')))
                if auto_enter then
                    auto_enter = false
                    run:begin(menu)
                end
            end
        else
            local button
            button = MenuEntry.install(menu, function(active_menu)
                local entered, error_message = pcall(function()
                    launch_isolated(active_menu, button)
                end)
                if not entered then show_error(button, error_message) end
            end)
        end
    end)
    if not ok then
        failed_menu = menu:GetAddress()
        show_error(nil, message)
        if run then pcall(run.fail, run, message) end
    end
end)
