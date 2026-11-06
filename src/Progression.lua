local Native = require('Native')
local Locale = require('Locale')
local Progression = {}
Progression.__index = Progression

Progression.HEART_ID = 'I_060002'
local widget_path = '/Game/PBZContent/UI/AbilityWidget/W_AbilityWidget.W_AbilityWidget_C'
local skill_mode_tag = 'PBZRogue.NativeSkills'
local skill_ready_tag = 'PBZRogue.NativeSkillsReady'
-- Native GEClassArray identifies only these three as repeatable stat upgrades.
local disabled_stat_nodes = {HeiShi8 = true, ShaChiHuPo8 = true, MemoryFlower8 = true}
local priced_progression, price_hook_installed

local function install_price_hook()
    if price_hook_installed then return end
    RegisterHook('/Script/ProjectPBZ.AbilityNodeHelpObj:GetConsumeDust', function() end,
        function(context)
            local owner = priced_progression
            if not owner or not Native.valid(owner.player) or not Native.valid(owner.component) then return end
            local node = context:get()
            if not Native.valid(node) then return end
            local entry = owner.priced_nodes[node:GetAddress()]
            if entry and Native.same(entry.node, node) then return entry.price end
        end)
    price_hook_installed = true
end

local function inventory_count(backpack, id)
    local count = 0
    backpack.Inventories:ForEach(function(key, value)
        if Native.name(key:get()) == id then count = value:get().CurrentAmount end
    end)
    return count
end

function Progression.new(backpack, player, config)
    assert(Native.valid(backpack) and Native.valid(player), Locale.text('修行系统需要有效原生背包和玩家', 'Training requires a valid native inventory and player'))
    local self = setmetatable({backpack = backpack, player = player,
        heart_prices = config.economy.heartPrices, heart_purchases = 0}, Progression)
    self.library = Native.cdo('/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary')
    self.component = self.library:GetPBZAbilityNodesComponent(player)
    assert(Native.valid(self.component), Locale.text('原生角色能力节点组件不可用', 'Native character ability-node component is unavailable'))
    self.asc = Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary')
        :GetAbilitySystemComponent(player)
    assert(Native.valid(self.asc), Locale.text('原生能力系统组件不可用', 'Native ability-system component is unavailable'))
    self.ui_library = Native.cdo('/Script/CommonGame.Default__CommonUIExtensions')
    self.priced_nodes = {}
    local remaining = {}
    for id, price in pairs(config.economy.skills) do remaining[id] = price end
    self.component.AbilityNodeMap:ForEach(function(key, value)
        local id, node = Native.name(key:get()), value:get()
        local price = remaining[id]
        if price ~= nil then
            assert(Native.valid(node), Locale.text('人物升级价格对应节点无效: ', 'Invalid character-upgrade node for configured price: ') .. id)
            self.priced_nodes[node:GetAddress()] = {node = node, price = price}
            remaining[id] = nil
        end
    end)
    assert(next(remaining) == nil, Locale.text('人物升级价格包含未知原生节点', 'Character-upgrade prices contain unknown native nodes'))
    install_price_hook()
    priced_progression = self
    return self
end

-- New runs must start from a clean skill tree. The native save slot is deleted on
-- restart, but the pawn's ability nodes survive an in-process restart, so reset
-- them through the native deactivation path before the run begins.
function Progression:reset()
    assert(not Native.valid(self.page), Locale.text('必须先关闭修行界面才能重置人物升级', 'Close Training before resetting character upgrades'))
    self.component:DeactivateAllNodes(self.asc)
    self.component.AbilityNodeMap:ForEach(function(key, value)
        local node = value:get()
        if Native.valid(node) then
            assert(node.Level == 0, Locale.text('原生修行节点未清零: ', 'Native training node was not reset: ') .. Native.name(key:get()))
        end
    end)
    self.heart_purchases = 0
end

