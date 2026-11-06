local Native = require('Native')
local Locale = require('Locale')
local English = require('EnglishNames')
local SlotState = require('SlotState')
local FixedUpgrades = require('FixedUpgrades')
local Economy = require('Economy')
local Equipment = {}
Equipment.__index = Equipment

local maps = {weapons = 'MainWeaponInfos', shadow = 'ShaqiWeaponInfos', medicine = 'MedicineInfos', accessory = 'Accessories'}
local levels = {weapons = 'WeaponLevel', shadow = 'ShaChiWeaponLevel', medicine = 'CurrentLevel', accessory = 'CurrentLevel'}
local titles = {weapons = {'武器', 'Weapons'}, shadow = {'影之武装', 'Phantom Edges'},
    medicine = {'药品', 'Medicine'}, accessory = {'饰品', 'Accessories'}, supplies = {'饰品／药品', 'Accessories / Medicine'}}
local groups = {'weapons', 'shadow', 'medicine', 'accessory'}
local function weapon(kind) return kind == 'weapons' or kind == 'shadow' end
local function baseline(kind) return weapon(kind) and 1 or 0 end
local function present(id) return id and id ~= '' and id ~= 'None' end
local function same_id(left, right)
    return left ~= nil and right ~= nil and left:lower() == right:lower()
end
local function lookup(map, id)
    local found
    map:ForEach(function(key, value)
        if same_id(Native.name(key:get()), id) then found = value:get() end
    end)
    return found
end

function Equipment.new(backpack, player, config, rng)
    assert(Native.valid(backpack) and Native.valid(player), Locale.text('装备系统需要有效原生背包和玩家', 'Equipment requires a valid native inventory and player'))
    return setmetatable({backpack = backpack, player = player, config = config, rng = rng,
        slots = {}, offers = {}, icons = {}, serial = 0, fixed = FixedUpgrades.new(backpack, player, config)}, Equipment)
end

function Equipment:_info(kind, id)
    return lookup(self.backpack[maps[kind]], id)
end

function Equipment:_data(kind, id)
    local b, name = self.backpack, FName(id)
    -- Validate against the concrete equipment table, not the generic shop-item predicate.
    if kind == 'weapons' then return b:GetMainWeaponTableData(name) end
    if kind == 'shadow' then return b:GetShaqiWeaponTableData(name) end
    if kind == 'medicine' then return b:GetMedicineData(name) end
    return b:GetAccessoryData(name)
end

function Equipment:_icon(kind, id, soul)
    local key = kind .. ':' .. id:lower() .. (soul and ':soul' or ':base')
    if self.icons[key] then return self.icons[key] end
    local data, reference = self:_data(kind, id)
    local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
    if weapon(kind) then
        -- Native UIHelper.getWeaponRenderIcon uses RenderIcon, including soul art.
        reference = data.RenderIcon
        if soul then
            local snapped = kind == 'weapons' and data.WeaponSnapSoulData or data.ShaChiWeaponSnapSoulData
            if system:IsValidSoftObjectReference(snapped.RenderIcon) then reference = snapped.RenderIcon end
        end
    elseif kind == 'medicine' then
        -- Native ShopWidget uses the medicine's item-specific soft texture.
        reference = data.SoftTexture
    else
        -- Native UIHelper.getAccessoryRenderIcon uses item-specific render art;
        -- Icon is shared placeholder art for many otherwise unrelated accessories.
        reference = data.HighPrecisionTexture
    end
    assert(system:IsValidSoftObjectReference(reference), Locale.text('原生商品缺少图标: ', 'Native item has no icon: ') .. kind .. ':' .. id)
    local path = Native.name(system:Conv_SoftObjectReferenceToString(reference))
    self.icons[key] = path
    return path
end

function Equipment:_weapon_config(kind, id, soul)
    local data = self:_data(kind, id)
    local reference = data.WeaponConfig
    local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
    if soul then
        local snapped = kind == 'weapons' and data.WeaponSnapSoulData or data.ShaChiWeaponSnapSoulData
        if system:IsValidSoftObjectReference(snapped.WeaponConfig) then reference = snapped.WeaponConfig end
    end
    return Native.load_object(Native.name(system:Conv_SoftObjectReferenceToString(reference)))
end

function Equipment:_player_shadow(id)
    if not self.player_shadow then
        local allowed, configs = {}, {}
        for _, candidate in ipairs(self.config.items.pools.shadow) do
            local data = self:_data('shadow', candidate)
            assert(same_id(Native.name(data.ItemId), candidate), Locale.text('影之武装分类错误: ', 'Invalid Phantom Edge category: ') .. candidate)
            local config = self:_weapon_config('shadow', candidate, false)
            -- Ability-driven subweapons need no persistent weapon actor.
            local playable = config:IsA(self.config.items.shadow_catalog.config_class)
                and #Native.array(config['Equip Abilities']) > 0
            -- The native table contains unfinished aliases sharing JinGua's config.
            -- Only the curated original item for a concrete player config is offered.
            local address = config:GetAddress()
            if playable and not configs[address] then
                allowed[candidate:lower()], configs[address] = true, true
            end
        end
        self.player_shadow = allowed
    end
    return self.player_shadow[id:lower()] == true
end

function Equipment:_cap(kind, id)
    local b, name = self.backpack, FName(id)
    if weapon(kind) then return b:GetWeaponMaxLevel(name, kind == 'weapons') end
    if kind == 'medicine' then return b:GetMedicineMaxLevel(name) end
    return b:GetAccessoryMaxRefineLevel(name)
end

function Equipment:_name(kind, id)
    if Locale.is_chinese() and kind ~= 'accessory' then
        local name = self.config.items.names[id]
        assert(name, '装备缺少中文显示名称: ' .. id)
        return name
    end
    local data = self:_data(kind, id)
    if not Locale.is_chinese() then
        local label = weapon(kind) and data.WeaponName or (kind == 'medicine' and data.Name or data.AccessoryName)
        return English.get(Native.name(label.Key))
    end
    local text = Native.cdo('/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary'):MakeTextByKey(data.AccessoryName.Key)
    local name = Native.name(Native.cdo('/Script/Engine.Default__KismetTextLibrary'):Conv_TextToString(text))
    assert(name ~= '' and not same_id(name, id), Locale.text('饰品缺少原生显示名称: ', 'Accessory has no native display name: ') .. id)
    return name
end

-- Pass scalar preview data to the game's own description widgets. Never flatten
-- native rich text: its decorators provide stat icons, colors and input glyphs.
local function item_tooltip(self, offer, bound, soul)
    local kind, id = offer.kind, offer.item
    local level = bound and offer.slot.state:effective_level(self:_cap(kind, id)) or baseline(kind)
    if bound and offer.action == 'upgrade' and not offer.sold then level = offer.targetLevel end
    return {kind = kind, item = id, level = level, soul = soul == true,
        side = weapon(kind) and 'right' or 'left'}
end

function Equipment:_equipped(kind, index)
    local b = self.backpack
    if kind == 'medicine' then return Native.name(b:GetMedicineByIndex(index)) end
    if kind == 'accessory' then return Native.name(b:GetAccessoryID(index)) end
    local list = Native.array(kind == 'weapons' and b.MainWeapons or b.ShaqiWeapons)
    return list[index + 1] and Native.name(list[index + 1]) or 'None'
end

