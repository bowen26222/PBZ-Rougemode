local Native = require('Native')
local Locale = require('Locale')
local Economy = require('Economy')
local Fixed = {}
Fixed.__index = Fixed
local effectRoot = '/Game/PBZContent/Blueprint/Item/GameplayEffect/Permanent/'
local slotRoot = '/Game/PBZContent/Blueprint/Ability/GameplayEffects/AbilityTree/'
local snapshotVersion, maximumLevel = 2, 20
local statDefinitions = {
    {id = 'fixed:health', title = {'莲花 · 血量上限升级', 'Lotus · Max Health Upgrade'}, target = 'Health_Max',
        icon = '/Game/PBZContent/UI/AbilityWidget/Texture/T_AbilityNeedItem_MemoryFLower.T_AbilityNeedItem_MemoryFLower'},
    {id = 'fixed:attack', title = {'黑石 · 攻击力升级', 'Blackstone · Attack Upgrade'}, item = 'Item_001', target = 'Attack',
        icon = '/Game/PBZContent/UI/UINew/items/T_HeiShiWanzheng_Icon.T_HeiShiWanzheng_Icon'},
    {id = 'fixed:shachi', title = {'杀气琥珀 · 杀气上限升级', 'Sha-Chi Amber · Max Sha-Chi Upgrade'}, item = 'Item_002', target = 'Shachi_Max',
        icon = '/Game/PBZContent/UI/UINew/items/T_HuPoWanzheng_Icon.T_HuPoWanzheng_Icon'},
}
local statNames = {
    Health_Max = {'生命值上限', 'Max HP'},
    Infliction_Max = {'内伤上限', 'Max Internal Injury'},
    Attack = {'攻击力', 'Attack'},
    ShachiAttack = {'杀气攻击力', 'Sha-Chi Attack'},
    Shachi_Max = {'杀气上限', 'Max Sha-Chi'},
}
local function stat_name(name)
    local label = statNames[name]
    return label and Locale.text(label[1], label[2]) or name
end
-- These IDs/petals are only for stripping initial or legacy native grants.
local flowerIDs = {
    'F_02001', 'FA_0201', 'FA_0202', 'FA_0203', 'FA_0205', 'FA_0206',
    'FA_0300', 'FA_0310', 'FA_0301', 'FA_0303', 'FA_0401', 'FA_0501',
    'FA_0502', 'FA_0503', 'FA_0505', 'FA_0600', 'FA_0602', 'FA_0601',
    'FA_0304', 'FA_0603', 'FA_0604', 'FA_0701', 'FA_0702', 'FA_0704',
    'FA_0801', 'FA_7000', 'FA_0804', 'FA_1100', 'FA_1200', 'FA_1201',
    'FA_1300', 'FA_1301', 'FA_1800', 'FA_1804', 'FA_1802', 'FA_1803', 'F_13020',
}
local slotAssets = {'GA_AddAccessorySlot_HeiShi', 'GA_AddAccessorySlot_HuPo', 'GA_AddAccessorySlot_MemoryFlower', 'GA_AddAccessorySlot_RongShu'}
local function attributes() return Native.cdo('/Script/SGameAttributes.Default__AttributeUtils') end
local function asc(player)
    return Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):GetAbilitySystemComponent(player)
end
local function attribute_data(player, attribute)
    local set = asc(player):GetAttributeSet(attribute.AttributeOwner)
    assert(Native.valid(set), Locale.text('原生属性集尚未初始化', 'Native attribute set has not been initialized'))
    return set[Native.name(attribute.AttributeName)]
end
local function value(player, attribute) return attribute_data(player, attribute).CurrentValue end
local function finite(number)
    return type(number) == 'number' and number == number and number > -math.huge and number < math.huge
end
local function close(left, right)
    return math.abs(left - right) <= math.max(0.001, math.abs(right) * 0.000001)
end

