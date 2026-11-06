local Native = require('Native')
local Locale = require('Locale')
local RestPoint = {}
RestPoint.__index = RestPoint

local bell_class = '/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C'
local prefix = 'PBZRogue.NativeBell'
local player_tag = prefix .. 'Player'
local events = {'Interacting', 'Entered', 'Closed', 'Shop', 'Skills', 'Next', 'Restart', 'MenuReady', 'Error'}

local function has_tag(actor, tag)
    return Native.valid(actor) and actor:ActorHasTag(FName(tag))
end

local function set_tag(actor, tag, enabled)
    if not Native.valid(actor) or has_tag(actor, tag) == enabled then return end
    local tags = {}
    for _, value in ipairs(Native.array(actor.Tags)) do
        if Native.name(value) ~= tag then tags[#tags + 1] = value end
    end
    if enabled then tags[#tags + 1] = FName(tag) end
    actor.Tags = tags
end

local function menu_belongs_to(page, actor)
    -- UBellInteractWidget.OwnerBell is TWeakObjectPtr<APBZCheckPoint>.
    -- UE4SS exposes FWeakObjectPtr here, not a UObject with IsValid().
    return Native.valid(page) and Native.same(page.OwnerBell:Get(), actor)
end

local function destroy_after_error(self, message)
    local ok, cleanup_error = pcall(self.destroy, self)
    if not ok then message = message .. Locale.text('\n铃铛清理失败: ', '\nBell cleanup failed: ') .. tostring(cleanup_error) end
    return message
end

function RestPoint.new(player, controller, origin, callbacks)
    assert(Native.valid(player) and Native.valid(controller), Locale.text('铃铛需要有效玩家和控制器', 'The bell requires a valid player and controller'))
    assert(type(callbacks) == 'table', Locale.text('铃铛需要原生菜单回调', 'The bell requires native menu callbacks'))
    for _, name in ipairs({'entered', 'closed', 'shop', 'skills', 'next', 'restart', 'error', 'can_interact'}) do
        assert(type(callbacks[name]) == 'function', Locale.text('铃铛缺少回调: ', 'Missing bell callback: ') .. name)
    end
    return setmetatable({player = player, controller = controller, callbacks = callbacks,
        origin = {X = origin.X, Y = origin.Y, Z = origin.Z}}, RestPoint)
end

function RestPoint:_take(event)
    local tag = prefix .. event
    if not has_tag(self.actor, tag) then return false end
    set_tag(self.actor, tag, false)
    return true
end

function RestPoint:_clear_events()
    for _, event in ipairs(events) do set_tag(self.actor, prefix .. event, false) end
end

function RestPoint:_time()
    return self.gameplay:GetRealTimeSeconds(self.player)
end

function RestPoint:spawn()
    assert(not Native.valid(self.actor), Locale.text('楼层铃铛已经存在', 'A bell already exists on this floor'))
    assert(not has_tag(self.player, player_tag), Locale.text('原生铃铛玩家标记未清除', 'The native bell player tag was not cleared'))
    self.gameplay = Native.cdo('/Script/Engine.Default__GameplayStatics')
    self.ui_library = Native.cdo('/Script/CommonGame.Default__CommonUIExtensions')
    self.interact = Native.cdo('/Script/ProjectPBZ.Default__PBZInteractComponent'):GetInteractComponent(self.player)
    assert(Native.valid(self.interact), Locale.text('原生玩家交互组件不可用', 'The native player interaction component is unavailable'))
    local hit, origin = {}, self.origin
    local color = {R = 0, G = 0, B = 0, A = 0}
    local found = Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):LineTraceSingle(self.player,
        {X = origin.X, Y = origin.Y, Z = origin.Z + 400},
        {X = origin.X, Y = origin.Y, Z = origin.Z - 2000}, 0, false, {self.player}, 0, hit, true, color, color, 0)
    assert(found and hit.bBlockingHit, Locale.text('中央铃铛没有找到实际地面', 'No solid ground was found for the central bell'))
    self.location = {X = hit.ImpactPoint.X, Y = hit.ImpactPoint.Y, Z = hit.ImpactPoint.Z + 2}
    local transform = {Translation = self.location, Rotation = {X = 0, Y = 0, Z = 0, W = 1},
        Scale3D = {X = 1, Y = 1, Z = 1}}
    local spawn = Native.cdo('/Script/SGameAI.Default__SGameAIFunctionLibrary')
    self.actor = spawn:SpawnActorDeferred(self.player, Native.load_class(bell_class), transform, 2)
    assert(Native.valid(self.actor), Locale.text('中央原生铃铛创建失败', 'Failed to create the central native bell'))
    local ok, message = xpcall(function()
        set_tag(self.player, player_tag, true)
        self.owns_scope = true
        set_tag(self.actor, prefix, true)
        -- Configure before BeginPlay: this bell is already active. The scoped
        -- native mixin bypasses story rest/save, not component lifecycle.
        self.actor.bActive = true
        self.actor.BellID = FName('None')
        self.actor.bDisableTeleport = true
        self.actor.bTeleportOnBrokenBellLeave = false
        self.actor.IsFirstSave = false
        self.actor.GameplayEffect = {}
        self.actor.SaveSlotNameArray = {}
        -- Keep PBZSaveComponent alive until native actor teardown completes.
        -- AMelodiousBell::EndPlay calls GetSaveActorID; with BellID=None it
        -- dereferences this component without a null check.
        spawn:FinishActorSpawning(self.actor, transform)
        assert(has_tag(self.actor, prefix .. 'Ready') and not has_tag(self.actor, prefix .. 'Error'),
            Locale.text('原生铃铛补丁未生效；需要完整安装同名 .pak/.utoc/.ucas 并在下次启动游戏时加载', 'The native bell patch is not active. Install the complete matching .pak/.utoc/.ucas files and restart the game to load them.'))
        self.actor:SetActorHiddenInGame(false)
        set_tag(self.actor, prefix .. 'Allowed', self.callbacks.can_interact() == true)
    end, debug.traceback)
    if not ok then error(destroy_after_error(self, message), 0) end
    return self.actor
end

function RestPoint:_find_menu()
    if not Native.valid(self.actor) then return end
    if menu_belongs_to(self.page, self.actor) then return self.page end
    for _, page in ipairs(FindAllOf('W_BellMenu_C') or {}) do
        if menu_belongs_to(page, self.actor) and page:IsActivated() then
            self.page = page
            return page
        end
    end
end

function RestPoint:open_menu()
    assert(Native.valid(self.actor) and has_tag(self.actor, prefix .. 'Ready'), Locale.text('原生铃铛已失效', 'The native bell is no longer valid'))
    assert(self.callbacks.can_interact(), Locale.text('检查点保存期间不能打开铃铛菜单', 'The bell menu cannot be opened while a checkpoint is being saved'))
    assert(not self.menu_open and not self.open_started, Locale.text('原生铃铛菜单已经打开或正在打开', 'The native bell menu is already open or opening'))
    self:_clear_events()
    set_tag(self.actor, prefix .. 'Allowed', true)
    self.open_started, self.reopening = self:_time(), true
    -- The scoped RefreshBell mixin pushes W_BellMenu with OwnerBell assigned
    -- before native activation; it does not repeat the rest/interaction ability.
    set_tag(self.actor, prefix .. 'Reopen', true)
    self.actor:RefreshBell()
    set_tag(self.actor, prefix .. 'Reopen', false)
end

function RestPoint:close_menu()
    self.menu_open, self.open_started = false, nil
    local reopening = self.reopening
    self.reopening = nil
    if reopening and Native.valid(self.actor) then self.actor:EndSwitchInteract() end
    set_tag(self.actor, prefix .. 'Allowed', false)
    local page = self:_find_menu()
    self.page = nil
    if Native.valid(page) then
        page:DeactivateWidget()
        self.ui_library:PopContentFromLayer(page)
    end
    self:_clear_events()
end

function RestPoint:_tick()
    if not Native.valid(self.actor) then return end
    set_tag(self.actor, prefix .. 'Allowed', self.callbacks.can_interact() == true)
    if self:_take('Error') then error(Locale.text('原生铃铛交互或菜单初始化失败，请查看游戏脚本日志', 'Native bell interaction or menu initialization failed. See the game script log.')) end
    if self:_take('Interacting') then self.open_started = self:_time() end
    if self:_take('Closed') then
        local was_open = self.menu_open or self.open_started ~= nil
        self.menu_open, self.open_started, self.page, self.reopening = false, nil, nil, nil
        self:_clear_events()
        if was_open then self.callbacks.closed() end
        return
    end
    if self:_take('Entered') then
        assert(has_tag(self.actor, prefix .. 'MenuReady'), Locale.text('原生铃铛菜单策略未生效', 'The native bell menu policy is not active'))
        assert(Native.valid(self:_find_menu()), Locale.text('原生铃铛菜单实例不可用', 'The native bell menu instance is unavailable'))
        self.open_started, self.menu_open, self.reopening = nil, true, nil
        self.callbacks.entered()
    end
    if self.open_started and self:_time() - self.open_started > 10 then
        error(Locale.text('原生铃铛菜单未能在 10 秒内打开', 'The native bell menu did not open within 10 seconds'))
    end
    if self.menu_open then
        for _, action in ipairs({{'Shop', 'shop'}, {'Skills', 'skills'}, {'Next', 'next'}, {'Restart', 'restart'}}) do
            if self:_take(action[1]) then
                if self.callbacks.can_interact() then self.callbacks[action[2]]() end
                break
            end
        end
    end
end

function RestPoint:tick()
    local ok, message = xpcall(function() self:_tick() end, debug.traceback)
    if not ok then
        self.callbacks.error(destroy_after_error(self, message))
    end
end

function RestPoint:destroy()
    if self.destroying then return end
    self.destroying = true
    local errors = {}
    local function cleanup(action)
        local ok, message = xpcall(action, debug.traceback)
        if not ok then errors[#errors + 1] = message end
    end
    cleanup(function() self:close_menu() end)
    cleanup(function()
        -- Native deactivation normally does this itself; cover cancellation
        -- during the approach/montage too, without ending another interaction.
        if Native.valid(self.actor) and Native.valid(self.interact)
            and Native.same(self.interact.InteractingActor, self.actor) then
            self.actor:EndSwitchInteract()
        end
    end)
    cleanup(function()
        if Native.valid(self.actor) then self.actor:K2_DestroyActor() end
    end)
    cleanup(function()
        if self.owns_scope then set_tag(self.player, player_tag, false) end
    end)
    self.owns_scope, self.actor, self.location, self.page, self.destroying = nil, nil, nil, nil, nil
    if #errors > 0 then error(table.concat(errors, '\n'), 0) end
end

return RestPoint
