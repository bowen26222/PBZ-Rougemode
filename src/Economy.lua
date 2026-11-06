local Native = require('Native')
local Locale = require('Locale')
local Economy = {}
local wallet_cap = 2000000000

local function money(value)
    assert(type(value) == 'number' and value >= 0 and value % 1 == 0 and value <= wallet_cap,
        Locale.text('原生钱数必须为 0～2000000000 的整数', 'Native currency must be an integer from 0 to 2000000000'))
    return value
end

function Economy.balance(player)
    return money(Native.cdo('/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary'):GetCurrentDust(player))
end

function Economy.set_balance(player, amount)
    money(amount)
    local before = Economy.balance(player)
    if before ~= amount then player:ChangeDustNumInternal(amount - before) end
    assert(Economy.balance(player) == amount, Locale.text('原生钱包变更未完成', 'Native wallet update did not complete'))
    return amount
end

function Economy.charge(player, amount)
    money(amount)
    local before = Economy.balance(player)
    if before < amount then return false, string.format(Locale.text('金钱不足：需要 %d，当前 %d', 'Insufficient funds: need %d, have %d'), amount, before) end
    Economy.set_balance(player, before - amount)
    return true
end

function Economy.award(player, amount)
    money(amount)
    return Economy.set_balance(player, math.min(wallet_cap, Economy.balance(player) + amount))
end

function Economy.stage(config, pool, floor)
    local stages = assert(config.economy.progress[pool], Locale.text('缺少进度配置: ', 'Missing progression configuration: ') .. tostring(pool))
    for _, stage in ipairs(stages) do
        if floor >= stage.firstFloor and (stage.lastFloor == nil or floor <= stage.lastFloor) then return stage end
    end
    error(Locale.text('楼层不在已配置进度区间内: ', 'Floor is outside the configured progression range: ') .. tostring(pool) .. '/' .. tostring(floor))
end

local function candidate_data(config, pool, candidate)
    if pool == 'mobs' or pool == 'bosses' then return candidate end
    return assert(config.economy.items[pool][candidate.item], Locale.text('缺少商品分档: ', 'Missing item tier: ') .. tostring(candidate.item))
end

function Economy.has_candidates(config, pool, floor, candidates)
    local stage = Economy.stage(config, pool, floor)
    for _, candidate in ipairs(candidates) do
        local data = candidate_data(config, pool, candidate)
        if data.weight > 0 and (stage.probabilities[data.tier] or 0) > 0 then return true end
    end
    return false
end

function Economy.choose(config, pool, floor, candidates, rng)
    local stage = Economy.stage(config, pool, floor)
    local tiers, groups = {}, {}
    for _, tier in ipairs(config.economy.tiers) do
        local probability = stage.probabilities[tier]
        if probability > 0 then groups[tier] = {weight = probability, rows = {}} end
    end
    for _, candidate in ipairs(candidates) do
        local data = candidate_data(config, pool, candidate)
        local group = groups[data.tier]
        if group and data.weight > 0 then group.rows[#group.rows + 1] = {weight = data.weight, value = candidate} end
    end
    -- Empty tiers have no legal outcomes; their mass is redistributed among nonempty tiers.
    for _, tier in ipairs(config.economy.tiers) do
        local group = groups[tier]
        if group and #group.rows > 0 then tiers[#tiers + 1] = group end
    end
    if #tiers == 0 then return nil end
    return rng:weighted(rng:weighted(tiers).rows).value
end

function Economy.price(config, kind, action, item, target_level)
    local row = assert(config.economy.items[kind][item], Locale.text('缺少商品价格: ', 'Missing item price: ') .. tostring(item))
    local price
    if action == 'replace' then price = row.buy
    elseif action == 'soul' then price = row.soul
    elseif action == 'upgrade' then
        if kind == 'weapons' or kind == 'shadow' then
            assert(type(target_level) == 'number' and target_level >= 1 and target_level <= 30,
                Locale.text('升级价格缺少合法目标等级', 'Upgrade price requires a valid target level'))
            -- Native caps or legacy saves can produce a target between milestones;
            -- charge the next configured milestone, never past the last one.
            local milestones = kind == 'shadow' and {5, 10, 15, 20, 25, 30}
                or {4, 7, 10, 13, 16, 19, 22, 25, 28, 30}
            for _, milestone in ipairs(milestones) do
                if target_level <= milestone then
                    price = row.upgrade[tostring(milestone)]
                    break
                end
            end
            price = price or row.upgrade[tostring(milestones[#milestones])]
        else price = row.upgrade end
    else error(Locale.text('未知商品操作: ', 'Unknown item action: ') .. tostring(action)) end
    return money(price)
end

function Economy.fixed_price(config, kind, purchase_index)
    local prices = assert(config.economy.fixed[kind], Locale.text('未知固定商品: ', 'Unknown fixed upgrade: ') .. tostring(kind))
    return money(prices[purchase_index])
end

return Economy