-- CharacterBasics.BasicAttributeSet current/max resource pairs (build 26266538).
-- GetAllAttributes/GetHealthAttribute return Lua tables and lose FieldPathProperty.
-- Keep each attribute as a native UScriptStruct borrowed from its loaded GE asset instead.
local resourceNames = {'Health', 'Shield', 'Shachi', 'UltimateCharge', 'UltimateChargeCount', 'SpiritShadow', 'Awakening'}
local resourceEffects = {}
local function resource_effect(name)
    local binding = resourceEffects[name]
    if binding then return binding end
    local asset = 'GE_MA_' .. name .. '_1_Override'
    local effect = Native.load_object('/PBZCombatAsset/Config/AttributesModifyEffect/' .. asset .. '.' .. asset)
    local modifiers = Native.array(effect.Modifiers)
    assert(effect.DurationPolicy == 0 and #modifiers == 1, Locale.text('原生资源覆盖模板不是单属性即时效果: ', 'Native resource override template is not a single-attribute instant effect: ') .. name)
    local modifier = modifiers[1]
    local attribute = modifier.Attribute
    assert(type(attribute) == 'userdata' and attribute:type() == 'UScriptStruct' and attribute:IsValid(),
        Locale.text('原生属性必须保留FieldPath，不能使用UFUNCTION返回的Lua属性表: ', 'Native attribute must retain FieldPath; Lua attribute tables returned by UFUNCTION are unsupported: ') .. name)
    assert(Native.name(attribute.AttributeName) == name and modifier.ModifierOp == 3,
        Locale.text('原生资源覆盖模板与属性不符: ', 'Native resource override template does not match attribute: ') .. name)
    binding = {effect = effect, attribute = attribute, name = name}
    resourceEffects[name] = binding
    return binding
end

function Fixed.capture_resources(player)
    local result, component = {}, asc(player)
    for _, name in ipairs(resourceNames) do
        local binding = resource_effect(name)
        local set = component:GetAttributeSet(binding.attribute.AttributeOwner)
        assert(Native.valid(set), Locale.text('原生资源属性集尚未初始化: ', 'Native resource attribute set has not been initialized: ') .. name)
        result[#result + 1] = {name = name, current = set[name].CurrentValue}
    end
    return result
end

function Fixed.restore_resources(player, snapshot)
    local component = asc(player)
    for _, saved in ipairs(snapshot) do
        local binding = resource_effect(saved.name)
        local set = component:GetAttributeSet(binding.attribute.AttributeOwner)
        assert(Native.valid(set), Locale.text('原生资源属性集已失效: ', 'Native resource attribute set is no longer valid: ') .. binding.name)
        local target = math.min(saved.current, set[binding.name .. '_Max'].CurrentValue)
        -- Pass the original native struct intact; AttributeUtils applies the game's GAS override effect.
        -- Never write FGameplayAttributeData.CurrentValue/BaseValue directly.
        attributes():ModifyCharacterAttributeValue(player, binding.attribute, 3, target)
        assert(math.abs(set[binding.name].CurrentValue - target) < 0.001, Locale.text('原生资源恢复失败: ', 'Native resource restoration failed: ') .. binding.name)
    end
end

local function scaled(number, level)
    local curve = number.Curve
    if not Native.valid(curve.CurveTable) then return number.Value end
    local status, output = {}, {}
    Native.cdo('/Script/Engine.Default__DataTableFunctionLibrary'):EvaluateCurveTableRow(
        curve.CurveTable, curve.RowName, level, status, output, 'PBZRogue.FixedUpgrades')
    assert(status.OutResult == 0 and type(output.OutXY) == 'number', Locale.text('原生升级曲线求值失败', 'Native upgrade curve evaluation failed'))
    return number.Value * output.OutXY
end

function Fixed.new(backpack, player, config)
    local self = setmetatable({backpack = backpack, player = player, config = config, asc = asc(player),
        stats = {}, tags = {}, effects = {}, inventoryIDs = {}, bindings = {}}, Fixed)
    local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
    local function binding(soft)
        local path = Native.name(system:Conv_SoftClassReferenceToString(soft))
        if not self.effects[path] then
            local class = Native.load_class(path)
            local defaults = Native.cdo((path:gsub('%.([^%.]+)$', '.Default__%1')))
            local modifiers = Native.array(defaults.Modifiers)
            assert(#modifiers > 0, Locale.text('原生升级道具没有属性效果: ', 'Native upgrade item has no attribute effects: ') .. path)
            self.effects[path] = {path = path, class = class, defaults = defaults, modifiers = modifiers}
        end
        return self.effects[path]
    end
    local config = backpack.InventoryDataAsset
    assert(Native.valid(config), Locale.text('原生道具升级配置未加载', 'Native item-upgrade configuration is not loaded'))
    binding(config.SmallFlowerEffect)
    binding(config.MediumFlowerEffect)
    local healthEffect = binding(config.LargeFlowerEffect)
    for _, id in ipairs(flowerIDs) do
        self.inventoryIDs[id] = true
        for _, petal in ipairs(Native.array(backpack:GetOrderedMemoryFlowerPetals(FName(id)))) do
            self.inventoryIDs[Native.name(petal)] = true
        end
    end
    self.inventoryIDs.Item_Piece_001, self.inventoryIDs.Item_Piece_002 = true, true
    for _, def in ipairs(statDefinitions) do
        local stat = {id = def.id, title = def.title, icon = def.icon, target = def.target, level = 0, effect = healthEffect}
        if def.item then
            self.inventoryIDs[def.item] = true
            stat.effect = binding(backpack:GetPropData(FName(def.item)).AddAttributeGE)
            config.AmountTierExtraGEMap:ForEach(function(key, entry)
                if Native.name(key:get()) == def.item then
                    -- Second-tier templates are retained only to strip legacy grants.
                    local tier = entry:get()
                    -- The mod sells its own increments; the native first tier must
                    -- still cover the ten purchases it was authored for.
                    assert(tier.Tier1Max >= 10, Locale.text('原生第一阶不足十次: ', 'Native first tier supports fewer than ten purchases: ') .. def.item)
                    binding(tier.SecondTierGE)
                end
            end)
        end
        local hasTarget = false
        for _, modifier in ipairs(stat.effect.modifiers) do
            local attribute = modifier.Attribute
            local name = Native.name(attribute.AttributeName)
            assert(type(attribute) == 'userdata' and attribute:type() == 'UScriptStruct' and attribute:IsValid(),
                Locale.text('原生升级属性丢失FieldPath: ', 'Native upgrade attribute has lost FieldPath: ') .. name)
            self.bindings[name] = attribute
            hasTarget = hasTarget or name == stat.target
        end
        assert(hasTarget, Locale.text('原生升级缺少目标属性: ', 'Native upgrade is missing its target attribute: ') .. stat.target)
        self.stats[#self.stats + 1] = stat
    end
    for _, asset in ipairs(slotAssets) do
        Native.load_class(slotRoot .. asset .. '.' .. asset .. '_C')
        local defaults = Native.cdo(slotRoot .. asset .. '.Default__' .. asset .. '_C')
        assert(Native.name(defaults.AccessoryTag.TagName) ~= 'None', Locale.text('原生饰品栏tag无效', 'Native accessory-slot tag is invalid'))
        self.tags[#self.tags + 1] = defaults.AccessoryTag
    end
    self.regeneration = {}
    for _, asset in ipairs({'GE_MemoryFlower_Regen', 'GE_SecondWind_Regen'}) do
        self.regeneration[#self.regeneration + 1] = Native.load_class(effectRoot .. asset .. '.' .. asset .. '_C')
    end
    return self
end

function Fixed:_strip_native_growth()
    -- Only remove known growth templates; skill-owned accessory tags remain intact.
    for _, effect in pairs(self.effects) do
        self.backpack.ActivateGE:Remove(effect.class)
        self.asc:RemoveActiveGameplayEffectBySourceEffect(effect.class, nil, -1)
    end
    for _, effect in ipairs(self.regeneration) do
        self.backpack.ActivateGE:Remove(effect)
        self.asc:RemoveActiveGameplayEffectBySourceEffect(effect, nil, -1)
    end
    for id in pairs(self.inventoryIDs) do self.backpack.Inventories:Remove(FName(id)) end
end

function Fixed:initialize()
    -- Only fresh runs strip initial/preorder slot grants.
    for _, tag in ipairs(self.tags) do self.backpack:RemoveAccessorySlotTag(tag, {}, {}) end
    self:_strip_native_growth()
    for _, stat in ipairs(self.stats) do stat.level = 0 end
end

function Fixed:_increments(stat)
    local result = {}
    for _, modifier in ipairs(stat.effect.modifiers) do
        local magnitude = modifier.ModifierMagnitude
        assert(magnitude.MagnitudeCalculationType == 1 and modifier.ModifierOp == 0, Locale.text('原生永久升级配置类型发生变化', 'Native permanent-upgrade configuration type has changed'))
        local source = magnitude.AttributeBasedMagnitude
        assert(source.AttributeCalculationType == 0 and not Native.valid(source.AttributeCurve.CurveTable),
            Locale.text('原生永久升级属性求值方式发生变化', 'Native permanent-upgrade attribute evaluation has changed'))
        local captured = value(self.player, source.BackingAttribute.AttributeToCapture)
        local delta = scaled(source.Coefficient, 1) * (captured + scaled(source.PreMultiplyAdditiveValue, 1))
            + scaled(source.PostMultiplyAdditiveValue, 1)
        assert(finite(delta) and delta > 0, Locale.text('原生升级增量无效', 'Invalid native upgrade increment'))
        result[#result + 1] = {name = Native.name(modifier.Attribute.AttributeName),
            attribute = modifier.Attribute, delta = delta}
    end
    return result
end

function Fixed:_growth(stat)
    local detail = {}
    for _, increment in ipairs(self:_increments(stat)) do
        detail[#detail + 1] = stat_name(increment.name) .. ' +' .. string.format('%.3g', increment.delta)
    end
    return string.format(Locale.text('%d/%d；', '%d/%d; '), stat.level, maximumLevel) .. table.concat(detail, Locale.text('；', '; ')) .. Locale.text('；不恢复当前资源', '; current resources are not replenished')
end

function Fixed:_bases()
    local result = {}
    for name, attribute in pairs(self.bindings) do
        local base = attribute_data(self.player, attribute).BaseValue
        assert(finite(base), Locale.text('原生升级基础属性无效: ', 'Invalid native upgrade base attribute: ') .. name)
        result[name] = base
    end
    return result
end

function Fixed:_override_bases(bases)
    for name, attribute in pairs(self.bindings) do
        attributes():ModifyCharacterAttributeValue(self.player, attribute, 3, bases[name])
        assert(close(attribute_data(self.player, attribute).BaseValue, bases[name]), Locale.text('原生基础属性恢复失败: ', 'Native base-attribute restoration failed: ') .. name)
    end
end

function Fixed:_transaction(apply, verify, price)
    local wallet = price and Economy.balance(self.player) or nil
    if wallet and wallet < price then return false, Locale.text('金钱不足', 'Insufficient funds') end
    local bases, resources = self:_bases(), Fixed.capture_resources(self.player)
    local ok, message = pcall(function()
        apply()
        Fixed.restore_resources(self.player, resources)
        if verify then verify() end
        if price then
            local charged, reason = Economy.charge(self.player, price)
            assert(charged, reason)
        end
    end)
    if ok then return true end
    -- Attempt every original base even if an individual rollback fails.
    local failures = {}
    for name, attribute in pairs(self.bindings) do
        local restored, reason = pcall(function()
            attributes():ModifyCharacterAttributeValue(self.player, attribute, 3, bases[name])
            assert(close(attribute_data(self.player, attribute).BaseValue, bases[name]), Locale.text('基础属性回滚失败: ', 'Base-attribute rollback failed: ') .. name)
        end)
        if not restored then failures[#failures + 1] = tostring(reason) end
    end
    local restored, reason = pcall(Fixed.restore_resources, self.player, resources)
    if not restored then failures[#failures + 1] = tostring(reason) end
    if wallet then
        local walletRestored, walletError = pcall(Economy.set_balance, self.player, wallet)
        if not walletRestored then failures[#failures + 1] = tostring(walletError) end
    end
    assert(#failures == 0, tostring(message) .. Locale.text('；回滚失败：', '; rollback failed: ') .. table.concat(failures, Locale.text('；', '; ')))
    return false, tostring(message)
end

function Fixed:_medicines()
    local result, seen = {}, {}
    for index = 0, 1 do
        local id = Native.name(self.backpack:GetMedicineByIndex(index))
        if id ~= 'None' and id ~= '' and not seen[id] then
            local info
            self.backpack.MedicineInfos:ForEach(function(key, entry)
                if Native.name(key:get()) == id then info = entry:get() end
            end)
            assert(Native.valid(info), Locale.text('已装备药品没有原生实例: ', 'Equipped medicine has no native instance: ') .. id)
            result[#result + 1] = {id = id, info = info, current = info:GetCurrentTime(), display = info:GetDisplayTime(), maximum = self.backpack:GetMedicineTotalMaxUsage(FName(id))}
            seen[id] = true
        end
    end
    return result
end

function Fixed:prepare_combat_resources()
    -- The native quick-item restore is the game's own refill path: it updates the
    -- equipped counts and fires the medicine UI notifications. Adding amounts alone
    -- leaves the HUD showing the previous charges until another native event.
    self.backpack:RestoreQuickItems()
    for _, item in ipairs(self:_medicines()) do
        local missing = item.maximum - item.info:GetCurrentTime()
        if missing > 0 then self.backpack:AddMedicineAmount(FName(item.id), missing) end
        item.info:SetDisplayTime(item.maximum)
        assert(item.info:GetCurrentTime() == item.maximum, Locale.text('原生药品补充失败: ', 'Native medicine refill failed: ') .. item.id)
    end
    self.backpack:RestoreShaqiWeaponBullet()
    Native.cdo('/Script/ProjectPBZ.Default__PBZRestoreQueryLibrary'):ResetHealthToMax(self.player)
    -- Finish the original bell's restore sequence. Ammo refill alone does not
    -- clear the temporary cooldowns used by equipment revival. The player's
    -- native reset handler clears temporary/status effects and active bullets;
    -- do not emulate revival or call ordinary Respawn (teleport/save/refresh).
    Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary'):SendGameplayEventToActor(
        self.player, {TagName = FName('GameplayEvent.Actor.Player.ResetState')}, {})
end

-- Base-value writes are not guaranteed to refresh the HUD by themselves: the
-- native bars listen for aggregated attribute changes. A zero-magnitude native
-- buff re-evaluates the attribute through GAS and broadcasts that change.
function Fixed:refresh_hud()
    local util = attributes()
    for _, stat in ipairs(self.stats) do
        local attribute = self.bindings[stat.target]
        if attribute ~= nil then
            local called, handle = pcall(util.AddAttributeBuff, util, self.player, attribute, 0, 0.0001, 0)
            if called and handle ~= nil then
                pcall(util.RemoveAttributeBuff, util, self.player, handle)
            end
        end
    end
end

function Fixed:offers(balance)
    local offers = {}
    balance = balance or Economy.balance(self.player)
    for _, stat in ipairs(self.stats) do
        local available = stat.level < maximumLevel
        local price = available and Economy.fixed_price(self.config, stat.id:match('^fixed:(.+)$'), stat.level + 1) or nil
        local affordable = available and balance >= price
        offers[#offers + 1] = {id = stat.id, title = Locale.text(stat.title[1], stat.title[2]), icon = stat.icon, purchaseIndex = stat.level + 1, price = price,
            service = available and string.format(Locale.text('升级 %d/%d → %d/%d', 'Upgrade %d/%d → %d/%d'), stat.level, maximumLevel, stat.level + 1, maximumLevel)
                or string.format(Locale.text('升级 %d/%d · 已满级', 'Upgrade %d/%d · Maxed'), stat.level, maximumLevel),
            detail = self:_growth(stat), enabled = affordable,
            reason = not available and Locale.text('已达到二十次升级上限', 'All twenty upgrades purchased') or (not affordable and Locale.text('金钱不足', 'Insufficient funds') or nil)}
    end
    return offers
end

function Fixed:purchase(id, expectedIndex)
    for _, stat in ipairs(self.stats) do
        if stat.id == id then
            if expectedIndex and expectedIndex ~= stat.level + 1 then return false, Locale.text('固定商品已更新；未扣费', 'Fixed upgrade has changed; no payment taken') end
            if stat.level >= maximumLevel then return false, Locale.text('已达到二十次升级上限', 'All twenty upgrades purchased') end
            local price = Economy.fixed_price(self.config, stat.id:match('^fixed:(.+)$'), stat.level + 1)
            if Economy.balance(self.player) < price then return false, Locale.text('金钱不足', 'Insufficient funds') end
            local increments = self:_increments(stat)
            for _, increment in ipairs(increments) do
                local data = attribute_data(self.player, increment.attribute)
                increment.beforeBase, increment.before = data.BaseValue, data.CurrentValue
            end
            local ok, message = self:_transaction(function()
                for _, increment in ipairs(increments) do
                    attributes():ModifyCharacterAttributeValue(self.player, increment.attribute, 0, increment.delta)
                end
            end, function()
                for _, increment in ipairs(increments) do
                    local data = attribute_data(self.player, increment.attribute)
                    increment.afterBase, increment.after = data.BaseValue, data.CurrentValue
                    assert(close(increment.afterBase, increment.beforeBase + increment.delta)
                        and increment.afterBase > increment.beforeBase, Locale.text('原生升级基础增量不符: ', 'Native upgrade base increment does not match: ') .. increment.name)
                    if increment.name == stat.target then
                        assert(increment.after > increment.before, Locale.text('原生升级未提高目标属性: ', 'Native upgrade did not increase its target attribute: ') .. increment.name)
                    end
                end
            end, price)
            if not ok then return false, message end
            local detail = {}
            for _, increment in ipairs(increments) do
                detail[#detail + 1] = stat_name(increment.name) .. string.format(' %.3g → %.3g', increment.before, increment.after)
            end
            stat.level = stat.level + 1
            self:refresh_hud()
            return true, Locale.text('原生数值升级已生效：', 'Stat upgrade applied: ') .. table.concat(detail, Locale.text('；', '; '))
        end
    end
    return false, Locale.text('不存在的固定商品', 'Unknown fixed upgrade')
end

function Fixed:snapshot()
    local result = {version = snapshotVersion, stats = {}, bases = self:_bases(),
        accessorySlots = self.backpack:GetCanAssembleAccessoryNum()}
    for _, stat in ipairs(self.stats) do result.stats[stat.id] = stat.level end
    return result
end

function Fixed:restore(saved)
    assert(type(saved) == 'table' and type(saved.stats) == 'table', Locale.text('固定升级存档无效', 'Invalid fixed-upgrade save'))
    local legacy = saved.version == nil and type(saved.inventory) == 'table' and type(saved.effects) == 'table'
    assert(legacy or (saved.version == snapshotVersion and type(saved.bases) == 'table'), Locale.text('固定升级存档版本无效', 'Invalid fixed-upgrade save version'))
    assert(self.backpack:GetCanAssembleAccessoryNum() == saved.accessorySlots, Locale.text('原生饰品栏与存档不一致', 'Native accessory slots do not match the save'))
    local levels = {}
    for _, stat in ipairs(self.stats) do
        local level = saved.stats[stat.id]
        assert(finite(level) and level >= 0 and level % 1 == 0, Locale.text('固定升级购买次数存档无效', 'Invalid saved fixed-upgrade purchase count'))
        assert(legacy or level <= maximumLevel, Locale.text('固定升级购买次数超过二十次', 'Fixed-upgrade purchase count exceeds twenty'))
        levels[stat.id] = math.min(level, maximumLevel)
    end
    if not legacy then
        for name in pairs(self.bindings) do
            assert(finite(saved.bases[name]), Locale.text('固定升级基础属性存档无效: ', 'Invalid saved fixed-upgrade base attribute: ') .. name)
        end
    end
    local bases = saved.bases
    local ok, message = self:_transaction(function()
        self:_strip_native_growth()
        if legacy then
            -- Old growth GEs are infinite modifiers, not base changes. Native load
            -- does not restore these five bases; retain the unbuffed native baseline.
            -- Cache it so retrying the same legacy restore never adds growth twice.
            self.legacyBases = self.legacyBases or self:_bases()
            bases = {}
            for name, base in pairs(self.legacyBases) do bases[name] = base end
            for _, stat in ipairs(self.stats) do
                for _, increment in ipairs(self:_increments(stat)) do
                    bases[increment.name] = bases[increment.name] + increment.delta * levels[stat.id]
                end
            end
        end
        self:_override_bases(bases)
    end, function()
        for name, attribute in pairs(self.bindings) do
            assert(close(attribute_data(self.player, attribute).BaseValue, bases[name]), Locale.text('固定升级读档基础属性不符: ', 'Restored fixed-upgrade base attribute does not match: ') .. name)
        end
        assert(self.backpack:GetCanAssembleAccessoryNum() == saved.accessorySlots, Locale.text('固定升级读档改变了饰品栏', 'Restoring fixed upgrades changed accessory slots'))
    end)
    assert(ok, message)
    for _, stat in ipairs(self.stats) do stat.level = levels[stat.id] end
    if legacy then
        -- One-way conversion; the next save also emits only the versioned base snapshot.
        saved.version, saved.stats, saved.bases = snapshotVersion, levels, bases
        saved.inventory, saved.effects = nil, nil
    end
end

return Fixed
