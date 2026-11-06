local Native = require('Native')
local Json = require('Json')
local Locale = require('Locale')
local Fixed = require('FixedUpgrades')

-- Browser bridge for the local GM console. The console writes command.json into
-- the active run profile; this module validates it and applies it on the game
-- thread without reinitializing the run, player, inventory or wallet.
local Gm = {}

local sessions = setmetatable({}, {__mode = 'k'})
local wave_limit, boss_limit, count_limit, floor_limit = 12, 3, 8, 999
local starts = {wave1 = true, wave2 = true, boss = true, shop = true}
local section_keys = {
    weapons = {'upgrade', 'replace', 'soul'},
    shadow = {'upgrade', 'replace', 'soul'},
    supplies = {'accessory_replace', 'medicine_replace', 'accessory_upgrade', 'medicine_upgrade'}
}

local function read_text(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local text = file:read('*a')
    file:close()
    return text
end

local function clean_message(message)
    -- Native Lua assertions prefix the file/line; the console only needs the text.
    return (tostring(message):gsub('^.-%.lua:%d+: ', ''))
end

local function write_text(path, text)
    local file = io.open(path, 'wb')
    if not file then return false end
    local written = file:write(text)
    file:close()
    return written ~= nil
end

local function integer(value, minimum, maximum, label)
    assert(type(value) == 'number' and value % 1 == 0 and value >= minimum and value <= maximum,
        string.format(Locale.text('%s 需要 %d～%d 的整数', '%s requires an integer from %d to %d'),
            label, minimum, maximum))
end

local function enemy_maps(config)
    local maps = {mobs = {}, bosses = {}}
    for _, pool in ipairs({'mobs', 'bosses'}) do
        for _, enemy in ipairs(config.enemy_pools[pool]) do maps[pool][enemy.id] = enemy end
    end
    return maps
end

local function resolve(pool, entries, maps, label, maximum)
    assert(type(entries) == 'table', string.format(Locale.text('%s 的敌人列表无效', '%s has an invalid enemy list'), label))
    local list, summary = {}, {}
    for index, entry in ipairs(entries) do
        assert(type(entry) == 'table', string.format(Locale.text('%s 第 %d 项格式无效', '%s entry %d is invalid'), label, index))
        local id = entry.id
        assert(type(id) == 'string' and id ~= '',
            string.format(Locale.text('%s 第 %d 项缺少敌人 ID', '%s entry %d has no enemy ID'), label, index))
        local enemy = assert(maps[pool][id],
            string.format(Locale.text('%s 中存在未知敌人：%s', 'Unknown enemy in %s: %s'), label, id))
        local count = entry.count
        if count == nil then count = 1 end
        integer(count, 1, count_limit, string.format(Locale.text('%s 的敌人数量', 'Enemy count in %s'), label))
        for _ = 1, count do list[#list + 1] = enemy end
        summary[#summary + 1] = {id = id, count = count}
    end
    assert(#list >= 1, string.format(Locale.text('%s 至少需要一个敌人', '%s requires at least one enemy'), label))
    assert(#list <= maximum, string.format(Locale.text('%s 最多 %d 个敌人', '%s allows at most %d enemies'), label, maximum))
    return list, summary
end

local function normalize_shop(shop)
    assert(type(shop) == 'table' and type(shop.weights) == 'table',
        Locale.text('商店配置缺少 weights', 'The shop configuration is missing weights'))
    local weights = {}
    for section, keys in pairs(section_keys) do
        local source = assert(shop.weights[section], string.format(Locale.text('商店配置缺少 %s 权重', 'Missing %s shop weights'), section))
        assert(type(source) == 'table', string.format(Locale.text('%s 商店权重无效', 'Invalid %s shop weights'), section))
        local row = {}
        for _, key in ipairs(keys) do
            integer(source[key], 0, 100, string.format('%s.%s', section, key))
            row[key] = source[key]
        end
        weights[section] = row
    end
    return {weights = weights}
end

function Gm.normalize(config, scenario)
    assert(type(scenario) == 'table', Locale.text('缺少 GM 场景数据', 'GM scenario data is missing'))
    integer(scenario.floor, 1, floor_limit, Locale.text('层数', 'Floor'))
    local start = scenario.start
    if start == nil then start = 'wave1' end
    assert(starts[start], Locale.text('起始阶段必须是 wave1、wave2、boss 或 shop', 'Start stage must be wave1, wave2, boss or shop'))
    local maps = enemy_maps(config)
    local mobs = scenario.mobs
    assert(type(mobs) == 'table' and #mobs == 2,
        Locale.text('GM 楼层需要正好两波小怪配置', 'A GM floor requires exactly two mob wave configurations'))
    local waves, summary = {}, {}
    for wave = 1, 2 do
        local entries = mobs[wave] and mobs[wave].enemies
        local label = string.format(Locale.text('小怪第 %d 波', 'Mob wave %d'), wave)
        waves[wave], summary[wave] = resolve('mobs', entries, maps, label, wave_limit)
    end
    local boss = scenario.boss
    assert(type(boss) == 'table' and type(boss.enemies) == 'table',
        Locale.text('缺少 Boss 配置', 'Boss configuration is missing'))
    local bosses, boss_summary = resolve('bosses', boss.enemies, maps, Locale.text('Boss', 'Boss'), boss_limit)
    local shop
    if scenario.shop ~= nil then shop = normalize_shop(scenario.shop) end
    return {
        floor = scenario.floor, mobs = waves, boss = bosses, shop = shop,
        summary = {floor = scenario.floor, start = start, mobs = summary, boss = boss_summary,
            shop = shop and shop.weights or nil,
            mobTotal = #waves[1] + #waves[2], bossTotal = #bosses}
    }
end

function Gm.apply(run, scenario)
    assert(run and run.config, Locale.text('游戏尚未进入可加载的爬塔进程', 'The game is not in a loadable trial process'))
    local plan = Gm.normalize(run.config, scenario)
    -- Resolve every native class before mutating the run, so a bad entry cannot
    -- leave a half-applied scenario behind.
    for _, list in ipairs({plan.mobs[1], plan.mobs[2], plan.boss}) do
        for _, enemy in ipairs(list) do
            local ok, message = pcall(Native.load_class, enemy.class)
            assert(ok, string.format(Locale.text('敌人蓝图加载失败：%s（%s）', 'Enemy blueprint failed to load: %s (%s)'),
                enemy.id, tostring(message)))
        end
    end
    run:gm_apply(plan)
    return plan
end

local control_keys = {health = true, maxHealth = true, attack = true, lockHealth = true, shachi = true}
local control_phases = {ready = true, rest = true, bell = true, shop = true, skills = true, between = true, combat = true}

local function stat_data(run, name)
    local fixed = run.equipment.fixed
    local attribute = assert(fixed.bindings[name], 'Missing native GM attribute: ' .. name)
    local set = fixed.asc:GetAttributeSet(attribute.AttributeOwner)
    assert(Native.valid(set), 'Native GM attribute set is unavailable')
    return set[name], attribute
end

local function shachi_data(run)
    local fixed = run.equipment.fixed
    local attribute = assert(fixed.bindings.Shachi_Max, 'Missing native Sha-Chi attribute')
    local set = fixed.asc:GetAttributeSet(attribute.AttributeOwner)
    assert(Native.valid(set), 'Native Sha-Chi attribute set is unavailable')
    return set.Shachi, set.Shachi_Max
end

local function apply_controls(run, controls)
    assert(control_phases[run.phase] and Native.valid(run.player),
        Locale.text('当前状态不能修改角色', 'Character controls are unavailable in the current state'))
    assert(not run.saves:is_busy() and not run.equipment.busy,
        Locale.text('正在存档或交易，请稍后重试', 'Saving or trading; try again shortly'))
    assert(type(controls) == 'table' and next(controls) ~= nil,
        Locale.text('缺少角色修改参数', 'Character controls are missing'))
    for key, value in pairs(controls) do
        assert(control_keys[key], 'Unknown character control: ' .. tostring(key))
        if key == 'lockHealth' then
            assert(type(value) == 'boolean', key .. ' must be a boolean')
        else
            local minimum = key == 'shachi' and 0 or 1
            assert(type(value) == 'number' and value >= minimum and value <= 1000000,
                Locale.text('属性值超出允许范围', 'Stat value is outside the allowed range'))
        end
    end
    local maximum, max_attribute = stat_data(run, 'Health_Max')
    local attack, attack_attribute = stat_data(run, 'Attack')
    -- Resource edits are separate from base-stat edits: changing a maximum must
    -- not silently refill the player, and an out-of-range HP request is rejected.
    assert(not (controls.health and controls.maxHealth),
        Locale.text('请分别修改生命上限和当前生命', 'Change max health and current health separately'))
    assert(not controls.health or controls.health <= maximum.CurrentValue,
        Locale.text('当前生命不能超过实际生命上限', 'Current health cannot exceed effective max health'))
    local _, shachi_max = shachi_data(run)
    assert(not controls.shachi or controls.shachi <= shachi_max.CurrentValue,
        Locale.text('杀气值不能超过实际杀气上限', 'Sha-Chi cannot exceed its effective maximum'))
    local util = Native.cdo('/Script/SGameAttributes.Default__AttributeUtils')
    if controls.maxHealth then
        local health = Native.health(run.player)
        util:ModifyCharacterAttributeValue(run.player, max_attribute, 3, controls.maxHealth)
        assert(math.abs(maximum.BaseValue - controls.maxHealth) < 0.01, 'Native max-health write failed')
        Fixed.restore_resources(run.player, {{name = 'Health', current = math.min(health, maximum.CurrentValue)}})
    end
    if controls.attack then
        util:ModifyCharacterAttributeValue(run.player, attack_attribute, 3, controls.attack)
        assert(math.abs(attack.BaseValue - controls.attack) < 0.01, 'Native attack write failed')
    end
    if controls.health then
        Fixed.restore_resources(run.player, {{name = 'Health', current = controls.health}})
    end
    if controls.shachi then
        Fixed.restore_resources(run.player, {{name = 'Shachi', current = controls.shachi}})
    end
    if controls.lockHealth ~= nil then run.battle:set_health_lock(controls.lockHealth) end
end

local function can_replace_equipment(run)
    return control_phases[run.phase] == true and Native.valid(run.player)
        and (Native.health(run.player) or 0) > 0 and run.equipment ~= nil
        and run.equipment.initialized == true and not run.equipment.busy
        and run.saves ~= nil and not run.saves:is_busy()
end

local function apply_equipment(run, request)
    assert(can_replace_equipment(run),
        Locale.text('当前不能替换装备：请等待角色就绪、存档或交易结束', 'Equipment replacement is unavailable; wait for the player, save or transaction to finish'))
    local called, ok, message = pcall(run.equipment.gm_replace, run.equipment, request)
    if not called then
        -- A failed rollback cannot leave a playable run with mismatched native
        -- inventory and slot metadata. Normal validation failures return false.
        run:fail(ok)
        error(ok, 0)
    end
    assert(ok, message)
    if run.phase == 'shop' then
        -- Dismiss any old replacement chooser/tooltip and rebuild presentation,
        -- retaining the existing generated offers and sold-out state.
        run.ui:hide()
        run:show_shop()
    else
        run:record()
    end
    return message or Locale.text('指定装备已替换', 'Specified equipment replaced')
end

local function snapshot(run)
    local data = {schema = 1, updated = os.time(), phase = run.phase, floor = run.floor, wave = run.wave,
        gm = run.gm_scenario}
    local player = run.player
    if player and Native.valid(player) then
        local ok, health = pcall(Native.health, player)
        if ok then data.health = health end
        local balance_ok, balance = pcall(function() return require('Economy').balance(player) end)
        if balance_ok then data.balance = balance end
        if run.equipment and run.equipment.fixed then
            local maximum = stat_data(run, 'Health_Max')
            local attack = stat_data(run, 'Attack')
            data.maxHealth, data.maxHealthBase = maximum.CurrentValue, maximum.BaseValue
            data.attack, data.attackBase = attack.CurrentValue, attack.BaseValue
            local shachi, shachi_max = shachi_data(run)
            data.shachi, data.shachiMax = shachi.CurrentValue, shachi_max.CurrentValue
        end
        data.lockHealth = run.battle ~= nil and run.battle:health_locked()
        if run.equipment and run.equipment.initialized then
            local equipped, equipment = pcall(function()
                return {catalog = run.equipment:gm_catalog(), slots = run.equipment:gm_slots(),
                    canReplace = can_replace_equipment(run)}
            end)
            data.equipment = equipped and equipment or {canReplace = false, reason = clean_message(equipment)}
        end
    end
    return data
end

local function session(run)
    local existing = sessions[run]
    if existing then return existing end
    local applied, ok, message = 0, true, ''
    local text = read_text(run.profile .. '/gm/status.json')
    if text then
        local decoded, status = pcall(Json.decode, text)
        if decoded and type(status) == 'table' then
            if type(status.appliedSeq) == 'number' then applied = status.appliedSeq end
            if type(status.ok) == 'boolean' then ok = status.ok end
            if type(status.message) == 'string' then message = status.message end
        end
    end
    existing = {applied = applied, ok = ok, message = message, written = 0}
    sessions[run] = existing
    return existing
end

function Gm.tick(run)
    if not run.profile or run.phase == 'menu' then return end
    if Gm._phase ~= run.phase then
        Gm._phase = run.phase
        print(string.format('[PBZRogue] GM bridge active in phase %s\n', tostring(run.phase)))
    end
    local state = session(run)
    local text = read_text(run.profile .. '/gm/command.json')
    if text then
        local decoded, command = pcall(Json.decode, text)
        if decoded and type(command) == 'table' and type(command.seq) == 'number' and command.seq > state.applied then
            local controls = command.action == 'controls'
            local applied, message
            if controls then
                applied, message = pcall(apply_controls, run, command.controls)
            elseif command.action == 'equipment' then
                applied, message = pcall(apply_equipment, run, command.equipment)
            elseif command.action == nil or command.action == 'apply' then
                applied, message = pcall(Gm.apply, run, command.scenario)
            else
                applied, message = false, 'Unknown GM command: ' .. tostring(command.action)
            end
            state.applied = command.seq
            state.ok = applied
            state.message = applied and (command.action == 'equipment' and message
                or (controls and Locale.text('角色参数已更新', 'Character controls updated')
                    or Locale.text('自定义楼层已加载', 'Custom floor loaded'))) or clean_message(message)
            print(string.format('[PBZRogue] GM command %d: %s\n', command.seq, state.message))
            state.written = 0
        end
    end
    local now = os.time()
    if now ~= state.written then
        state.written = now
        local data = snapshot(run)
        data.appliedSeq, data.ok, data.message = state.applied, state.ok, state.message
        write_text(run.profile .. '/gm/status.json', Json.encode(data))
    end
end

return Gm