function Equipment:_weapon_actors(kind, index)
    local actors = {}
    local tag = kind == 'weapons' and 'Weapon.Slot.Main' or 'Weapon.Slot.ShaChi'
    self.player['Character Weapons Component'].RuntimeWeaponData:ForEach(function(key, value)
        if same_id(Native.name(key:get().TagName), tag) then
            local slot = Native.array(value:get().Weapons)[index + 1]
            if slot then actors = Native.array(slot.WeaponActors) end
        end
    end)
    return actors
end

function Equipment:_unequip_weapon(kind, id)
    for index = 0, 1 do
        if same_id(self:_equipped(kind, index), id) then
            -- RemoveWeaponByID is an UNEQUIP operation, not inventory disposal.
            -- Its native callback cancels the slot's pending config load and calls
            -- the player's UnRegisterWeapon -> SetSlotWeapon(tag, index, null).
            self.backpack:RemoveWeaponByID(FName(id), kind == 'weapons')
            assert(not present(self:_equipped(kind, index)), Locale.text('原生武器栏卸下失败: ', 'Failed to unequip native weapon slot: ') .. id)
            assert(#self:_weapon_actors(kind, index) == 0, Locale.text('原生旧武器实体未卸下: ', 'Previous native weapon actor was not removed: ') .. id)
        end
    end
end

function Equipment:_dispose_weapon(kind, id)
    self:_unequip_weapon(kind, id)
    -- DisposeWeapon runs native cleanup and erases the owning
    -- MainWeaponInfos/ShaqiWeaponInfos entry; RemoveWeaponByID never does.
    self.backpack:DisposeWeapon(FName(id), kind == 'weapons')
    assert(not Native.valid(self:_info(kind, id)), Locale.text('原生武器所有权未删除: ', 'Native weapon ownership was not removed: ') .. id)
    for index = 0, 1 do
        assert(not same_id(self:_equipped(kind, index), id), Locale.text('原生已删除武器仍在装备栏: ', 'Removed native weapon remains equipped: ') .. id)
    end
end

function Equipment:_other_weapons(changed)
    local result = {}
    for _, slot in ipairs(self.slots) do
        if weapon(slot.kind) and slot.key ~= changed.key then
            result[#result + 1] = {kind = slot.kind, index = slot.index,
                id = self:_equipped(slot.kind, slot.index), state = slot.id and self:_state(slot.kind, slot.id),
                actors = self:_weapon_actors(slot.kind, slot.index)}
        end
    end
    return result
end

function Equipment:_assert_other_weapons(saved)
    for _, slot in ipairs(saved) do
        assert(same_id(self:_equipped(slot.kind, slot.index), slot.id), Locale.text('交易修改了其他武器栏', 'Transaction changed another weapon slot'))
        if slot.state then
            local current = self:_state(slot.kind, slot.id)
            assert(current.level == slot.state.level and current.soul == slot.state.soul, Locale.text('交易修改了其他武器强化', 'Transaction changed another weapon upgrade'))
        end
        local actors = self:_weapon_actors(slot.kind, slot.index)
        assert(#actors == #slot.actors, Locale.text('交易修改了其他武器实体', 'Transaction changed another weapon actor'))
        for index, actor in ipairs(actors) do
            assert(Native.same(actor, slot.actors[index]), Locale.text('交易替换了其他武器实体', 'Transaction replaced another weapon actor'))
        end
    end
end

function Equipment:_equip(kind, id, index)
    local b, name = self.backpack, FName(id)
    if weapon(kind) then
        self:_weapon_config(kind, id, self:_state(kind, id).soul)
        local previous = self:_equipped(kind, index)
        if present(previous) and not same_id(previous, id) then self:_unequip_weapon(kind, previous) end
    end
    if kind == 'weapons' then b:ReplaceWeaponByIndex(name, index)
    elseif kind == 'shadow' then b:ReplaceShaChiWeaponByIndex(name, index)
    elseif kind == 'medicine' then b:ReplaceMedicineByIndex(index, name, false)
    else b:AssembleAccessory(name, index) end
    assert(same_id(self:_equipped(kind, index), id), Locale.text('原生装备栏未接受 ', 'Native equipment slot rejected ') .. id)
end

function Equipment:_obtain(kind, id)
    local b, name = self.backpack, FName(id)
    if not Native.valid(self:_info(kind, id)) then
        if weapon(kind) then b:AddWeaponItem(name, kind == 'weapons', false, false, false)
        elseif kind == 'medicine' then b:PushMedicineToInventory(name, false, false)
        else
            b:PushAccessoryToInventory(name, false)
            -- Equipment is assigned by this mode, not by the native pickup/replacement prompt.
            b:DeactivatePickupWidget()
            b:ResetPickupItem()
        end
    end
    return assert(Native.valid(self:_info(kind, id)) and self:_info(kind, id), Locale.text('原生物品未创建: ', 'Native item was not created: ') .. id)
end

function Equipment:_soul_compatible(kind, id)
    if not weapon(kind) or id:lower() == 'woodenswordhun' then return false end
    local data = self:_data(kind, id)
    local soul = kind == 'weapons' and data.WeaponSnapSoulData or data.ShaChiWeaponSnapSoulData
    return Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):IsValidSoftObjectReference(soul.WeaponConfig)
        or #Native.array(soul.GameplayEffectDatas) > 0 or #Native.array(soul.PersistentGEDatas) > 0
end

function Equipment:_upgrade(kind, id, amount)
    local b, name = self.backpack, FName(id)
    -- Replay every native weapon level so intermediate effects are applied as in the native UI.
    if weapon(kind) then
        local before = self:_state(kind, id)
        for step = 1, amount do
            b:UpgradeWeapon(name, kind == 'weapons', 1)
            local actual = self:_state(kind, id)
            assert(actual.level == before.level + step and actual.soul == before.soul,
                Locale.text('原生武器升级未逐级生效或改变了铸魂: ', 'Native weapon upgrade skipped a level or changed Soul Tempering: ') .. id)
        end
    elseif kind == 'medicine' then b:UpgradeMedicine(name, amount)
    else b:UpgradeAccessory(name, amount) end
end

function Equipment:_state(kind, id)
    local info = self:_info(kind, id)
    assert(Native.valid(info), Locale.text('原生物品实例丢失: ', 'Native item instance is missing: ') .. id)
    return {level = info[levels[kind]], soul = weapon(kind) and info.bAlreadySnapSoul or false,
        count = kind == 'medicine' and info:GetCurrentTime() or nil,
        display = kind == 'medicine' and info:GetDisplayTime() or nil}
end

function Equipment:_restore_item(kind, id, state)
    if weapon(kind) then self:_dispose_weapon(kind, id) end
    local info = self:_obtain(kind, id)
    info[levels[kind]] = baseline(kind)
    if weapon(kind) then info.bAlreadySnapSoul = false end
    if state.level > baseline(kind) then self:_upgrade(kind, id, state.level - baseline(kind)) end
    if state.soul then self.backpack:SnapSoulWeapon(FName(id), kind == 'weapons') end
    if kind == 'medicine' then
        info:SetCurrentTime(state.count)
        info:SetDisplayTime(state.display)
    end
    local actual = self:_state(kind, id)
    assert(actual.level == state.level and actual.soul == state.soul, Locale.text('原生物品强化回滚不完整: ', 'Native item upgrade rollback is incomplete: ') .. id)
end

function Equipment:_resources()
    local b = self.backpack
    local snapshot = {native = FixedUpgrades.capture_resources(self.player), medicine = {}, bullets = {},
        selected = b.CurrentShaqiWeaponIndex, mainSelected = b.CurrentWeaponIndex,
        ultimate = b.CurrentUltimateCharge, percentage = b.UltimateChargePercentage}
    for arrayIndex, id in ipairs(Native.array(b.ShaqiWeapons)) do
        local name = Native.name(id)
        if present(name) then
            local count = {}
            local hasBullets = b:GetShaChiWeaponBulletNum(id, count)
            snapshot.bullets[#snapshot.bullets + 1] = {id = name, index = arrayIndex - 1, count = hasBullets and count.BulletNum or 0}
        end
    end
    b.MedicineInfos:ForEach(function(key, value)
        local info = value:get()
        snapshot.medicine[Native.name(key:get()):lower()] = {count = info:GetCurrentTime(), display = info:GetDisplayTime()}
    end)
    return snapshot
end

function Equipment:_restore_resources(snapshot, changed, replacement)
    local b = self.backpack
    for id, saved in pairs(snapshot.medicine) do
        local info = self:_info('medicine', id)
        if Native.valid(info) then
            info:SetCurrentTime(math.min(saved.count, b:GetMedicineTotalMaxUsage(FName(id))))
            info:SetDisplayTime(math.min(saved.display, b:GetMedicineTotalMaxUsage(FName(id))))
        end
    end
    if changed and changed.kind == 'medicine' then
        local old = changed.id and snapshot.medicine[changed.id:lower()] or nil
        local info = self:_info('medicine', replacement)
        info:SetCurrentTime(math.min(old and old.count or 0, b:GetMedicineTotalMaxUsage(FName(replacement))))
        info:SetDisplayTime(info:GetCurrentTime())
    end
    for _, saved in ipairs(snapshot.bullets) do
        local id = changed and changed.kind == 'shadow' and changed.index == saved.index and replacement or saved.id
        b:SetCurrentWeaponByIndex(saved.index, false)
        local now = b:GetCurrentShaqiWeaponBulletNum()
        if now > saved.count then b:UseShaqiWeapon(now - saved.count)
        elseif now < saved.count then b:AddShaChiWeaponBullet(FName(id), saved.count - now) end
        assert(b:GetCurrentShaqiWeaponBulletNum() <= saved.count, Locale.text('影之武装操作意外补充资源', 'Phantom Edge operation unexpectedly replenished resources'))
    end
    if present(self:_equipped('shadow', snapshot.selected)) then b:SetCurrentWeaponByIndex(snapshot.selected, false) end
    if changed and changed.kind == 'shadow' and not changed.id then
        b:SetCurrentWeaponByIndex(changed.index, false)
        local granted = b:GetCurrentShaqiWeaponBulletNum()
        if granted > 0 then b:UseShaqiWeapon(granted) end
        assert(b:GetCurrentShaqiWeaponBulletNum() == 0, Locale.text('空栏购买影之武装意外补充弹药', 'Buying a Phantom Edge for an empty slot unexpectedly replenished ammunition'))
        if present(self:_equipped('shadow', snapshot.selected)) then b:SetCurrentWeaponByIndex(snapshot.selected, false) end
    end
    if snapshot.mainSelected ~= nil and present(self:_equipped('weapons', snapshot.mainSelected)) then
        b:SetCurrentWeaponByIndex(snapshot.mainSelected, true)
    end
    b.CurrentUltimateCharge = snapshot.ultimate
    b:ChangeUltimatePercentage(snapshot.percentage)
    FixedUpgrades.restore_resources(self.player, snapshot.native)
end

function Equipment:_new_slot(kind, index, id, state)
    self.serial = self.serial + 1
    local slot = {kind = kind, index = index, id = id, key = kind .. ':' .. index, instance = self.serial,
        state = state or SlotState.new(baseline(kind), false)}
    self.slots[#self.slots + 1] = slot
    return slot
end

function Equipment:initialize()
    assert(not self.initialized, Locale.text('装备已经初始化', 'Equipment is already initialized'))
    local initial, b = self.config.items.initial, self.backpack
    assert(#initial.weapons == 2, Locale.text('开局必须配置两把武器', 'Starting equipment must contain two weapons'))
    for _, kind in ipairs(groups) do
        assert(type(initial[kind]) == 'table' and type(self.config.items.pools[kind]) == 'table', Locale.text('缺少装备配置: ', 'Missing equipment configuration: ') .. kind)
        for _, id in ipairs(initial[kind]) do
            assert(same_id(Native.name(self:_data(kind, id).ItemId), id), Locale.text('装备分类与ItemId不符: ', 'Equipment category does not match ItemId: ') .. id)
        end
    end
    -- Unequip first: entitlement accessories must lose their granted effects, not merely disappear from a Lua list.
    for index = 0, #Native.array(b.AssemblyAccessory) - 1 do b:TakeOffAccessory(index) end
    b:TakeOffMedicineByIndex(0)
    b:TakeOffMedicineByIndex(1)
    for _, id in ipairs(Native.array(b:GetAllMedicines())) do b:DisposeMedicine(id) end
    b.MedicineInfos:Empty()
    b.Accessories:Empty()
    local initialProps = {}
    b.Inventories:ForEach(function(key, entry)
        initialProps[#initialProps + 1] = {id = key:get(), count = entry:get().CurrentAmount}
    end)
    for _, prop in ipairs(initialProps) do
        if prop.count > 0 then b:RemovePropsFromBackPack(prop.count, prop.id, false) end
    end
    for _, kind in ipairs({'weapons', 'shadow'}) do
        local owned = {}
        b[maps[kind]]:ForEach(function(key) owned[#owned + 1] = Native.name(key:get()) end)
        for _, id in ipairs(owned) do self:_dispose_weapon(kind, id) end
        -- Keep two legal native targets even when this category starts empty.
        if kind == 'weapons' then b.MainWeapons = {FName('None'), FName('None')}
        else b.ShaqiWeapons = {FName('None'), FName('None')} end
    end
    b:RemoveMedicineExtraUsage(b:GetMedicineExtraUsage())
    self.fixed:initialize()
    assert(#initial.accessory <= b:GetCanAssembleAccessoryNum(), Locale.text('初始饰品超过原生可用栏位', 'Starting accessories exceed available native slots'))
    for _, kind in ipairs(groups) do
        for index, id in ipairs(initial[kind]) do
            local info = self:_obtain(kind, id)
            info[levels[kind]] = baseline(kind)
            if weapon(kind) then info.bAlreadySnapSoul = false end
            self:_equip(kind, id, index - 1)
            local actual = self:_state(kind, id)
            assert(actual.level == baseline(kind) and not actual.soul, Locale.text('初始配装带入了额外强化', 'Starting equipment contains extra upgrades'))
            self:_new_slot(kind, index - 1, id)
        end
    end
    for index = #initial.shadow, 1 do self:_new_slot('shadow', index, nil) end
    for index = #initial.accessory, b:GetCanAssembleAccessoryNum() - 1 do self:_new_slot('accessory', index, nil) end
    for index = #initial.medicine, 1 do self:_new_slot('medicine', index, nil) end
    -- Starting resources are native defaults. Subsequent upgrades/replacements never refill them.
    for _, id in ipairs(initial.medicine) do
        local info = self:_info('medicine', id)
        info:SetCurrentTime(b:GetMedicineTotalMaxUsage(FName(id)))
        info:SetDisplayTime(info:GetCurrentTime())
    end
    b:RestoreShaqiWeaponBullet()
    for _, slot in ipairs(self.slots) do assert(self:_valid_slot(slot), Locale.text('初始原生装备栏与模式配装不一致: ', 'Starting native equipment does not match mode loadout: ') .. slot.key) end
    assert(#Native.array(b:GetAllShaqiWeapons()) == #initial.shadow, Locale.text('初始影之武装背包未清空', 'Starting Phantom Edge inventory was not cleared'))
    self.initialized = true
    return true
end

function Equipment:sync_accessory_slots()
    local count, existing = self.backpack:GetCanAssembleAccessoryNum(), {}
    for _, slot in ipairs(self.slots) do
        if slot.kind == 'accessory' then
            existing[slot.index] = true
            local id = slot.index < count and self:_equipped('accessory', slot.index) or 'None'
            assert(not present(id) or same_id(id, slot.id), Locale.text('修行后原生饰品栏出现未登记的装备', 'Unregistered accessory appeared after Training'))
            if slot.id and not present(id) then
                self.serial = self.serial + 1
                slot.id, slot.instance = nil, self.serial
            end
        end
    end
    for index = 0, count - 1 do
        if not existing[index] then
            assert(not present(self:_equipped('accessory', index)), Locale.text('新解锁的饰品栏不是空栏', 'Newly unlocked accessory slot is not empty'))
            self:_new_slot('accessory', index, nil)
        end
    end
end

function Equipment:_valid_slot(slot)
    if slot.kind == 'accessory' and slot.index >= self.backpack:GetCanAssembleAccessoryNum() then
        return slot.id == nil
    end
    if not slot.id then return not present(self:_equipped(slot.kind, slot.index)) end
    if not same_id(self:_equipped(slot.kind, slot.index), slot.id) then return false end
    local current = self:_state(slot.kind, slot.id)
    return current.level == slot.state:effective_level(self:_cap(slot.kind, slot.id)) and current.soul == slot.state.snapSoul
end

function Equipment:_upgrade_target(slot)
    local cap = self:_cap(slot.kind, slot.id)
    if weapon(slot.kind) then return slot.state:next_weapon_level(cap, slot.kind) end
    if slot.state.level < cap then return slot.state:effective_level(cap) + 1 end
end

function Equipment:_targets(kind, id)
    local result = {}
    if kind == 'shadow' and not self:_player_shadow(id) then return result end
    -- Native DT_Accessory also contains rows with no display-name key.
    -- They are catalog entries, not usable shop items; reject before building labels.
    if kind == 'accessory' and not present(Native.name(self:_data(kind, id).AccessoryName.Key)) then return result end
    for _, slot in ipairs(self.slots) do
        if slot.kind == kind and same_id(slot.id, id) then return result end
    end
    local cap = self:_cap(kind, id)
    local accessory_count = kind == 'accessory' and self.backpack:GetCanAssembleAccessoryNum() or 0
    for _, slot in ipairs(self.slots) do
        if slot.kind == kind and (kind ~= 'accessory' or slot.index < accessory_count)
            and self:_valid_slot(slot) then
            result[#result + 1] = {key = slot.key, title = string.format(Locale.text('%d号栏：%s', 'Slot %d: %s'), slot.index + 1, slot.id and self:_name(kind, slot.id) or Locale.text('空', 'Empty')),
                detail = string.format(Locale.text('%s → %s；栏位等级 %d → 实际 %d（原生上限 %d）%s', '%s → %s; slot level %d → effective %d (native cap %d)%s'), slot.id and self:_name(kind, slot.id) or Locale.text('空', 'Empty'), self:_name(kind, id), slot.state.level, slot.state:effective_level(cap), cap, weapon(kind) and Locale.text('；新装备不继承铸魂', '; replacement does not inherit Soul Tempering') or '')}
        end
    end
    return result
end

function Equipment:_candidates(kind, action)
    local rows = {}
    if action == 'replace' then
        for _, id in ipairs(self.config.items.pools[kind]) do
            assert(same_id(Native.name(self:_data(kind, id).ItemId), id), Locale.text('候选物品分类错误: ', 'Invalid candidate item category: ') .. id)
            if #self:_targets(kind, id) > 0 then rows[#rows + 1] = {kind = kind, action = action, item = id} end
        end
    else
        for _, slot in ipairs(self.slots) do
            if slot.kind == kind and slot.id and self:_valid_slot(slot) then
                local legal = action == 'upgrade' and self:_upgrade_target(slot) ~= nil
                if action == 'soul' then legal = not slot.state.snapSoul and self:_soul_compatible(kind, slot.id) and not (kind == 'shadow' and slot.id == 'CuiXinPiPa') end
                if legal then rows[#rows + 1] = {kind = kind, action = action, item = slot.id, slot = slot, instance = slot.instance} end
            end
        end
    end
    return rows
end

function Equipment:_shop_floor()
    return self.floor == 1 and self.wave == 0 and 0 or self.floor
end

function Equipment:_price(offer)
    if offer.action == 'upgrade' and not offer.sold and offer.slot
        and offer.slot.instance == offer.instance and same_id(offer.slot.id, offer.item) then
        offer.targetLevel = self:_upgrade_target(offer.slot) or offer.targetLevel
    end
    return Economy.price(self.config, offer.kind, offer.action, offer.item, offer.targetLevel)
end

function Equipment:_availability(offer)
    if offer.sold then return false, Locale.text('已售罄', 'Sold out') end
    if offer.action == 'replace' then
        if weapon(offer.kind) and not Economy.has_candidates(self.config, offer.kind, self:_shop_floor(), {offer}) then
            return false, Locale.text('当前楼层不出售此档位装备', 'This equipment tier is not sold on this floor')
        end
        offer.targets = self:_targets(offer.kind, offer.item)
        return #offer.targets > 0, Locale.text('没有兼容的替换栏位', 'No compatible replacement slot')
    end
    local slot = offer.slot
    if slot.instance ~= offer.instance or not same_id(slot.id, offer.item) or not self:_valid_slot(slot) then return false, Locale.text('原装备实例已更换或原生装备已改变', 'Original item was replaced or native equipment changed') end
    if offer.action == 'upgrade' then
        return self:_upgrade_target(slot) ~= nil, weapon(slot.kind) and Locale.text('已达到 30 级或当前物品原生上限', 'Level 30 or native item cap reached') or Locale.text('已达到当前物品原生上限', 'Native item cap reached')
    end
    return not slot.state.snapSoul and self:_soul_compatible(slot.kind, slot.id), Locale.text('无法再次铸魂', 'Cannot Soul Temper again')
end

function Equipment:_gm_slot_count(kind)
    if kind == 'accessory' then return self.backpack:GetCanAssembleAccessoryNum() end
    if kind == 'medicine' then return 2 end
    return math.min(2, #Native.array(kind == 'weapons' and self.backpack.MainWeapons or self.backpack.ShaqiWeapons))
end

-- Catalog eligibility is independent of current ownership and shop tiers.
-- Keep native table/config lookups out of the GM status polling path.
function Equipment:gm_catalog()
    local chinese = Locale.is_chinese()
    if self.gmCatalog and self.gmCatalogChinese == chinese then return self.gmCatalog end
    local catalog, byId = {}, {}
    for _, kind in ipairs(groups) do
        catalog[kind], byId[kind] = {}, {}
        for _, id in ipairs(self.config.items.pools[kind]) do
            local data = self:_data(kind, id)
            local supported = same_id(Native.name(data.ItemId), id)
                and (kind ~= 'shadow' or self:_player_shadow(id))
                and (kind ~= 'accessory' or present(Native.name(data.AccessoryName.Key)))
            if supported and not byId[kind][id] then
                local cap = self:_cap(kind, id)
                assert(type(cap) == 'number' and cap % 1 == 0 and cap >= baseline(kind) and cap < math.huge,
                    Locale.text('原生装备等级上限无效: ', 'Invalid native equipment level cap: ') .. id)
                local row = {id = id, name = self:_name(kind, id), minLevel = baseline(kind),
                    maxLevel = cap, soulSupported = self:_soul_compatible(kind, id)}
                catalog[kind][#catalog[kind] + 1], byId[kind][id] = row, row
            end
        end
    end
    self.gmCatalog, self.gmCatalogById, self.gmCatalogChinese = catalog, byId, chinese
    return catalog
end

function Equipment:gm_slots()
    if not self.initialized then return {} end
    if not self.busy then self:sync_accessory_slots() end
    self:gm_catalog()
    local result = {}
    for _, kind in ipairs(groups) do
        for index = 0, self:_gm_slot_count(kind) - 1 do
            local id = self:_equipped(kind, index)
            local state = present(id) and self:_state(kind, id) or {level = baseline(kind), soul = false}
            local row = present(id) and self.gmCatalogById[kind][id] or nil
            result[#result + 1] = {kind = kind, slot = index + 1, id = present(id) and id or '',
                name = present(id) and (row and row.name or self:_name(kind, id)) or '',
                level = state.level, soul = state.soul}
        end
    end
    return result
end

function Equipment:_gm_unequip(kind, index)
    local id = self:_equipped(kind, index)
    if not present(id) then return end
    if weapon(kind) then self:_unequip_weapon(kind, id)
    elseif kind == 'medicine' then self.backpack:TakeOffMedicineByIndex(index)
    else self.backpack:TakeOffAccessory(index) end
    assert(not present(self:_equipped(kind, index)),
        Locale.text('原生装备栏卸下失败', 'Failed to unequip native equipment slot'))
end

function Equipment:gm_replace(request)
    local slot, kind, id, oldId, oldState, itemBefore, created, resources, otherWeapons, wallet, saved
    -- Every fallible read/config load precedes native mutation. Bad commands and
    -- stale native/mode state are recoverable failures, not fatal run errors.
    local ready, reason = pcall(function()
        assert(self.initialized and not self.busy,
            Locale.text('装备尚未初始化或交易正在处理', 'Equipment is not initialized or a transaction is in progress'))
        assert(type(request) == 'table', Locale.text('装备请求无效', 'Invalid equipment request'))
        kind, id = request.kind, request.item
        assert(type(kind) == 'string' and maps[kind] and type(id) == 'string',
            Locale.text('装备种类或物品无效', 'Invalid equipment kind or item'))
        self:gm_catalog()
        local row = assert(self.gmCatalogById[kind][id],
            Locale.text('物品不在可用装备目录中', 'Item is not in the supported equipment catalog'))
        assert(type(request.level) == 'number' and request.level % 1 == 0
            and request.level >= row.minLevel and request.level <= row.maxLevel
            and request.level <= self:_cap(kind, id),
            Locale.text('等级必须在原生上下限内且为整数', 'Level must be an integer within the native bounds'))
        assert(type(request.soul) == 'boolean' and (not request.soul or row.soulSupported),
            Locale.text('此装备不支持所请求的铸魂状态', 'The requested soul state is not supported for this equipment'))
        local count = self:_gm_slot_count(kind)
        assert(type(request.slot) == 'number' and request.slot % 1 == 0 and request.slot >= 1 and request.slot <= count,
            Locale.text('目标栏位必须是可用的原生栏位（从 1 开始）', 'Target must be a usable native slot (numbered from 1)'))
        for index = 0, count - 1 do
            assert(index == request.slot - 1 or not same_id(self:_equipped(kind, index), id),
                Locale.text('此物品已在同类其他栏位装备；不会移动或复制', 'Item is equipped in another slot of this kind; it will not be moved or duplicated'))
        end
        self:sync_accessory_slots()
        for _, candidate in ipairs(self.slots) do
            assert(self:_valid_slot(candidate),
                Locale.text('原生装备与模式栏位不一致: ', 'Native equipment does not match its mode slot: ') .. candidate.key)
            if candidate.kind == kind and candidate.index == request.slot - 1 then slot = candidate end
            assert(candidate.kind ~= kind or candidate.index == request.slot - 1 or not same_id(candidate.id, id),
                Locale.text('物品已绑定其他栏位', 'Item is already bound to another slot'))
        end
        assert(slot, Locale.text('目标栏位未登记', 'Target slot is not registered'))
        -- Resolve the requested and original configs while rollback is still unnecessary.
        if weapon(kind) then self:_weapon_config(kind, id, request.soul) end
        oldId = slot.id
        oldState = oldId and self:_state(kind, oldId) or nil
        created = not Native.valid(self:_info(kind, id))
        itemBefore = not created and self:_state(kind, id) or nil
        if weapon(kind) then
            if oldState then self:_weapon_config(kind, oldId, oldState.soul) end
            if itemBefore then self:_weapon_config(kind, id, itemBefore.soul) end
        end
        resources, otherWeapons, wallet = self:_resources(), self:_other_weapons(slot), Economy.balance(self.player)
        saved = {id = slot.id, instance = slot.instance, state = slot.state, serial = self.serial}
    end)
    if not ready then return false, tostring(reason) end

    self.busy = true
    local oldDisposed = false
    local ok, message = pcall(function()
        -- Native supply unequip must see the OLD level, so it can remove exactly
        -- the effects it granted. Resetting CurrentLevel while still equipped
        -- leaves old effects behind on same-item downgrades/reapplication.
        self:_gm_unequip(kind, slot.index)
        self:_restore_item(kind, id, {level = request.level, soul = request.soul,
            count = itemBefore and itemBefore.count or 0, display = itemBefore and itemBefore.display or 0})
        self:_equip(kind, id, slot.index)
        if oldId and not same_id(oldId, id) and weapon(kind) then
            oldDisposed = true
            self:_dispose_weapon(kind, oldId)
        end
        self:_restore_resources(resources, slot, id)
        self:_assert_other_weapons(otherWeapons)
        for _, other in ipairs(self.slots) do
            if other ~= slot then
                assert(self:_valid_slot(other),
                    Locale.text('GM 替换修改了其他装备栏', 'GM replacement changed another equipment slot'))
            end
        end
        local actual = self:_state(kind, id)
        assert(same_id(self:_equipped(kind, slot.index), id)
            and actual.level == request.level and actual.soul == request.soul,
            Locale.text('原生装备未达到请求状态', 'Native equipment did not reach the requested state'))
        Economy.set_balance(self.player, wallet)
        -- A GM edit establishes an exact new slot level, not inherited progress.
        -- New instance identity invalidates bound offers without selling/rerolling.
        slot.state = SlotState.new(actual.level, actual.soul)
        self.serial = self.serial + 1
        slot.id, slot.instance = id, self.serial
    end)
    if not ok then
        local restored, rollback = pcall(function()
            self:_gm_unequip(kind, slot.index)
            if created then
                if weapon(kind) then self:_dispose_weapon(kind, id)
                else
                    if kind == 'medicine' then self.backpack:DisposeMedicine(FName(id)) end
                    self.backpack[maps[kind]]:Remove(FName(id))
                end
                assert(not Native.valid(self:_info(kind, id)),
                    Locale.text('GM 新物品所有权回滚失败', 'Failed to roll back ownership of the new GM item'))
            else
                self:_restore_item(kind, id, itemBefore)
            end
            if oldId then
                if oldDisposed then self:_restore_item(kind, oldId, oldState) end
                self:_equip(kind, oldId, slot.index)
                local actual = self:_state(kind, oldId)
                assert(actual.level == oldState.level and actual.soul == oldState.soul,
                    Locale.text('原装备强化回滚失败', 'Failed to restore the original equipment upgrades'))
            else
                assert(not present(self:_equipped(kind, slot.index)),
                    Locale.text('空栏回滚失败', 'Failed to restore the empty slot'))
            end
            self:_restore_resources(resources)
            self:_assert_other_weapons(otherWeapons)
            for _, other in ipairs(self.slots) do
                if other ~= slot then
                    assert(self:_valid_slot(other),
                        Locale.text('GM 回滚后其他装备栏已改变', 'Another equipment slot changed after GM rollback'))
                end
            end
        end)
        slot.id, slot.instance, slot.state, self.serial = saved.id, saved.instance, saved.state, saved.serial
        local walletRestored, walletError = pcall(Economy.set_balance, self.player, wallet)
        self.busy = false
        if not restored or not walletRestored then
            error(Locale.text('GM 装备替换及回滚失败，必须结束本局: ', 'GM equipment replacement and rollback failed; this run must end: ')
                .. tostring(message) .. '; ' .. tostring(not restored and rollback or walletError))
        end
        return false, Locale.text('GM 替换失败，已恢复原装备：', 'GM replacement failed; original equipment restored: ') .. tostring(message)
    end
    self.busy = false
    return true, Locale.text('GM 装备已替换；等级与铸魂已精确设置，未扣费', 'GM equipment replaced; exact level and soul state set, no charge')
end

-- GM scenarios may reshape the next shop without touching the shipped
-- configuration. Resetting the cached offers forces regeneration on the next
-- rest stop, while fixed services keep their normal prices and limits.
function Equipment:set_shop_override(shop)
    assert(not self.busy, Locale.text('商店交易处理中不能修改商店配置', 'Cannot change shop settings during a transaction'))
    self.shop_override = shop and shop.weights or nil
    self.current, self.offers, self.open = nil, {}, false
end

-- Generate the real offers once at bell preparation, without enabling purchases.
-- Opening and reopening the same rest stop only refresh presentation/availability.
function Equipment:prepare_shop(floor, wave)
    assert(self.initialized, Locale.text('装备尚未初始化', 'Equipment has not been initialized'))
    assert((floor == 1 and wave == 0) or wave == 2 or wave == 3, Locale.text('商店只能在开局、中场或层末休整时开放', 'Shop is only available before battle, at intermission, or after a floor'))
    if self.current and self.floor == floor and self.wave == wave then return self:model() end
    self.floor, self.wave = floor, wave
    self.offers = {}
    self.current = {sections = {}, fixed = {}}
    for _, section in ipairs({'weapons', 'shadow', 'supplies'}) do
        local entries = {}
        local weights = (self.shop_override and self.shop_override[section]) or self.config.shop.weights[section]
        local keys = section == 'supplies' and {'accessory_replace', 'medicine_replace', 'accessory_upgrade', 'medicine_upgrade'} or {'upgrade', 'replace', 'soul'}
        for _, key in ipairs(keys) do
            local kind, action = section, key
            if section == 'supplies' then kind, action = key:match('^(.-)_(.+)$') end
            if (weights[key] or 0) > 0 then
                local candidates = self:_candidates(kind, action)
                local tiered = action == 'replace' and weapon(kind)
                if #candidates > 0 and (not tiered or Economy.has_candidates(self.config, kind, self:_shop_floor(), candidates)) then
                    entries[#entries + 1] = {weight = weights[key], kind = kind, tiered = tiered, candidates = candidates}
                end
            end
        end
        local model = {id = section, offers = {}}
        for index = 1, 3 do
            if #entries == 0 then break end
            local group = self.rng:weighted(entries)
            local selected
            if group.tiered then
                selected = assert(Economy.choose(self.config, group.kind, self:_shop_floor(), group.candidates, self.rng), Locale.text('分档商品候选已失效', 'Tiered item candidate is no longer valid'))
                for i, candidate in ipairs(group.candidates) do
                    if candidate == selected then table.remove(group.candidates, i); break end
                end
            else
                selected = table.remove(group.candidates, self.rng:integer(#group.candidates))
            end
            if #group.candidates == 0 or (group.tiered and not Economy.has_candidates(self.config, group.kind, self:_shop_floor(), group.candidates)) then
                for i, entry in ipairs(entries) do if entry == group then table.remove(entries, i); break end end
            end
            selected.id = section .. ':' .. index
            selected.sold = false
            selected.price = self:_price(selected)
            self.offers[selected.id] = selected
            model.offers[#model.offers + 1] = selected
        end
        self.current.sections[#self.current.sections + 1] = model
    end
    return self:model()
end

function Equipment:open_shop(floor, wave)
    local model = self:prepare_shop(floor, wave)
    self.open = true
    return model
end

function Equipment:model()
    if not self.current then return nil end
    self.current.title = string.format(Locale.text('第 %d 层 · %s', 'Floor %d · %s'), self.floor,
        self.wave == 0 and Locale.text('开战前准备', 'Battle Preparation')
        or (self.wave == 2 and Locale.text('中场休整', 'Intermission') or Locale.text('层末休整', 'Floor Complete')))
    self.current.subtitle = Locale.text('离店后返回铃铛', 'Return to the bell after leaving')
    for _, section in ipairs(self.current.sections) do
        section.title = Locale.text(titles[section.id][1], titles[section.id][2])
        section.reason = #section.offers < 3 and string.format(
            Locale.text('合法候选不足：仅提供 %d 件商品', 'Not enough eligible items: only %d offers available'), #section.offers) or nil
    end
    local balance = Economy.balance(self.player)
    self.current.balance = balance
    for _, offer in pairs(self.offers) do
        local available, reason = self:_availability(offer)
        local enabled = available
        offer.price = self:_price(offer)
        if enabled and balance < offer.price then enabled, reason = false, Locale.text('金钱不足', 'Insufficient funds') end
        offer.enabled, offer.reason = enabled, not enabled and reason or nil
        -- Presentation is regenerated here for new, refreshed and restored offers;
        -- only strings are cached, never transient native data or texture objects.
        offer.title = ({replace = Locale.text('购买替换', 'Replace'), upgrade = Locale.text('升级', 'Upgrade'), soul = Locale.text('铸魂', 'Soul Tempering')})[offer.action]
            .. ' · ' .. self:_name(offer.kind, offer.item)
        local bound = offer.slot and offer.slot.instance == offer.instance and same_id(offer.slot.id, offer.item)
        local soul = offer.action == 'soul' or (bound and offer.slot.state.snapSoul)
        offer.icon = self:_icon(offer.kind, offer.item, soul)
        if offer.action == 'replace' then
            offer.service = weapon(offer.kind) and Locale.text('继承所选栏位等级 · 不继承铸魂', 'Inherits slot level · Soul Tempering is not inherited')
                or Locale.text('继承所选栏位等级（受原生上限限制）', 'Inherits slot level (up to native cap)')
        elseif not bound then
            offer.service = string.format(Locale.text('栏位 Lv.%d · 原装备已替换', 'Slot Lv.%d · Original item replaced'), offer.slot.state.level)
        else
            local level = offer.slot.state:effective_level(self:_cap(offer.kind, offer.item))
            if offer.action == 'upgrade' then
                offer.service = offer.sold and string.format(Locale.text('Lv.%d · 升级已完成', 'Lv.%d · Upgrade complete'), level)
                    or string.format('Lv.%d → Lv.%d', level, offer.targetLevel)
            else
                offer.service = string.format('Lv.%d · %s', level,
                    offer.slot.state.snapSoul and Locale.text('已铸魂', 'Soul Tempered') or Locale.text('未铸魂 → 已铸魂', 'Not Soul Tempered → Soul Tempered'))
            end
        end
        if offer.action == 'replace' then
            offer.detail = weapon(offer.kind) and Locale.text('选择栏位；保留栏位等级，新装备不继承铸魂，不补充使用资源', 'Choose a slot; keeps slot level, does not inherit Soul Tempering or replenish resources')
                or Locale.text('选择栏位；保留栏位等级，不补充使用资源', 'Choose a slot; keeps slot level, does not replenish resources')
        elseif offer.action == 'upgrade' and weapon(offer.kind) then
            local target = available and self:_upgrade_target(offer.slot) or nil
            offer.detail = target and string.format(Locale.text('当前 %d → %d 级；按 5／10／15／20／25／30 级档位升级，不超过原生上限；保留铸魂，不补充使用资源', 'Lv.%d → %d; upgrades at 5/10/15/20/25/30 milestones up to native cap; keeps Soul Tempering, does not replenish resources'),
                offer.slot.state:effective_level(self:_cap(offer.kind, offer.item)), target)
                or Locale.text('按 5／10／15／20／25／30 级档位升级，不超过原生上限；保留铸魂，不补充使用资源', 'Upgrades at 5/10/15/20/25/30 milestones up to native cap; keeps Soul Tempering, does not replenish resources')
        else
            offer.detail = offer.action == 'upgrade' and Locale.text('绑定当前装备实例；原生单次升级，使用原生上限，不补充使用资源', 'Bound to current item; one native upgrade up to native cap, no resource refill')
                or Locale.text('绑定当前装备实例；效果和上限使用原生配置', 'Bound to current item; uses native effects and caps')
        end
        offer.tooltip = item_tooltip(self, offer, bound, soul)
    end
    self.current.fixed = self.fixed:offers(balance)
    for _, offer in ipairs(self.current.fixed) do offer.floor, offer.wave = self.floor, self.wave end
    return self.current
end

function Equipment:purchase(id, targetKey, expectedOffer)
    if not self.open or not self.current or self.busy then return false, Locale.text('商店未开放或交易正在处理', 'Shop is closed or a transaction is in progress') end
    if expectedOffer and expectedOffer.id ~= id then return false, Locale.text('商品已失效', 'Offer is no longer valid') end
    local offer = self.offers[id]
    if not offer then
        if expectedOffer and (expectedOffer.floor ~= self.floor or expectedOffer.wave ~= self.wave) then
            return false, Locale.text('商店商品已刷新', 'Shop offers have refreshed')
        end
        self.busy = true
        local called, ok, message = pcall(self.fixed.purchase, self.fixed, id, expectedOffer and expectedOffer.purchaseIndex)
        self.busy = false
        if not called then error(ok) end
        self:model()
        return ok, message
    end
    if expectedOffer and expectedOffer ~= offer then return false, Locale.text('商店商品已刷新', 'Shop offers have refreshed') end
    local enabled, reason = self:_availability(offer)
    if not enabled then return false, reason end
    local slot = offer.slot
    if offer.action == 'replace' then
        if not targetKey then return false, Locale.text('已取消；未修改装备', 'Cancelled; equipment unchanged') end
        for _, target in ipairs(offer.targets) do
            if target.key == targetKey then for _, candidate in ipairs(self.slots) do if candidate.key == targetKey then slot = candidate end end end
        end
        if not slot then return false, Locale.text('替换栏位已失效', 'Replacement slot is no longer valid') end
    end
    local price, wallet = self:_price(offer), Economy.balance(self.player)
    if wallet < price then return false, Locale.text('金钱不足', 'Insufficient funds') end
    local savedSlot = {id = slot.id, instance = slot.instance, level = slot.state.level, soul = slot.state.snapSoul}
    local savedSerial = self.serial
    self.busy = true
    local oldId, oldState, resources, itemBefore, created, otherWeapons, mutationStarted
    local ok, message = pcall(function()
        resources = self:_resources()
        oldId = slot.id
        oldState = oldId and self:_state(slot.kind, oldId) or nil
        otherWeapons = self:_other_weapons(slot)
        mutationStarted = true
        if offer.action == 'replace' then
            created = not Native.valid(self:_info(slot.kind, offer.item))
            itemBefore = not created and self:_state(slot.kind, offer.item) or nil
            if weapon(slot.kind) and not created then self:_dispose_weapon(slot.kind, offer.item) end
            local info = self:_obtain(slot.kind, offer.item)
            info[levels[slot.kind]] = baseline(slot.kind)
            if weapon(slot.kind) then info.bAlreadySnapSoul = false end
            local inherited = slot.state:replacement(self:_cap(slot.kind, offer.item))
            if inherited.level > baseline(slot.kind) then self:_upgrade(slot.kind, offer.item, inherited.level - baseline(slot.kind)) end
            self:_equip(slot.kind, offer.item, slot.index)
            local actual = self:_state(slot.kind, offer.item)
            assert(actual.level == inherited.level and actual.soul == inherited.snapSoul, Locale.text('原生替换未保留等级或清除铸魂', 'Native replacement did not preserve level or clear Soul Tempering'))
            if oldId and weapon(slot.kind) then self:_dispose_weapon(slot.kind, oldId) end
            self:_restore_resources(resources, slot, offer.item)
            self:_assert_other_weapons(otherWeapons)
            slot.state:commit_replacement(actual.level, self:_cap(slot.kind, offer.item), actual.soul)
            self.serial = self.serial + 1
            slot.id, slot.instance = offer.item, self.serial
        elseif offer.action == 'upgrade' then
            local target = assert(self:_upgrade_target(slot), Locale.text('装备已达到升级上限', 'Equipment upgrade cap reached'))
            self:_upgrade(slot.kind, oldId, weapon(slot.kind) and target - oldState.level or 1)
            local actual = self:_state(slot.kind, oldId)
            assert((not weapon(slot.kind) or actual.level == target) and actual.soul == oldState.soul,
                Locale.text('原生升级未达到目标等级或改变了铸魂', 'Native upgrade did not reach the target level or changed Soul Tempering'))
            self:_restore_resources(resources)
            self:_assert_other_weapons(otherWeapons)
            slot.state:commit_upgrade(oldState.level, actual.level, self:_cap(slot.kind, oldId))
        else
            self.backpack:SnapSoulWeapon(FName(oldId), slot.kind == 'weapons')
            local actual = self:_state(slot.kind, oldId)
            self:_restore_resources(resources)
            slot.state:commit_snap_soul(actual.soul)
        end
        -- Native inventory operations may spend dust. Only this synchronous purchase
        -- is normalized; shop refreshes and skill refunds never restore an old wallet.
        Economy.set_balance(self.player, wallet)
        local charged, reason = Economy.charge(self.player, price)
        assert(charged, reason)
    end)
    if not ok then
        local restored, rollback = pcall(function()
            if not mutationStarted then return end
            if slot.kind == 'accessory' then self.backpack:TakeOffAccessory(slot.index)
            elseif slot.kind == 'medicine' then self.backpack:TakeOffMedicineByIndex(slot.index) end
            if created then
                if weapon(slot.kind) then self:_dispose_weapon(slot.kind, offer.item)
                else
                    if slot.kind == 'medicine' then self.backpack:DisposeMedicine(FName(offer.item)) end
                    self.backpack[maps[slot.kind]]:Remove(FName(offer.item))
                end
            elseif itemBefore then self:_restore_item(slot.kind, offer.item, itemBefore) end
            if oldState then self:_restore_item(slot.kind, oldId, oldState); self:_equip(slot.kind, oldId, slot.index)
            elseif offer.action == 'replace' then
                if slot.kind == 'accessory' then self.backpack:TakeOffAccessory(slot.index)
                elseif slot.kind == 'shadow' then self:_unequip_weapon(slot.kind, offer.item)
                end
            end
            if resources then self:_restore_resources(resources) end
            if otherWeapons then self:_assert_other_weapons(otherWeapons) end
        end)
        slot.id, slot.instance, self.serial = savedSlot.id, savedSlot.instance, savedSerial
        slot.state = SlotState.new(savedSlot.level, savedSlot.soul)
        local walletRestored, walletError = pcall(Economy.set_balance, self.player, wallet)
        self.busy = false
        if not restored then error(Locale.text('交易失败且原生回滚失败，必须结束本局: ', 'Transaction and native rollback failed; this run must end: ') .. tostring(message) .. '; ' .. tostring(rollback)) end
        if not walletRestored then error(Locale.text('交易失败且钱包回滚失败，必须结束本局: ', 'Transaction and wallet rollback failed; this run must end: ') .. tostring(message) .. '; ' .. tostring(walletError)) end
        return false, Locale.text('交易失败，已恢复原装备：', 'Transaction failed; original equipment restored: ') .. tostring(message)
    end
    offer.sold = true
    offer.price = price
    self.busy = false
    self:model()
    return true, Locale.text('购买成功', 'Purchase successful')
end

function Equipment:close_shop()
    assert(not self.busy, Locale.text('交易处理中不能离店', 'Cannot leave during a transaction'))
    self.open = false
end

function Equipment:complete_wave(floor, wave)
    assert(self.initialized and not self.busy, Locale.text('装备仍在交易中，不能结算波次', 'Cannot complete the wave during an equipment transaction'))
    if wave == 1 then
        self.floor, self.wave, self.current, self.offers, self.open = floor, wave, nil, {}, false
    else
        self:prepare_shop(floor, wave)
        self.open = false
    end
end

function Equipment:snapshot()
    assert(self.initialized and not self.busy and (self.wave == 1 or self.current), Locale.text('只能保存已结算波次的完整装备状态', 'Only complete equipment state after a finished wave can be saved'))
    local result = {serial = self.serial, floor = self.floor, wave = self.wave, slots = {}, sections = {},
        resources = self:_resources(), fixed = self.fixed:snapshot(),
        mainIndex = self.backpack.CurrentWeaponIndex, medicineExtra = self.backpack:GetMedicineExtraUsage()}
    for _, slot in ipairs(self.slots) do
        assert(self:_valid_slot(slot), Locale.text('保存时原生装备与栏位不一致: ', 'Native equipment does not match its slot while saving: ') .. slot.key)
        result.slots[#result.slots + 1] = {kind = slot.kind, index = slot.index, id = slot.id, key = slot.key,
            instance = slot.instance, level = slot.state.level, soul = slot.state.snapSoul}
    end
    for _, section in ipairs(self.current and self.current.sections or {}) do
        local saved = {id = section.id, title = section.title, reason = section.reason, offers = {}}
        for _, offer in ipairs(section.offers) do
            saved.offers[#saved.offers + 1] = {id = offer.id, kind = offer.kind, action = offer.action, item = offer.item,
                instance = offer.instance, slotKey = offer.slot and offer.slot.key or nil,
                title = offer.title, detail = offer.detail, sold = offer.sold, targetLevel = offer.targetLevel}
        end
        result.sections[#result.sections + 1] = saved
    end
    return result
end

function Equipment:restore(saved)
    assert(not self.initialized and type(saved) == 'table', Locale.text('装备恢复必须在原生读档后且不执行开局初始化', 'Equipment restore requires a native save load without starting-loadout initialization'))
    self.fixed:restore(saved.fixed)
    self.serial, self.floor, self.wave, self.slots, self.offers = saved.serial, saved.floor, saved.wave or 3, {}, {}
    local byKey = {}
    for _, item in ipairs(saved.slots) do
        assert(maps[item.kind] and item.key == item.kind .. ':' .. item.index and not byKey[item.key], Locale.text('栏位存档无效', 'Invalid saved slot'))
        local slot = {kind = item.kind, index = item.index, id = item.id, key = item.key,
            instance = item.instance, state = SlotState.new(item.level, item.soul)}
        self.slots[#self.slots + 1], byKey[slot.key] = slot, slot
        assert(self:_valid_slot(slot), Locale.text('原生读档未恢复装备: ', 'Native save did not restore equipment: ') .. slot.key)
    end
    assert(self.backpack:GetMedicineExtraUsage() == saved.medicineExtra, Locale.text('原生药品额外次数未恢复', 'Native extra medicine uses were not restored'))
    assert(type(saved.sections) == 'table' and (self.wave ~= 1 or #saved.sections == 0), Locale.text('第一波存档不能包含商店', 'Wave-one saves cannot contain a shop'))
    self.current = self.wave ~= 1 and {sections = {}, fixed = {}} or nil
    for _, section in ipairs(saved.sections) do
        local model = {id = section.id, offers = {}}
        for _, offer in ipairs(section.offers) do
            assert(not self.offers[offer.id], Locale.text('商店商品存档重复', 'Duplicate saved shop offer'))
            if offer.slotKey then
                offer.slot = assert(byKey[offer.slotKey], Locale.text('商店商品绑定栏位已丢失', 'Saved shop offer has lost its bound slot'))
                offer.slotKey = nil
            end
            offer.price = self:_price(offer)
            self.offers[offer.id] = offer
            model.offers[#model.offers + 1] = offer
        end
        self.current.sections[#self.current.sections + 1] = model
    end
    self:_restore_resources(saved.resources)
    self.backpack:SetCurrentWeaponByIndex(saved.mainIndex, true)
    local actual = self:_resources()
    for index, resource in ipairs(saved.resources.native) do
        assert(actual.native[index].name == resource.name and math.abs(actual.native[index].current - resource.current) < 0.001,
            Locale.text('原生资源未完整恢复: ', 'Native resources were not fully restored: ') .. resource.name)
    end
    for id, medicine in pairs(saved.resources.medicine) do
        local restored = actual.medicine[id]
        assert(restored and restored.count == medicine.count and restored.display == medicine.display, Locale.text('药品次数未完整恢复: ', 'Medicine uses were not fully restored: ') .. id)
    end
    for index, bullet in ipairs(saved.resources.bullets) do
        local restored = actual.bullets[index]
        assert(restored and same_id(restored.id, bullet.id) and restored.count == bullet.count, Locale.text('影之武装弹药未完整恢复', 'Phantom Edge ammunition was not fully restored'))
    end
    assert(actual.ultimate == saved.resources.ultimate and actual.percentage == saved.resources.percentage, Locale.text('原生绝技资源未恢复', 'Native ultimate resources were not restored'))
    self.initialized, self.open = true, false
    self:model()
end

return Equipment