function Progression:_set_skill_scope()
    assert(not self.skill_scope, Locale.text('原生修行策略已经启用', 'Native training policy is already active'))
    local tags = Native.array(self.player.Tags)
    for _, tag in ipairs(tags) do
        local name = Native.name(tag)
        assert(name ~= skill_mode_tag and name ~= skill_ready_tag, Locale.text('原生修行策略标记未清除', 'Native training policy tags were not cleared'))
    end
    tags[#tags + 1] = FName(skill_mode_tag)
    self.player.Tags = tags
    self.skill_scope = true
end

function Progression:_clear_skill_scope()
    if not self.skill_scope then return end
    if Native.valid(self.player) then
        local tags = {}
        for _, tag in ipairs(Native.array(self.player.Tags)) do
            local name = Native.name(tag)
            if name ~= skill_mode_tag and name ~= skill_ready_tag then tags[#tags + 1] = tag end
        end
        self.player.Tags = tags
    end
    self.skill_scope = nil
end

function Progression:_require_skill_policy()
    if self.player:ActorHasTag(FName(skill_ready_tag)) then return end
    self:destroy()
    error(Locale.text('原生修行规则补丁未生效；请完整安装同名 .pak/.utoc/.ucas 三个文件，并在下次启动游戏时加载', 'Native training patch is inactive; install all three matching .pak/.utoc/.ucas files for the next game launch'))
end

function Progression:open(on_close)
    assert(not Native.valid(self.page), Locale.text('修行界面已经打开', 'Training is already open'))
    assert(type(on_close) == 'function', Locale.text('修行界面需要关闭回调', 'Training requires a close callback'))
    local class = Native.load_class(widget_path)
    local controller = Native.controller(self.player)
    local local_player = self.ui_library:GetLocalPlayerFromController(controller)
    assert(Native.valid(local_player), Locale.text('原生修行界面缺少本地玩家', 'Native Training UI has no local player'))
    -- The story tutorial grants a free node, resets the tree, and requests an
    -- autosave. This isolated run uses the real purchase UI, not that tutorial.
    local runtime = Native.subsystem(self.player, '/Script/ProjectPBZ.PBZUIRuntimeDataManager')
    local tutorial = {TagName = FName('UI.Tutorial.AbilityWidget')}
    runtime:AddTutorialTag(tutorial)
    runtime:CompleteTutorialTag(tutorial)
    -- The native story gate hides both heart branches. The scoped JS policy
    -- handles selectable node states and purchases without changing any levels,
    -- cycle counts, table rows, owned materials or original node caps.
    self.previous_heart_visibility = self.component.bForceUnLockRongShuZhiXin
    self.component.bForceUnLockRongShuZhiXin = true
    local ok, page = pcall(function()
        self:_set_skill_scope()
        return self.ui_library:PushContentToLayer_ForPlayer(local_player,
            {TagName = FName('UI.Layer.Menu')}, class)
    end)
    if not ok or not Native.valid(page) then
        self:_restore_visibility()
        self:_clear_skill_scope()
        error(ok and Locale.text('原生修行界面未能进入菜单层', 'Native Training UI could not enter the menu layer') or page)
    end
    self.page = page
    self.seen_active = page:IsActivated()
    self.open_started = Native.cdo('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(self.player)
    self.on_close = on_close
    if self.seen_active then self:_require_skill_policy() end
    -- The native UI owns purchases/refunds/materials; GetConsumeDust supplies the
    -- configured price for this run's nodes only. No temporary funding is granted.
end

function Progression:_restore_visibility()
    if self.previous_heart_visibility ~= nil and Native.valid(self.component) then
        self.component.bForceUnLockRongShuZhiXin = self.previous_heart_visibility
    end
    self.previous_heart_visibility = nil
end

function Progression:tick()
    if not self.on_close then return end
    if Native.valid(self.page) and self.page:IsActivated() then
        self.seen_active = true
        self:_require_skill_policy()
        return
    end
    -- CommonUI may return a queued page before its layer transition activates
    -- it. Inactive during opening is not a close, and world pause must not stop
    -- this deadline (GetRealTimeSeconds is independent of time dilation/pause).
    if not self.seen_active then
        local elapsed = Native.cdo('/Script/Engine.Default__GameplayStatics'):GetRealTimeSeconds(self.player)
            - self.open_started
        if Native.valid(self.page) and elapsed < 10 then return end
        self:destroy()
        error(Locale.text('原生修行界面未能在 10 秒内激活；已关闭等待中的页面', 'Native Training UI did not activate within 10 seconds; the pending page was closed'))
    end
    local callback = self.on_close
    self.on_close, self.page = nil, nil
    self.seen_active, self.open_started = nil, nil
    self:_restore_visibility()
    self:_clear_skill_scope()
    callback()
end

function Progression:destroy(world_ended)
    self.on_close = nil
    if not world_ended then
        if Native.valid(self.page) then self.ui_library:PopContentFromLayer(self.page) end
        self:_restore_visibility()
        self:_clear_skill_scope()
    end
    self.page, self.skill_scope, self.previous_heart_visibility = nil, nil, nil
    self.seen_active, self.open_started = nil, nil
    if priced_progression == self then priced_progression = nil end
end

function Progression:heart_count()
    return inventory_count(self.backpack, self.HEART_ID)
end

function Progression:heart_price()
    return self.heart_prices[self.heart_purchases + 1]
end

function Progression:buy_heart()
    assert(self:heart_price() ~= nil, Locale.text('榕树之心已购满（8/8）', "The Banyan's Heart purchase limit reached (8/8)"))
    local before = self:heart_count()
    -- Price and payment belong to Run; count successful grants, not inventory.
    -- Spending or refunding native materials must not reopen a purchase tier.
    self.backpack:AddPropsToBackPack(1, FName(self.HEART_ID), false)
    local after = self:heart_count()
    assert(after == before + 1, Locale.text('原生背包未增加榕树之心（可能已到物品上限）', "The Banyan's Heart was not added to the native inventory (item limit may have been reached)"))
    self.heart_purchases = self.heart_purchases + 1
    return after
end

function Progression:award_floor(amount)
    assert(type(amount) == 'number' and amount >= 0 and amount % 1 == 0 and amount <= 2147483647,
        Locale.text('楼层奖励必须是原生 int32 范围内的非负整数', 'Floor reward must be a nonnegative integer within the native int32 range'))
    -- Run is the sole once-per-completed-floor caller. Native dust notification
    -- and persistence remain native; this does not touch health/ammo/medicine.
    self.backpack:AddDustNum(amount)
    return self.library:GetCurrentDust(self.player)
end

function Progression:snapshot()
    assert(not Native.valid(self.page), Locale.text('必须先关闭修行界面才能保存真实货币', 'Close Training before saving native currency'))
    local nodes = {}
    self.component.AbilityNodeMap:ForEach(function(key, value)
        local node = value:get()
        if Native.valid(node) and node.bActive then
            nodes[Native.name(key:get())] = {level = node.Level}
        end
    end)
    return {nodes = nodes, heart = self:heart_count(), heart_purchases = self.heart_purchases,
        dust = self.library:GetCurrentDust(self.player),
        load_key = Native.name(self.component.LoadObjectJsonKey)}
end

function Progression:restore(snapshot)
    assert(type(snapshot) == 'table' and type(snapshot.nodes) == 'table', Locale.text('修行续局状态无效', 'Invalid saved Training state'))
    assert(type(snapshot.heart_purchases) == 'number' and snapshot.heart_purchases % 1 == 0
        and snapshot.heart_purchases >= 0 and snapshot.heart_purchases <= #self.heart_prices,
        Locale.text('榕树之心购买记录无效', "Invalid purchase history for The Banyan's Heart"))
    -- Native SaveGame/LoadJson restores the effects and their levels. Replaying
    -- purchases would double-charge, grant duplicate effects, or refill stats.
    local current = self:snapshot()
    assert(current.load_key == snapshot.load_key, Locale.text('原生修行存档键不匹配', 'Native Training save key does not match'))
    assert(current.heart == snapshot.heart and current.dust == snapshot.dust, Locale.text('原生修行材料或货币未正确载入', 'Native Training materials or currency were not restored correctly'))
    for id, node in pairs(snapshot.nodes) do
        assert(current.nodes[id] and current.nodes[id].level == node.level, Locale.text('原生修行节点未正确载入: ', 'Native Training node was not restored correctly: ') .. id)
    end
    for id in pairs(current.nodes) do
        assert(snapshot.nodes[id], Locale.text('原生修行出现续局以外节点: ', 'Native Training contains a node absent from the saved run: ') .. id)
    end
    self.heart_purchases = snapshot.heart_purchases
    return true
end

return Progression
