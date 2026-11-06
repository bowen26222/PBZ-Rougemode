local Native = require('Native')
local Locale = require('Locale')
local Json = require('Json')
local RunSave = {}
RunSave.__index = RunSave
local active, serial = nil, 0
local configNames = {'run', 'floors', 'enemy_pools', 'items', 'shop', 'economy'}
local requestPrefix, completePrefix = 'PBZRogue.SaveRequest.', 'PBZRogue.SaveComplete.'

local function command_line()
    return Native.name(Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):GetCommandLine())
end
local function option(command, key)
    return command:match('%-' .. key .. '="([^"]+)"') or command:match('%-' .. key .. '=([^%s]+)')
end
local function exists(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end
local function contents(path)
    local file = assert(io.open(path, 'rb'), 'Cannot read isolated checkpoint: ' .. path)
    local result = file:read('*a')
    file:close()
    return assert(result, 'Cannot read checkpoint bytes')
end
local function write_file(path, text)
    local file = assert(io.open(path, 'wb'), 'Cannot write isolated checkpoint: ' .. path)
    local ok, message = file:write(text)
    local closed, close_error = file:close()
    assert(ok and closed, message or close_error)
end
local function profile(run)
    local command = command_line()
    local user, saves = option(command, 'UserDir'), option(command, 'SaveGamesDir')
    assert(user and saves, 'Independent native namespace is required')
    user, saves = user:gsub('\\', '/'):gsub('/+$', ''), saves:gsub('\\', '/'):gsub('/+$', '')
    local root = assert(os.getenv('LOCALAPPDATA')):gsub('\\', '/'):lower() .. '/pbzrogue/runs/'
    assert(user:lower():sub(1, #root) == root and saves:lower() == user:lower() .. '/nativesavegames',
        'Checkpoint path is outside the isolated run namespace')
    for segment in user:gmatch('[^/]+') do
        assert(segment ~= '.' and segment ~= '..', 'Checkpoint profile must use a canonical path')
    end
    assert(run.profile and run.profile:lower() == user:lower(), 'Run profile disagrees with verified native namespace')
    return user
end
local function integer(value, minimum, maximum)
    return type(value) == 'number' and value % 1 == 0 and value >= minimum and value <= maximum
end

function RunSave.is_resume()
    return command_line():match('%-PBZRogueResume%s') ~= nil or command_line():match('%-PBZRogueResume$') ~= nil
end

function RunSave.new(run)
    local config = {}
    for _, name in ipairs(configNames) do config[name] = contents(run.directory .. '/config/' .. name .. '.json') end
    local worker = option(command_line(), 'PBZRogueWorker')
    assert(worker and #worker == 32 and worker:match('^[0-9a-f]+$'),
        Locale.text('隐藏保存进程未配置，请通过无尽修炼入口启动', 'The background save worker is not configured. Launch through the Endless Trials entry.'))
    return setmetatable({run = run, profile = profile(run), config = config, worker = worker}, RunSave)
end

function RunSave:is_busy() return self.pending ~= nil or self.native_pending == true or self.operation ~= nil end

function RunSave:has_checkpoint()
    return not exists(self.profile .. '/run-dead') and exists(self.profile .. '/checkpoint.json')
end

function RunSave:_operate(operation, checkpoint)
    assert(not self.operation, 'Another profile operation is still pending')
    serial = serial + 1
    local id = tostring(os.time()) .. '-' .. serial
    local resultPath = self.profile .. '/operation-' .. id .. '.json'
    while exists(resultPath) or exists(self.profile .. '/operation-' .. id .. '.cancel')
        or exists(self.profile .. '/operation-' .. id .. '.request.json') do
        serial = serial + 1
        id = tostring(os.time()) .. '-' .. serial
        resultPath = self.profile .. '/operation-' .. id .. '.json'
    end
    local ready = Json.decode(contents(self.profile .. '/save-worker-' .. self.worker .. '.ready'))
    assert(ready.schema == 1 and ready.worker == self.worker, Locale.text('隐藏保存进程未就绪', 'The background save worker is not ready'))
    local requestPath = self.profile .. '/operation-' .. id .. '.request.json'
    local job = {id = id, kind = operation, checkpoint = checkpoint, result = resultPath,
        request = requestPath, started = os.time()}
    local request = {schema = 1, worker = self.worker, id = id, operation = operation, checkpoint = checkpoint}
    local state = checkpoint and assert(self.pending.state, 'Missing checkpoint snapshot') or nil
    local pendingPath = checkpoint and (self.profile .. '/pending-' .. checkpoint .. '.json') or nil
    self.operation = job
    -- Publish only the small request/snapshot here; the existing worker still
    -- performs the native-save copying. Async Lua shares this VM and can race
    -- with the game-thread callbacks even when it only handles plain data.
    local ok, message = pcall(function()
        if state then write_file(pendingPath, Json.encode(state)) end
        local temporary = requestPath .. '.tmp'
        write_file(temporary, Json.encode(request))
        assert(os.rename(temporary, requestPath), 'Cannot publish background save request')
    end)
    if not ok then job.dispatch_error = tostring(message) end
end

function RunSave:retire()
    assert(not self:is_busy() and not active, 'Cannot retire a run while a native save is busy')
    assert(self.profile == profile(self.run), 'Cannot retire an unverified run profile')
    self:tick()
    assert(self.discarded and exists(self.profile .. '/run-dead'), 'Dead run payload has not been removed')
    assert(os.remove(self.profile .. '/run-dead'))
    self.saved, self.on_completed = nil, nil
end

function RunSave:read()
    assert(not exists(self.profile .. '/run-dead'), 'This run ended; its checkpoint cannot be resumed')
    local pointer = Json.decode(contents(self.profile .. '/checkpoint.json'))
    assert(pointer.schema == 1 and type(pointer.id) == 'string' and pointer.id:match('^%d+%-%d+$'), 'Invalid checkpoint pointer')
    local directory = self.profile .. '/Checkpoints/' .. pointer.id
    local complete = Json.decode(contents(directory .. '/complete.json'))
    assert(complete.schema == 1 and complete.id == pointer.id, 'Checkpoint did not complete')
    local saved = Json.decode(contents(directory .. '/state.json'))
    assert(saved.schema == 1 and saved.checkpoint == pointer.id and integer(saved.wave, 1, 3)
        and integer(saved.floor, 1, 2147483646), 'Invalid wave checkpoint')
    assert(type(saved.nativeSlot) == 'string' and saved.nativeSlot:match('^ManualSave%d+$'), 'Invalid native checkpoint slot')
    assert(integer(saved.seed, 0, 9007199254740991) and integer(saved.combat_rng, 1, 2147483646)
        and integer(saved.shop_rng, 1, 2147483646), 'Invalid saved RNG state')
    assert(saved.equipment.floor == saved.floor and saved.equipment.wave == saved.wave
        and type(saved.equipment.sections) == 'table' and (saved.wave ~= 1 or #saved.equipment.sections == 0)
        and type(saved.progression) == 'table', 'Incomplete run snapshot')
    for _, name in ipairs(configNames) do
        assert(saved.config[name] == contents(self.run.directory .. '/config/' .. name .. '.json'), 'Run configuration changed since checkpoint: ' .. name)
    end
    local container = complete.nativeContainer
    assert(type(container) == 'string' and container:match('^NativeSaveGames/[%w_/-]+/PBZSaveGame%.sav$')
        and not container:find('..', 1, true) and exists(self.profile .. '/' .. container),
        'Native checkpoint container is missing from the isolated profile')
    self.saved = saved
    return saved
end

function RunSave:load_native(instance)
    local saved = self.saved or self:read()
    assert(self.run.resume_requested, 'Native run load requires explicit resume launch')
    local loaded = {}
    instance:LoadGame(saved.nativeSlot, loaded)
    assert(loaded.ResultType == 0, 'Native isolated checkpoint load failed')
    assert(Native.name(loaded.LevelName) == self.run.config.floors.arena.map
        or Native.name(loaded.LevelName) == self.run.config.floors.arena.map:match('([^/]+)$'), 'Native checkpoint targets a different map')
    -- Native StartMenu.js explicitly travels after GameInstance.LoadGame returns;
    -- using the saved GameModeOptions is required for the native load-game path.
    Native.cdo('/Script/Engine.Default__GameplayStatics'):OpenLevel(instance, FName(Native.name(loaded.LevelName)),
        true, Native.name(loaded.GameModeOptions))
    return loaded
end

function RunSave:restore()
    local run, saved = self.run, assert(self.saved, 'No native checkpoint has been loaded')
    run.progression:restore(saved.progression)
    run.equipment:restore(saved.equipment)
    run.seed, run.floor, run.wave = saved.seed, saved.floor, saved.wave
    run.combat_rng.state, run.shop_rng.state = saved.combat_rng, saved.shop_rng
    return saved
end

function RunSave:_complete(ok, message)
    self.pending = nil
    if active == self and not self.native_pending and not self.operation then active = nil end
    self.last_ok, self.last_message = ok, message
    if self.on_completed then self.on_completed(ok, message) end
end

local function save_tags(player, slot)
    local tags = {}
    for _, tag in ipairs(Native.array(player.Tags)) do
        local name = Native.name(tag)
        if name:sub(1, #requestPrefix) ~= requestPrefix and name:sub(1, #completePrefix) ~= completePrefix then
            tags[#tags + 1] = tag
        end
    end
    if slot then tags[#tags + 1] = FName(requestPrefix .. slot) end
    player.Tags = tags
end
function RunSave:detach()
    self.detached = true
    self.on_completed = nil
end


function RunSave:_receive_completion()
    if self.detached or not self.native_pending or not Native.valid(self.run.player)
        or not self.run.player:ActorHasTag(FName(completePrefix .. self.native_slot)) then return end
    save_tags(self.run.player)
    self.native_pending = false
    if self.pending then
        self.pending.finished = true
    elseif active == self then
        active = nil
    end
end

-- The native JS save-start listener invokes this side-effect-free receiver.
-- Both native and custom state are sampled on the game thread, not when the
-- request is queued or when disk I/O finishes. No world pause is needed.
RegisterHook('/Script/ProjectPBZ.PBZSaveLoadSubsystem:RecordFiredDelegateForTest', function(context, slot)
    local save = active
    if save and save.native_pending
        and Native.same(context:get(), save.subsystem)
        and Native.name(slot:get()) == 'PBZRogue.SaveDetachedComplete.' .. save.native_slot then
        save.native_pending = false
        save:detach()
        if save.pending then save.pending.finished = true
        elseif not save.operation then active = nil end
        return
    end
    if not save or not save.pending or not save.native_pending
        or not Native.same(context:get(), save.subsystem) or Native.name(slot:get()) ~= save.native_slot then return end
    local pending, run = save.pending, save.run
    if run.phase ~= 'checkpoint' or exists(save.profile .. '/run-dead') then return end
    local ok, result = pcall(function()
        local state = {schema = 1, checkpoint = pending.id, nativeSlot = save.native_slot,
            seed = run.seed, floor = run.floor, wave = run.wave, combat_rng = run.combat_rng.state,
            shop_rng = run.shop_rng.state, equipment = run.equipment:snapshot(), progression = run.progression:snapshot(),
            config = save.config}
        return state
    end)
    pending.state = ok and result or nil
    pending.capture_error = not ok and tostring(result) or nil
end)

function RunSave:_poll_operation()
    local operation = self.operation
    if not operation then return end
    if operation.dispatch_error then
        self.operation = nil
        if active == self and not self.native_pending then active = nil end
        if operation.kind == 'Discard' then
            self.discard_error = operation.dispatch_error
            self.run:fail(Locale.text('无法启动独立存档后台清理：', 'Could not start background cleanup of the isolated save: ') .. self.discard_error)
        else
            self:_complete(false, operation.dispatch_error)
        end
        return
    end
    -- The worker removes its request after inspecting the child's receipt.
    -- Do not consume that receipt early and race its completion check.
    if not exists(operation.result) or exists(operation.request) then
        if not operation.timed_out and os.time() - operation.started > 120 then
            operation.timed_out = true
            write_file(self.profile .. '/operation-' .. operation.id .. '.cancel', 'timeout')
            if operation.kind == 'Checkpoint' then
                self:_complete(false, Locale.text('后台检查点处理超时；已请求取消，等待后台最终回执', 'Background checkpoint processing timed out. Cancellation requested; waiting for the final acknowledgement.'))
            else
                self.run:fail(Locale.text('后台删档超时；仍在等待文件操作结束，禁止重开本局', 'Background save deletion timed out. Restart is blocked until file operations finish.'))
            end
        end
        return
    end
    local result = Json.decode(contents(operation.result))
    assert(result.schema == 1 and result.id == operation.id and result.operation == operation.kind
        and (operation.kind ~= 'Checkpoint' or result.checkpoint == operation.checkpoint)
        and type(result.success) == 'boolean', 'Background save receipt does not match its request')
    self.operation = nil
    if active == self and not self.native_pending then active = nil end
    os.remove(operation.result)
    os.remove(self.profile .. '/operation-' .. operation.id .. '.cancel')
    if operation.kind == 'Discard' then
        self.discarded = result.success
        if not result.success then
            self.discard_error = tostring(result.error)
            self.run:fail(Locale.text('独立存档后台清理失败：', 'Background cleanup of the isolated save failed: ') .. self.discard_error)
        end
        return
    end
    if exists(self.profile .. '/run-dead') then return end
    local pending = self.pending
    if not pending or operation.timed_out then return end
    local ok, message = pcall(function()
        assert(result.success, tostring(result.error or Locale.text('后台检查点写入失败', 'Background checkpoint write failed')))
        local pointer = Json.decode(contents(self.profile .. '/checkpoint.json'))
        assert(pointer.id == pending.id and pending.id == operation.checkpoint,
            'Checkpoint commit did not publish the requested generation')
        self.saved = pending.state
    end)
    self:_complete(ok, ok and Locale.text('本波已自动保存；下次进入无尽修炼将自动续局', 'Wave autosaved. Your run will resume automatically the next time you enter Endless Trials.') or tostring(message))
end

function RunSave:save()
    if self:is_busy() then return false, Locale.text('存档正在写入，请稍候', 'Writing save. Please wait.') end
    local run = self.run
    if not integer(run.wave, 1, 3) or run.phase ~= 'checkpoint' then
        return false, Locale.text('仅在每波战斗结束后自动保存', 'Autosaving is only available after each combat wave')
    end
    if exists(self.profile .. '/run-dead') then return false, Locale.text('本局已结束，不能续存', 'This run has ended and cannot be saved for continuation') end
    local ok, message = pcall(function()
        assert(not active, 'Another native checkpoint is still pending')
        assert(run.player:ActorHasTag(FName('PBZRogue.SaveBridgeReady2')),
            Locale.text('原生保存回执补丁未加载；未提交自动保存', 'The native save acknowledgement patch is not loaded; autosave was not submitted'))
        serial = serial + 1
        local stamp = os.time()
        local id = tostring(stamp) .. '-' .. serial
        while exists(self.profile .. '/Checkpoints/' .. id .. '/complete.json')
            or exists(self.profile .. '/pending-' .. id .. '.json') do
            serial = serial + 1
            id = tostring(stamp) .. '-' .. serial
        end
        self.subsystem = Native.subsystem(run.player, '/Script/ProjectPBZ.PBZSaveLoadSubsystem')
        local maximum = 0
        local summaries = self.subsystem:GetManualSaveSummariesSorted()
        for _, entry in ipairs(Native.array(summaries)) do
            local number = tonumber(Native.name(entry.SlotName):match('^ManualSave(%d+)$'))
            if number then maximum = math.max(maximum, number) end
        end
        assert(maximum < 2147483647, 'Native manual save slot index exhausted')
        local nativeSlot = 'ManualSave' .. (maximum + 1)
        assert(type(run.spawn_transform) == 'table' and type(run.spawn_transform.Translation) == 'table'
            and type(run.spawn_transform.Rotation) == 'table' and type(run.spawn_transform.Scale3D) == 'table',
            'Native save transform must contain plain Lua values, not reflected userdata')
        self.pending = {id = id, nativeSlot = nativeSlot, started = os.time()}
        self.native_pending, self.native_slot = true, nativeSlot
        active = self
        save_tags(run.player, nativeSlot)
        -- UE4SS cannot marshal a reflected Transform userdata nested inside this
        -- parameter table; keep the same plain-value transform used for InitDataPolicy.
        local result = self.subsystem:ForceSave(4, {bOverridePlayerCharacterTransform = true,
            OverridePlayerCharacterSaveTransform = run.spawn_transform,
            bIsRevive = false, SaveSlotName = nativeSlot, bIsOverrideLevelName = true,
            NewLevelName = FName(run.config.floors.arena.map), bSaveAdvanced = true,
            BellID = FName('None'), DisplayBellID = FName('None'), bShowSaveTip = false, IoContext = 0, Reason = 4},
            nil)
        if result ~= 0 and result ~= 1 then
            self.native_pending, active = false, nil
            save_tags(run.player)
            error(Locale.text('原生存档请求被拒绝，结果码：', 'Native save request rejected. Result code: ') .. tostring(result))
        end
    end)
    if not ok then self:_complete(false, tostring(message)); return false, tostring(message) end
    return true, Locale.text('正在写入原生存档与独立检查点，请勿关闭游戏', 'Writing the native save and isolated checkpoint. Do not close the game.')
end

function RunSave:tick()
    self:_receive_completion()
    self:_poll_operation()
    if exists(self.profile .. '/run-dead') then
        if self.native_pending or self.operation or self.discarded or self.discard_error then return end
        self.pending, self.saved = nil, nil
        if active == self then active = nil end
        local ok, message = pcall(self._operate, self, 'Discard')
        if not ok then
            self.discard_error = tostring(message)
            self.run:fail(Locale.text('无法启动独立存档后台清理：', 'Could not start background cleanup of the isolated save: ') .. self.discard_error)
        end
        return
    end
    local pending = self.pending
    if not pending or self.operation then return end
    if not pending.finished then
        if os.time() - pending.started > 60 then self:_complete(false, Locale.text('未收到原生磁盘存档完成回执；未标记为可继续', 'No native disk-save completion acknowledgement received; the run was not marked resumable')) end
        return
    end
    local ok, message = pcall(function()
        assert(pending.state, pending.capture_error or Locale.text('未收到原生采样回执；保留上次完整存档', 'No native snapshot acknowledgement received; the previous complete save has been retained'))
        assert(self.run.floor == pending.state.floor and self.run.wave == pending.state.wave,
            'Run boundary changed while native save was pending')
        self:_operate('Checkpoint', pending.id)
    end)
    if not ok then self:_complete(false, tostring(message)) end
end

function RunSave:invalidate(reason)
    write_file(self.profile .. '/run-dead', tostring(reason or 'ended'))
    -- Never delete files underneath an in-flight native writer. Its completion
    -- event releases this gate; the launcher also removes any late writes.
    self:tick()
end

return RunSave
