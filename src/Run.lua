local Native = require('Native')
local Locale = require('Locale')
local Config = require('Config')
local Json = require('Json')
local Rng = require('Rng')
local Battle = require('Battle')
local ShopUI = require('ShopUI')
local Equipment = require('Equipment')
local RestPoint = require('RestPoint')
local Progression = require('Progression')
local RunSave = require('RunSave')
local ModeUI = require('ModeUI')
local Economy = require('Economy')
local Run = {}
Run.__index = Run
local restart_token = {}
local active_run

-- Invalidate before native death presentation starts its asynchronous UI load.
RegisterHook('/Script/ProjectPBZ.PBZSaveLoadSubsystem:RecordFiredDelegateForTest', function(_, slot)
    local player_path = Native.name(slot:get()):match('^PBZRogue%.Death|(.*)$')
    local run = active_run
    if not player_path or not run or not Native.valid(run.player) then return end
    local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
    if Native.name(system:GetPathName(run.player)) == player_path then run:begin_death() end
end)

-- Run cleanup must precede UEngine::LoadMap destroying its world. Initial
-- entry and explicit restarts already own their teardown and use 'loading'.
RegisterLoadMapPreHook(function()
    local run = active_run
    if run and run.phase ~= 'loading' and run.phase ~= 'menu' then run:leave_world() end
end)

local function normalized(path)
    return path:gsub('\\', '/'):gsub('/+$', ''):lower()
end

local function option(command, key)
    return command:match('%-' .. key .. '="([^"]+)"') or command:match('%-' .. key .. '=([^%s]+)')
end

function Run.is_isolated_process()
    local command = Native.name(Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):GetCommandLine())
    return command:find('%-PBZRogue%s') ~= nil or command:match('%-PBZRogue$') ~= nil
end

function Run.new(directory)
    return setmetatable({directory = directory, phase = 'menu', floor = 1, wave = 0,
        resume_requested = RunSave.is_resume()}, Run)
end

