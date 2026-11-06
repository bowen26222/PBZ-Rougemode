local Json = require('Json')
local Config = {}

local function integer(value, minimum, label)
    assert(type(value) == 'number' and value == math.floor(value) and value >= minimum, 'Invalid ' .. label)
end

local function positive(value, label)
    assert(type(value) == 'number' and value > 0 and value < math.huge, 'Invalid ' .. label)
end

local function finite(value, label)
    assert(type(value) == 'number' and value == value and math.abs(value) < math.huge, 'Invalid ' .. label)
end

function Config.load(directory)
    local result = {}
    for _, name in ipairs({'run', 'floors', 'enemy_pools', 'items', 'shop', 'economy', 'music'}) do
        local path = directory .. '/' .. name .. '.json'
        local file = assert(io.open(path, 'rb'), 'Missing mode configuration: ' .. path)
        local contents = file:read('*a')
        file:close()
        result[name] = Json.decode(contents)
        assert(type(result[name]) == 'table', 'Configuration root must be an object: ' .. name)
    end
    assert(result.run.schema == 1, 'Unsupported run configuration schema')
    integer(result.run.startingMoney, 0, 'starting money')
    assert(result.run.startingMoney <= 2000000000, 'Starting money exceeds the native wallet cap')
    if result.run.seed ~= nil then integer(result.run.seed, 0, 'run seed') end
    local floors = result.floors
    assert(#floors.waves == 3 and floors.waves[1].pool == 'mobs' and floors.waves[2].pool == 'mobs'
        and floors.waves[3].pool == 'bosses', 'Each floor must contain two mob waves followed by one boss wave')
    assert(floors.waves[3].minimum == 1 and floors.waves[3].maximum == 1,
        'Each boss encounter must contain exactly one original boss phase')
    integer(floors.level.first, 1, 'first enemy level')
    integer(floors.level.perFloor, 1, 'enemy levels per floor')
    if floors.level.byFloor ~= nil then
        assert(type(floors.level.byFloor) == 'table', 'level.byFloor must be an object')
        for floor, level in pairs(floors.level.byFloor) do
            local number = tonumber(floor)
            integer(number, 1, 'level.byFloor floor')
            integer(level, 1, 'level.byFloor level')
        end
    end
    integer(floors.clearReward, 0, 'floor clear reward')
    positive(floors.waveDelaySeconds, 'wave interval')
    positive(floors.readyDelaySeconds, 'start interval')
    local arena = floors.arena
    assert(type(arena.map) == 'string' and arena.map:match('^/Game/'), 'Arena requires a native game map')
    assert(type(arena.policy) == 'string', 'Arena requires a native spawn policy')
    assert(type(arena.center) == 'table' and type(arena.camera) == 'table', 'Arena center/camera missing')
    for _, axis in ipairs({'X', 'Y', 'Z'}) do finite(arena.center[axis], 'arena center ' .. axis) end
    for _, axis in ipairs({'Pitch', 'Yaw', 'Roll'}) do finite(arena.camera[axis], 'arena camera ' .. axis) end
    assert(type(arena.cinematicFlows) == 'table' and #arena.cinematicFlows > 0,
        'Arena requires exact cinematic flow asset paths')
    local cinematic_flows = {}
    for _, path in ipairs(arena.cinematicFlows) do
        assert(type(path) == 'string' and path:match('^/Game/[%w_/]+%.[%w_]+$')
            and not cinematic_flows[path], 'Invalid or duplicate arena cinematic flow path')
        cinematic_flows[path] = true
    end
    positive(arena.spawnRadius, 'spawn radius')
    positive(arena.minimumPlayerDistance, 'minimum player distance')
    positive(arena.minimumEnemyDistance, 'enemy spacing')
    positive(arena.boundaryRadius, 'arena recovery radius')
    assert(arena.minimumPlayerDistance < arena.spawnRadius and arena.spawnRadius < arena.boundaryRadius,
        'Arena radii are inconsistent')
    local wall = arena.stairWall
    assert(type(wall) == 'table' and type(wall.start) == 'table' and type(wall.finish) == 'table',
        'Arena requires a stairway collision wall')
    positive(wall.height, 'stairway wall height')
    positive(wall.depth, 'stairway wall depth')
    positive(wall.thickness, 'stairway wall thickness')
    finite(wall.baseZ, 'stairway wall base')
    for _, point in ipairs({wall.start, wall.finish}) do
        finite(point.X, 'stairway wall X')
        finite(point.Y, 'stairway wall Y')
    end
    positive((wall.finish.X - wall.start.X)^2 + (wall.finish.Y - wall.start.Y)^2, 'stairway wall length')
    for _, wave in ipairs(floors.waves) do
        integer(wave.minimum, 1, 'minimum wave size')
        integer(wave.maximum, wave.minimum, 'maximum wave size')
    end
    local economy = result.economy
    assert(type(economy.tiers) == 'table' and #economy.tiers > 0, 'Economy requires at least one tier')
    local tiers = {}
    for _, tier in ipairs(economy.tiers) do
        assert(type(tier) == 'string' and tier ~= '' and not tiers[tier], 'Economy tiers must be unique names')
        tiers[tier] = true
    end
    local function progress(pool, wave_count)
        local stages = economy.progress[pool]
        assert(type(stages) == 'table' and #stages > 0, 'Economy progress is missing: ' .. pool)
        local previous
        for _, stage in ipairs(stages) do
            integer(stage.firstFloor, 0, 'progress first floor')
            if previous then
                assert(previous.firstFloor < stage.firstFloor, 'Progress floors must ascend: ' .. pool)
                assert(stage.firstFloor <= previous.lastFloor + 1, 'Progress stages leave a floor gap: ' .. pool)
            end
            previous = stage
            local total = 0
            for tier in pairs(tiers) do
                local probability = stage.probabilities[tier]
                assert(type(probability) == 'number' and probability >= 0 and probability <= 100,
                    'Invalid tier probability: ' .. pool)
                total = total + probability
            end
            assert(total == 100, 'Tier probabilities must total 100: ' .. pool)
            if stage.waves ~= nil then
                assert(wave_count and #stage.waves == wave_count, 'Invalid stage wave count: ' .. pool)
                for _, wave in ipairs(stage.waves) do
                    integer(wave.minimum, 1, 'stage minimum wave size')
                    integer(wave.maximum, wave.minimum, 'stage maximum wave size')
                end
            end
        end
        return stages
    end
    local mob_stages = progress('mobs', #floors.waves - 1)
    local boss_stages = progress('bosses', 1)
    assert(mob_stages[1].firstFloor <= 1 and boss_stages[1].firstFloor <= 1,
        'Enemy progress must cover the first floor')
    for _, pool in ipairs({'weapons', 'shadow'}) do
        assert(progress(pool)[1].firstFloor == 0, 'Opening shop progress must start at floor 0: ' .. pool)
    end

    local upgrade_targets = {
        weapons = {4, 7, 10, 13, 16, 19, 22, 25, 28, 30},
        shadow = {5, 10, 15, 20, 25, 30},
    }
    local function item_prices(kind, pool, tiered, skip)
        local rows = assert(economy.items[kind], 'Missing price table: ' .. kind)
        for _, id in ipairs(result.items.pools[pool]) do
            if not skip(id) then
                local row = rows[id]
                assert(type(row) == 'table', 'Missing price row: ' .. pool .. '/' .. id)
                integer(row.buy, 0, 'item replacement price')
                if tiered then
                    assert(tiers[row.tier], 'Invalid item tier: ' .. id)
                    positive(row.weight, 'item weight')
                    local levels = upgrade_targets[kind]
                    for _, level in ipairs(levels) do
                        integer(row.upgrade[tostring(level)], 0, 'weapon upgrade price')
                    end
                    local allowed = {}
                    for _, level in ipairs(levels) do allowed[tostring(level)] = true end
                    for level in pairs(row.upgrade) do
                        assert(allowed[level], 'Invalid upgrade price level: ' .. level)
                    end
                    integer(row.soul, 0, 'snap soul price')
                else
                    integer(row.upgrade, 0, 'item upgrade price')
                end
            end
        end
    end
    local function never() return false end
    item_prices('weapons', 'weapons', true, never)
    item_prices('shadow', 'shadow', true, never)
    item_prices('medicine', 'medicine', false, never)
    local excluded = type(economy.items.excluded) == 'table' and economy.items.excluded.accessory or {}
    for id, reason in pairs(excluded) do
        assert(type(reason) == 'string' and reason ~= '', 'Excluded accessory requires a reason: ' .. tostring(id))
    end
    item_prices('accessory', 'accessory', false, function(id) return excluded[id] ~= nil end)
    for _, kind in ipairs({'health', 'attack', 'shachi'}) do
        local list = assert(economy.fixed[kind], 'Missing fixed upgrade prices: ' .. kind)
        assert(#list == 20, 'Fixed upgrades require exactly twenty prices: ' .. kind)
        for _, price in ipairs(list) do integer(price, 0, 'fixed upgrade price') end
    end
    assert(type(economy.heartPrices) == 'table' and #economy.heartPrices == 8,
        'Hearts require exactly eight purchase prices')
    for _, price in ipairs(economy.heartPrices) do
        integer(price, 0, 'heart price')
        assert(price <= 2000000000, 'Heart price exceeds the native wallet cap')
    end
    assert(type(economy.skills) == 'table' and next(economy.skills), 'Missing skill upgrade prices')
    for id, price in pairs(economy.skills) do
        assert(type(id) == 'string' and id ~= '', 'Invalid skill node ID')
        integer(price, 0, 'skill upgrade price')
        assert(price <= 2000000000, 'Skill price exceeds the native wallet cap')
    end

    local ids = {}
    for _, name in ipairs({'mobs', 'bosses'}) do
        local pool, starts_available = result.enemy_pools[name], false
        assert(type(pool) == 'table' and #pool > 0, 'Enemy pool is empty: ' .. name)
        for _, enemy in ipairs(pool) do
            assert(type(enemy.id) == 'string' and not ids[enemy.id], 'Enemy IDs must be unique')
            ids[enemy.id] = true
            assert(type(enemy.class) == 'string' and enemy.class:match('^/[%w_/]+%.[%w_]+_C$'),
                'Invalid enemy blueprint class path: ' .. enemy.id)
            positive(enemy.weight, 'enemy weight')
            integer(enemy.firstFloor, 1, 'enemy first floor')
            if enemy.enabled ~= false then
                assert(tiers[enemy.tier], 'Enemy requires a valid tier: ' .. enemy.id)
                integer(enemy.reward, 0, 'enemy kill reward')
            end
            assert(enemy.enabled == nil or type(enemy.enabled) == 'boolean', 'Invalid enemy enabled flag')
            if enemy.enabled == false then
                assert(type(enemy.unavailableReason) == 'string'
                    and enemy.unavailableReason ~= '', 'Unavailable enemy requires a native dependency reason')
            end
            if enemy.phase ~= nil then integer(enemy.phase, 1, 'boss phase') end
            if enemy.releaseStoryHealthLock ~= nil then
                assert(name == 'bosses' and type(enemy.releaseStoryHealthLock) == 'boolean',
                    'Story health gate release is only valid for explicit boss entries')
            end
            if enemy.firstFloor == 1 and enemy.enabled ~= false then starts_available = true end
        end
        assert(starts_available, 'Enemy pool has no first-floor candidate: ' .. name)
    end
    local music = result.music
    assert(music.schema == 1 and type(music.mobs) == 'table' and #music.mobs > 0
        and type(music.bosses) == 'table', 'Missing native battle music configuration')
    local function track(value)
        assert(type(value) == 'table', 'Native music entry must be an event/state pair')
        for _, key in ipairs({'event', 'state'}) do
            assert(type(value[key]) == 'string' and value[key]:match('^/Game/Wwise/[%w_/%-]+%.[%w_%-]+$'),
                'Invalid native music asset: ' .. key)
        end
    end
    for _, value in ipairs(music.mobs) do track(value) end
    -- Only bosses with an original dedicated encounter track need an entry.
    -- Missing entries use the same random battle pool as ordinary enemies.
    for _, value in pairs(music.bosses) do track(value) end
    return result
end

return Config