function Run:verify_isolation(menu, token)
    local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
    local command = Native.name(system:GetCommandLine())
    local user_dir, save_dir = option(command, 'UserDir'), option(command, 'SaveGamesDir')
    assert(user_dir and save_dir, 'Both independent save namespace arguments are required')
    assert(normalized(save_dir) == normalized(user_dir) .. '/nativesavegames', 'Save namespace arguments disagree')
    local local_app_data = assert(os.getenv('LOCALAPPDATA'), 'LOCALAPPDATA is unavailable')
    for segment in user_dir:gsub('\\', '/'):gmatch('[^/]+') do
        assert(segment ~= '.' and segment ~= '..', 'Independent profile must use a canonical path')
    end
    local root = normalized(local_app_data) .. '/pbzrogue/runs/'
    assert(normalized(user_dir):sub(1, #root) == root, 'Tower profile must be created by the independent launcher')
    local saved = normalized(Native.name(system:GetProjectSavedDirectory()))
    assert(saved:sub(1, #normalized(user_dir) + 1) == normalized(user_dir) .. '/', 'Native user directory isolation did not take effect')
    local saves = Native.subsystem(menu, '/Script/ProjectPBZ.PBZSaveLoadSubsystem')
    if token == restart_token then
        assert(self.profile and normalized(self.profile) == normalized(user_dir)
            and Native.same(self.instance, Native.cdo('/Script/Engine.Default__GameplayStatics'):GetGameInstance(menu)),
            'In-process restart must keep the verified profile and GameInstance')
    else
        local probe = option(command, 'PBZRogueProbe')
        local guid = probe and probe:match('^PBZRogueProbe_([0-9a-f]+)$')
        assert(guid and #guid == 32, 'Independent launcher namespace probe is missing')
        local gameplay = Native.cdo('/Script/Engine.Default__GameplayStatics')
        -- Ordinary slots are account-scoped; preferences and our marker live at the
        -- save root. The pinned backend appends slot + ".sav" without sanitizing
        -- relative components. Probe only the root, legacy account, and Steam/account
        -- layouts; never pass these relative names to a native write/delete API.
        local probe_slot
        for _, prefix in ipairs({'', '../', '../../'}) do
            local candidate = prefix .. probe
            if gameplay:DoesSaveGameExist(candidate, 0) then
                assert(not probe_slot, 'Native namespace probe resolved more than once')
                probe_slot = candidate
            end
        end
        assert(probe_slot and not gameplay:DoesSaveGameExist(probe_slot .. '_absent', 0),
            'Native save backend did not select the independent namespace')
        assert(os.remove(save_dir .. '/' .. probe .. '.sav'), 'Cannot remove native namespace probe')
        assert(not gameplay:DoesSaveGameExist(probe_slot, 0), 'Native save backend disagrees with the independent namespace')
        if not self.resume_requested then
            assert(not saves:HasAnyLoadableSave(), 'This profile already has progress; a new run requires a fresh profile')
        end
    end
    self.profile = user_dir:gsub('\\', '/'):gsub('/+$', '')
end

function Run:record()
    local file = assert(io.open(self.profile .. '/run-state.json', 'wb'), 'Cannot write independent run status')
    local data = {schema = 1, seed = self.seed, floor = self.floor, wave = self.wave, phase = self.phase,
        resumable = self.saves and self.saves:has_checkpoint() or false,
        error = self.failure, updated = os.time()}
    local encoded = Json.encode(data)
    local ok, message = file:write(encoded)
    file:close()
    assert(ok, message)
end

-- A checkpoint written under a different configuration can never be resumed. Treat
-- only that case as stale and start fresh; other failures stay fatal.
function Run:_load_resume()
    if not self.resume_requested then return end
    local ok, result = pcall(self.saves.read, self.saves)
    if ok then
        self.resume_checkpoint = result
        return
    end
    local reason = tostring(result)
    if not reason:find('configuration changed', 1, true) then error(result) end
    print('[PBZRogue] Checkpoint rejected after configuration change: ' .. reason .. '\n')
    self.saves:invalidate('configuration change: ' .. reason)
    self.resume_requested, self.resume_note = false, Locale.text('旧检查点与当前配置不一致，已作废并开始新局。', 'The previous checkpoint does not match the current configuration. It has been discarded and a new run started.')
end

function Run:begin(menu, token)
    assert(self.phase == 'menu', 'Run has already started')
    -- The start menu is destroyed by OpenLevel; drop the entry before that so the
    -- queued native action cannot retain an obsolete menu entry.
    pcall(function() require('MenuEntry').release() end)
    self:verify_isolation(menu, token)
    ModeUI.setup()
    Native.bind_lifetime(menu)
    self.config = Config.load(self.directory .. '/config')
    local arena = self.config.floors.arena
    local original = Native.load_object(arena.policy)
    local gameplay = Native.cdo('/Script/Engine.Default__GameplayStatics')
    local instance = gameplay:GetGameInstance(menu)
    self.instance = instance
    self.saves = RunSave.new(self)
    self:_load_resume()
    self.seed = self.resume_checkpoint and self.resume_checkpoint.seed or self.config.run.seed or os.time()
    self.combat_rng, self.shop_rng = Rng.new(self.seed), Rng.new(self.seed + 104729)
    self.saves.on_completed = function(ok, message)
        if self.phase ~= 'checkpoint' or self.quit_requested then return end
        if not ok then self:fail(message); return end
        self:after_checkpoint()
    end
    local policy = Native.retain(Native.construct('/Script/ProjectPBZ.InitDataPolicy', instance))
    policy.OwnerLevelName = FName(arena.map)
    local half_yaw = arena.camera.Yaw * math.pi / 360
    self.spawn_transform = {
        Translation = arena.center, Scale3D = {X = 1, Y = 1, Z = 1},
        Rotation = {X = 0, Y = 0, Z = math.sin(half_yaw), W = math.cos(half_yaw)}
    }
    policy.DefaultTransform = self.spawn_transform
    policy.CameraRotator = arena.camera
    policy.GameplayTagContainer = original.GameplayTagContainer
    -- Native scene/lighting layers are not inventory or metaprogression.
    policy.ShowLayer = original.ShowLayer
    policy.ActivateLayerAssets = Native.array(original.ActivateLayerAssets)
    policy.OpenLevelOption = original.OpenLevelOption
    local game_data = Native.load_object('/Game/PBZContent/Blueprint/DA_PBZGameDataPolicy.DA_PBZGameDataPolicy')
    game_data.NormalGamePolicy = policy
    instance.InitDataPolicy = policy
    instance.StartScripts = {}
    instance:EndTutorial()
    self.policy = policy
    self.phase, self.loading_started = 'loading', os.time()
    self:record()
    print(string.format('[PBZRogue] Starting isolated run, seed %d, arena %s\n', self.seed, arena.map))
    if self.resume_checkpoint then
        self.saves:load_native(instance)
        return
    end
    -- The original StartMenu.StartGame uses StartNewGame (ResetJsonObject) before
    -- OpenLevel; do not load a previous native slot when restarting in this GI.
    instance:StartNewGame()
    -- Native selector "nitian" is EDifficultMode.Hard (3), not NightMare.
    -- Match StartMenu: assign after StartNewGame resets the native save object.
    Native.subsystem(instance, '/Script/ProjectPBZ.PBZSaveLoadSubsystem'):SetSaveGameDifficultyMode(3)
    instance.InitDataPolicy = policy
    local options = Native.name(policy.OpenLevelOption)
    if options == 'None' then options = '' end
    if options ~= '' then options = options .. '?' end
    gameplay:OpenLevel(menu, FName(arena.map), true, options .. 'PBZRogue=1')
end

function Run:ready(player)
    self.departing_player = nil
    self.player = player
    active_run = self
    self.controller = Native.controller(player)
    assert(Native.valid(self.controller), 'Local player controller is unavailable')
    self.controller:SetControlRotation(self.config.floors.arena.camera)
    local backpack = Native.cdo('/Script/ProjectPBZ.Default__PBZBackPackSubsystem'):GetBackPackSubsytemByContextObject(player)
    assert(Native.valid(backpack), 'Native backpack is unavailable')
    ModeUI.cleanup(player)
    self.ui = ShopUI.new(self.controller, player)
    self.ui.on_error = function(message) self:fail(message) end
    self.battle = Battle.new(player, self.config, self.combat_rng, self.policy.DefaultTransform.Translation, self.seed)
    self.battle:clear_native_encounters()
    self.battle:preload()
    self.equipment = Equipment.new(backpack, player, self.config, self.shop_rng)
    self.progression = Progression.new(backpack, player, self.config)
    self.restpoint = RestPoint.new(player, self.controller, self.config.floors.arena.center, {
        can_interact = function()
            return (self.phase == 'rest' or self.phase == 'bell')
                and not self.restart_confirmation and not self.saves:is_busy()
        end,
        entered = function()
            assert(self.phase == 'rest' or self.phase == 'bell', 'Native bell opened outside a rest phase')
            self.phase = 'bell'
            self:record()
        end,
        closed = function()
            if self.phase == 'bell' then self.phase = 'rest'; self:record() end
        end,
        shop = function() self:open_shop() end,
        skills = function() self:open_skills() end,
        next = function() self:next_wave() end,
        restart = function() self:restart_from_bell() end,
        error = function(message) self:fail(message) end
    })
    if self.resume_checkpoint then
        self.saves:restore()
        self:after_checkpoint()
    else
        -- Restarting in the same process keeps the pawn's purchased nodes alive.
        self.progression:reset()
        self.equipment:initialize()
        Economy.set_balance(player, self.config.run.startingMoney)
        self.phase = 'ready'
        if self.start_after_restart then
            self.start_after_restart = nil
            self:prepare_first_wave()
        else
            self.ui:start_page(self.resume_note, {
                {id = 'begin', label = Locale.text('开始修炼', 'Begin Training'), on_select = function() self:prepare_first_wave() end},
                {id = 'quit', label = Locale.text('退出游戏', 'Quit Game'), on_select = function() self:quit() end}
            })
            self:update_hud()
        end
    end
    self:record()
    print('[PBZRogue] Arena and isolated run state initialized; ready to play.\n')
end

function Run:update_hud(remaining, countdown)
    local next_floor = self.phase == 'rest' and self.wave == 3 and self.floor + 1 or nil
    self.ui:hud({
        floor = self.floor, wave = math.max(1, self.wave), phase = self.phase,
        remaining = remaining, countdown = countdown,
        boss_names = self.battle:boss_preview(self.floor).names,
        next_floor = next_floor,
        next_boss_names = next_floor and self.battle:boss_preview(next_floor).names or nil
    })
end

function Run:prepare_first_wave()
    assert(self.phase == 'ready' and self.floor == 1 and self.wave == 0, 'Opening preparation requires a new run')
    self.equipment:prepare_shop(self.floor, self.wave)
    self.ui:preload_shop(self:shop_model())
    self.phase = 'rest'
    self.restpoint:spawn()
    self.ui:hide()
    self:update_hud()
    self:record()
end

-- Load a GM floor in place. Player health, wallet, equipment, progression and
-- the native save slot are untouched: only the wave lineup, floor counter and
-- next shop weights change. The wave starts through the normal countdown so
-- settlement, checkpoints and the bell keep their regular behavior.
function Run:gm_apply(plan)
    local phase = self.phase
    assert(phase ~= 'menu' and phase ~= 'loading' and phase ~= 'dying' and phase ~= 'ended' and phase ~= 'failed',
        Locale.text('当前状态不能加载 GM 楼层', 'A GM floor cannot be loaded in the current state'))
    if self.saves:is_busy() then error(Locale.text('正在存档，请稍后再加载 GM 楼层', 'Saving. Load the GM floor again shortly.'), 0) end
    if self.equipment.busy then error(Locale.text('商店交易处理中，请稍后再加载', 'A shop transaction is in progress; try again shortly'), 0) end
    if phase == 'combat' then
        self.battle:clean()
        self.battle.music:stop(false)
    end
    if phase == 'rest' or phase == 'bell' or phase == 'shop' or phase == 'skills' then
        self.equipment:close_shop()
        self.restpoint:destroy()
    end
    self.ui:hide()
    self.battle:set_custom_waves({mobs = plan.mobs, boss = plan.boss})
    self.equipment:set_shop_override(plan.shop)
    self.floor = plan.floor
    self.gm_scenario, self.gm_no_refill = plan.summary, true
    local start = plan.summary.start or 'wave1'
    if start == 'shop' then
        -- Preview the configured shop immediately. A real bell is spawned first
        -- so the shop's close button has a valid rest stop to return to.
        self.wave, self.phase = 3, 'bell'
        self.gm_no_refill = nil
        self.restpoint:spawn()
        self:show_shop()
    else
        -- wave 1/2/boss map directly onto the existing three-wave floor.
        self.wave = start == 'wave2' and 2 or (start == 'boss' and 3 or 1)
        self.phase = 'between'
        local gameplay = Native.cdo('/Script/Engine.Default__GameplayStatics')
        self.next_wave_at = gameplay:GetTimeSeconds(self.player) + self.config.floors.waveDelaySeconds
        self:update_hud()
        self:record()
    end
    print(string.format('[PBZRogue] GM floor %d loaded without reset (%s): %d mobs / %d mobs / %d boss\n',
        plan.floor, start, #plan.mobs[1], #plan.mobs[2], #plan.boss))
end

function Run:clear_gm()
    if not self.gm_scenario then return end
    self.battle:set_custom_waves(nil)
    self.equipment:set_shop_override(nil)
    self.gm_scenario, self.gm_no_refill = nil, nil
    print('[PBZRogue] GM floor cleared; configured generation resumed.\n')
end

function Run:next_wave()
    assert(self.phase == 'between' or self.phase == 'bell', 'Invalid wave transition')
    if self.saves:is_busy() then self.ui:set_status(Locale.text('正在存档，请稍候。', 'Saving. Please wait.')); return end
    if self.phase == 'bell' then
        self.equipment:close_shop()
        self.restpoint:destroy()
        if self.wave == 3 then
            self.floor, self.wave = self.floor + 1, 0
            self:clear_gm()
        else assert(self.wave == 2 or (self.floor == 1 and self.wave == 0),
            'Bell requires opening preparation, two mob waves or the boss') end
    end
    self.ui:hide()
    self.wave = self.wave + 1
    self.phase = 'between'
    self.next_wave_at = Native.cdo('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(self.player)
        + self.config.floors.waveDelaySeconds
    self:record()
end


function Run:after_checkpoint()
    if self.wave == 1 then
        self.phase = 'between'
        self:next_wave()
        return
    end
    assert(self.wave == 2 or self.wave == 3, 'Invalid completed wave')
    self.equipment:prepare_shop(self.floor, self.wave)
    self.ui:preload_shop(self:shop_model())
    self.phase = 'rest'
    self.restpoint:spawn()
    self:update_hud()
    self:record()
end

function Run:settle_wave()
    assert(self.phase == 'combat' and self.wave >= 1 and self.wave <= 3, 'Only an active wave can settle')
    self.phase = 'checkpoint'
    self.battle:clean()
    if self.wave ~= 1 then self.battle.music:stop(true) end
    if self.wave == 3 then self.progression:award_floor(self.config.floors.clearReward) end
    self.equipment:complete_wave(self.floor, self.wave)
    self:record()
    self:update_hud()
    local ok, message = self.saves:save()
    if not ok and self.phase == 'checkpoint' then self:fail(message) end
end

function Run:open_bell()
    assert(self.phase == 'rest' or self.phase == 'shop' or self.phase == 'skills', 'Bell is not available')
    self.equipment:close_shop()
    self.ui:hide()
    self.phase = 'bell'
    self.restpoint:open_menu()
    self:record()
end

function Run:shop_model()
    local model = self.equipment:model()
    local price, balance = self.progression:heart_price(), Economy.balance(self.player)
    model.balance = balance
    model.fixed[#model.fixed + 1] = {
        id = 'heart', title = Locale.text('购买榕树之心', "Buy The Banyan's Heart"), price = price, enabled = price ~= nil and balance >= price,
        icon = '/Game/PBZContent/UI/UINew/items/RongShuZhiXin_w.RongShuZhiXin_w',
        service = string.format(Locale.text('已购买 %d/8', 'Purchased %d/8'), self.progression.heart_purchases),
        reason = price == nil and Locale.text('本局已购满（8/8）', 'Run purchase limit reached (8/8)') or (balance < price and Locale.text('金钱不足', 'Not enough money') or nil),
        detail = Locale.text('用于原生技能树升级；每局最多购买 8 个', 'Used for skill tree upgrades; purchase up to 8 per run')
    }
    return model
end

function Run:open_shop()
    assert(self.phase == 'bell', 'Shop requires a rest bell')
    if self.saves:is_busy() then self.ui:set_status(Locale.text('正在存档，请稍候。', 'Saving. Please wait.')); return end
    self.restpoint:close_menu()
    self:show_shop()
end

-- Presentation is shared by the bell and the GM shop preview. The caller has
-- already closed any native menu and (for GM previews) spawned a rest bell so
-- the shop's close button returns to a valid bell instead of a dead actor.
function Run:show_shop()
    self.phase = 'shop'
    self.equipment:open_shop(self.floor, self.wave)
    local model = self:shop_model()
    self.ui:show(model, {
        purchase = function(id, target, expectedOffer)
            if self.phase ~= 'shop' then return false, Locale.text('商店已经关闭', 'The shop is closed') end
            if self.saves:is_busy() then return false, Locale.text('正在存档，请稍候。', 'Saving. Please wait.') end
            local ok, message
            if id == 'heart' then
                local price = self.progression:heart_price()
                if price == nil then return false, Locale.text('榕树之心已购满（8/8）', "The Banyan's Heart purchase limit reached (8/8)") end
                if expectedOffer and expectedOffer.price ~= price then return false, Locale.text('商品已刷新；未扣费', 'The offer has changed; no money was charged') end
                if Economy.balance(self.player) < price then return false, Locale.text('金钱不足', 'Not enough money') end
                local count = self.progression:buy_heart()
                local charged, reason = Economy.charge(self.player, price)
                assert(charged, reason)
                ok, message = true, string.format(Locale.text('购买完成；当前榕树之心：%d，余额 %d', "Purchase complete. The Banyan's Heart: %d; balance: %d"), count, Economy.balance(self.player))
            else ok, message = self.equipment:purchase(id, target, expectedOffer) end
            if ok then self:record() end
            return ok, message
        end,
        refresh = function() return self:shop_model() end,
        close = function() self:open_bell() end
    })
    self:record()
end

function Run:open_skills()
    assert(self.phase == 'bell', 'Skills require a rest bell')
    if self.saves:is_busy() then self.ui:set_status(Locale.text('正在存档，请稍候。', 'Saving. Please wait.')); return end
    self.restpoint:close_menu()
    self.ui:hide()
    self.phase = 'skills'
    self.progression:open(function()
        if self.phase == 'skills' then
            self.equipment:sync_accessory_slots()
            self:open_bell()
        end
    end)
    self:record()
end

function Run:restart_from_bell()
    if self.restart_requested or self.restart_confirmation then return end
    assert(self.phase == 'bell', 'Restart requires a rest bell')
    if self.saves:is_busy() then self.ui:set_status(Locale.text('正在存档，请稍候。', 'Saving. Please wait.')); return end
    self.restpoint:close_menu()
    self.restart_confirmation = true
    self.ui:confirm_restart(function()
        if self.phase ~= 'bell' or not self.restart_confirmation then return false, Locale.text('确认已失效。', 'This confirmation is no longer valid.') end
        if self.saves:is_busy() then return false, Locale.text('正在存档，请稍候。', 'Saving. Please wait.') end
        self.restart_confirmation = nil
        self.restart_requested = true
        self.ui:hide()
        self:finish(Locale.text('主动重开本局；存档清理完成后自动开始新局。', 'Restart requested. A new run will begin automatically once the save has been cleared.'))
        return true
    end, function()
        if self.phase ~= 'bell' or not self.restart_confirmation then return end
        self.restart_confirmation = nil
        self.phase = 'rest'
        self:open_bell()
    end)
end

function Run:begin_death()
    if self.phase == 'dying' or self.phase == 'ended' or self.phase == 'failed' or self.phase == 'loading' then return end
    self.phase = 'dying'
    -- Only committed native death is terminal; pending death may be intercepted
    -- by equipment revival. Lock ordinary Respawn without stopping that ability.
    if not self.player:ActorHasTag(FName('PBZRogue.DeathLocked')) then
        local tags = Native.array(self.player.Tags)
        tags[#tags + 1] = FName('PBZRogue.DeathLocked')
        self.player.Tags = tags
    end
    self.saves:invalidate(Locale.text('角色死亡。', 'You died.'))
    self:record()
end

function Run:close_death_page()
    if not Native.valid(self.player) then return end
    local page = self.player['Death Widget']
    if not Native.valid(page) then return end
    -- The death patch removes native resurrection and deferred ResetAllLayers
    -- callbacks, so releasing CommonUI ownership cannot erase the restart page.
    page:StopAllAnimations()
    if page:IsActivated() then page:DeactivateWidget() end
    Native.cdo('/Script/CommonGame.Default__CommonUIExtensions'):PopContentFromLayer(page)
    self.player['Death Widget'] = nil
end

function Run:finish(reason)
    if self.phase == 'ended' then return end
    local died = self.phase == 'dying'
    self.phase = 'ended'
    if not self.death_cleaned then self.saves:invalidate(reason) end
    self.restpoint:destroy()
    self.progression:destroy()
    self.battle:destroy()
    self:record()
    local choices = {
        {id = 'restart', label = Locale.text('再战', 'Try Again'), on_select = function() self:restart() end},
        {id = 'quit', label = Locale.text('退出游戏', 'Quit Game'), on_select = function() self:quit() end}
    }
    if died then
        local page = self.player['Death Widget']
        assert(Native.valid(page), Locale.text('原生殒命页面不可用', 'The native death screen is unavailable'))
        -- Pause at the visible native pose instead of removing the death backdrop.
        page:PauseAnimation(page.AI_PlayerDeadDaysDecrease)
        self.ui:death_page(choices)
    else
        self:close_death_page()
        self.ui:message(Locale.text('本局结束', 'Run Over'), reason .. string.format(Locale.text('\n到达第 %d 层。所有成长仅属于本局。', '\nReached floor %d. All progression applies only to this run.'), self.floor), choices)
    end
end

function Run:leave_world()
    if self.returned_to_menu then return end
    local world_alive = Native.valid(self.player) and Native.valid(self.controller)
        and Native.same(Native.controller(self.instance), self.controller)
    self.returned_to_menu, self.phase = true, 'menu'
    if active_run == self then active_run = nil end
    if self.saves then self.saves:detach() end
    -- Invalidate callbacks before any native deactivation broadcasts. If travel
    -- has already invalidated the world, only release ownership; never call its
    -- actors, audio subsystem, pause state, or CommonUI layer.
    local function cleanup(action)
        local ok, message = xpcall(action, debug.traceback)
        if not ok then print('[PBZRogue] Leaving world: ' .. tostring(message) .. '\n') end
    end
    if self.ui then cleanup(function() self.ui:destroy(not world_alive) end) end
    if self.progression then cleanup(function() self.progression:destroy(not world_alive) end) end
    if self.battle then cleanup(function() self.battle:destroy(not world_alive) end) end
    if world_alive and self.restpoint then cleanup(function() self.restpoint:destroy() end) end
    if self.equipment then self.equipment:close_shop() end
    cleanup(function()
        local game_data = Native.load_object('/Game/PBZContent/Blueprint/DA_PBZGameDataPolicy.DA_PBZGameDataPolicy')
        if Native.same(game_data.NormalGamePolicy, self.policy) then game_data.NormalGamePolicy = nil end
        if Native.valid(self.instance) and Native.same(self.instance.InitDataPolicy, self.policy) then self.instance.InitDataPolicy = nil end
        Native.release(self.policy)
    end)
    self.ui, self.progression, self.battle, self.restpoint, self.equipment = nil, nil, nil, nil, nil
    self.player, self.controller, self.policy = nil, nil, nil
    self.quit_requested, self.restart_requested = nil, nil
    if self.profile then cleanup(function() self:record() end) end
end

function Run:resume_from_menu(menu)
    assert(self.returned_to_menu and self.phase == 'menu', 'Run has not returned to the main menu')
    assert(not self.saves:is_busy(), Locale.text('正在完成后台存档，请稍候。', 'Finishing the background save. Please wait.'))
    self:verify_isolation(menu, restart_token)
    local resume = self.saves:has_checkpoint()
    if self.saves.discarded then self.saves:retire() end
    assert(not self.saves.discard_error, self.saves.discard_error)
    local directory, profile, instance = self.directory, self.profile, self.instance
    for key in pairs(self) do self[key] = nil end
    self.directory, self.profile, self.instance = directory, profile, instance
    self.phase, self.floor, self.wave, self.resume_requested = 'menu', 1, 0, resume
    self:begin(menu, restart_token)
end

function Run:restart()
    assert(self.phase == 'ended', 'Only an ended run can start a fresh in-process run')
    if self.saves:is_busy() then self.ui:set_status(Locale.text('正在存档，请稍候。', 'Saving. Please wait.')); return end
    local instance, profile, directory, player = self.instance, self.profile, self.directory, self.player
    self:verify_isolation(instance, restart_token)
    self.saves:retire()
    self:close_death_page()
    self.ui:destroy()
    self.equipment:close_shop()
    self.restpoint:destroy()
    self.progression:destroy()
    self.battle:destroy()
    local game_data = Native.load_object('/Game/PBZContent/Blueprint/DA_PBZGameDataPolicy.DA_PBZGameDataPolicy')
    if Native.same(game_data.NormalGamePolicy, self.policy) then game_data.NormalGamePolicy = nil end
    if Native.same(instance.InitDataPolicy, self.policy) then instance.InitDataPolicy = nil end
    Native.release(self.policy)
    -- Preserve only the verified namespace and GI, never run-owned Lua state.
    for key in pairs(self) do self[key] = nil end
    self.directory, self.profile, self.instance = directory, profile, instance
    self.phase, self.floor, self.wave, self.resume_requested = 'menu', 1, 0, false
    self.departing_player = player
    self.start_after_restart = true
    self:begin(instance, restart_token)
end

function Run:quit()
    if self.saves and self.saves:is_busy() then
        self.quit_requested = true
        if self.ui then self.ui:set_status(Locale.text('正在后台保存，完成后自动退出。', 'Saving in the background. The game will quit automatically when finished.')) end
        return
    end
    self.quit_requested = nil
    if self.profile then self.phase = 'ended'; self:record() end
    if self.ui then self.ui:hide() end
    if self.battle then self.battle:destroy() end
    if self.restpoint then self.restpoint:destroy() end
    if self.progression then self.progression:destroy() end
    Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):QuitGame(self.player, self.controller, 0, false)
end

function Run:fail(message)
    print('[PBZRogue] Run stopped: ' .. tostring(message) .. '\n')
    if self.returned_to_menu then
        self.failure = tostring(message)
        if self.profile then pcall(function() self:record() end) end
        return
    end
    self.phase = 'failed'
    self.failure = tostring(message)
    if self.profile then pcall(function() self:record() end) end
    if Native.valid(self.player) and self.player:ActorHasTag(FName('PBZRogue.DeathLocked')) then
        pcall(function() self:close_death_page() end)
    end
    if self.battle then pcall(function() self.battle:destroy() end) end
    if self.restpoint then pcall(function() self.restpoint:destroy() end) end
    if self.progression then pcall(function() self.progression:destroy() end) end
    if self.ui then
        self.ui:message(Locale.text('模式已停止', 'Mode Stopped'), tostring(message) .. Locale.text('\n未跳过敌人、未伪造升级。详细信息见 UE4SS 日志。', '\nNo enemies were skipped and no upgrades were fabricated. See the UE4SS log for details.'), {
            {id = 'quit', label = Locale.text('退出游戏', 'Quit Game'), on_select = function() self:quit() end}
        })
    end
end

function Run:tick(context)
    if self.returned_to_menu then
        if self.saves then self.saves:tick() end
        return
    end
    if self.player and self.phase ~= 'loading' and
        (not Native.valid(self.player) or not Native.same(Native.controller(self.instance), self.controller)) then
        self:leave_world()
        return
    end
    if Native.valid(self.player) and self.phase ~= 'loading' and self.phase ~= 'failed'
        and self.phase ~= 'ended' and self.phase ~= 'dying' then
        local death = self.player['Death Component']
        assert(Native.valid(death), 'Native death component disappeared')
        if death['Is Dead'](death) then self:begin_death() end
    end
    if self.saves then self.saves:tick() end
    if self.quit_requested then
        if not self.saves:is_busy() then self:quit() end
        return
    end
    if self.restart_requested and self.phase == 'ended' then
        if not self.saves:is_busy() then self:restart() end
        return
    end
    if self.phase == 'dying' then
        if not self.death_cleaned then
            self.ui:hide()
            if Native.valid(self.ui.hud_page) then self.ui.hud_page:SetVisibility(1) end
            self.equipment:close_shop()
            self.restpoint:destroy()
            self.progression:destroy()
            self.battle:destroy()
            self.death_cleaned = true
        end
        -- Only DeadMenu's visible glyph/geometry observation starts its one
        -- second clock. Health zero, object creation and activation do not.
        if self.player:ActorHasTag(FName('PBZRogue.DeathReady')) then self:finish(Locale.text('角色死亡。', 'You died.')) end
        return
    end
    if self.ui then self.ui:focus_pending() end
    if self.progression then self.progression:tick() end
    if self.phase == 'menu' or self.phase == 'failed' or self.phase == 'ended' then return end
    local gameplay = Native.cdo('/Script/Engine.Default__GameplayStatics')
    if self.phase == 'loading' then
        local player = Native.player(context)
        if Native.valid(player) and not Native.same(player, self.departing_player)
            and player:IsA('/Game/RenewalContent/Prototypes/Character/BP_RenewalPlayer.BP_RenewalPlayer_C') then
            local level = Native.name(gameplay:GetCurrentLevelName(player, true))
            if level == self.config.floors.arena.map:match('([^/]+)$') then
                local health = Native.health(player)
                if health and health > 0 then
                    local now = gameplay:GetTimeSeconds(player)
                    self.player_ready_at = self.player_ready_at or now
                    if now - self.player_ready_at >= self.config.floors.readyDelaySeconds then self:ready(player) end
                end
            end
        end
        assert(os.time() - self.loading_started < 180, 'Arena initialization timed out')
        return
    end
    if self.restpoint then self.restpoint:tick() end
    if self.phase == 'shop' or self.phase == 'bell' or self.phase == 'skills' or self.phase == 'ready'
        or self.phase == 'failed' or self.phase == 'ended' then return end
    if gameplay:IsGamePaused(self.player) then return end
    -- Native control handovers can temporarily possess no pawn or another pawn.
    -- Keep the original character, as RenewalPlayer's save-section handover does.
    if not Native.same(Native.player(self.instance), self.player) then return end
    self.battle:enforce_boundary()
    if self.phase == 'checkpoint' then return end
    if self.phase == 'rest' then
        self:update_hud()
        return
    end
    if self.phase == 'between' then
        local remaining = self.next_wave_at - gameplay:GetTimeSeconds(self.player)
        self:update_hud(nil, math.max(0, math.ceil(remaining)))
        if remaining <= 0 then
            -- Bell departures refill supplies and health; a GM load intentionally
            -- leaves the player exactly as they were when the scenario was sent.
            if (self.wave == 1 or self.wave == 3) and not self.gm_no_refill then
                self.equipment.fixed:prepare_combat_resources()
            end
            self.gm_no_refill = nil
            self.battle:start(self.floor, self.wave)
            self.phase = 'combat'
            self:record()
        end
    elseif self.phase == 'combat' then
        local remaining = self.battle:remaining()
        self:update_hud(remaining)
        if remaining == 0 then
            self:settle_wave()
        end
    end
end

return Run
