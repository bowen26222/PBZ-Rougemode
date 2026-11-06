local Native = require('Native')
local Locale = require('Locale')
local English = require('EnglishNames')
local Economy = require('Economy')
local BossPhases = require('BossPhases')
local Rng = require('Rng')
local BattleMusic = require('BattleMusic')
local DeathPresentation = require('DeathPresentation')
local HuaShan = require('HuaShanEncounter')
local BossFreeze = require('BossFreeze')
local Battle = {}
Battle.__index = Battle
local current_battle
local hooks_installed = false
local npc_path = '/Game/RenewalContent/Prototypes/Character/BP_RenewalNPC.BP_RenewalNPC_C'
local npc_native_path = '/Script/ProjectPBZ.PBZCharacter_NPC'

local function vector(value)
    return {X = value.X, Y = value.Y, Z = value.Z}
end

local function distance_squared(left, right)
    return (left.X - right.X)^2 + (left.Y - right.Y)^2 + (left.Z - right.Z)^2
end

local function actors(world, class)
    local result = {}
    Native.cdo('/Script/Engine.Default__GameplayStatics'):GetAllActorsOfClass(world, class, result)
    return Native.array(result)
end

local function member_of(battle, owner)
    return battle ~= nil and Native.valid(owner) and battle.members[owner:GetAddress()] ~= nil
end

-- Loot computed by an encounter NPC. Phase actors that never dispatched Init
-- Level still resolve through their MobGroup, so their dust is suppressed too.
local function owned_npc(battle, pawn)
    if not member_of(battle, pawn) then
        return battle ~= nil and Native.valid(pawn) and battle:owns_group(pawn.MobGroup)
    end
    return true
end

-- Native combat loot derives dust from the story loot table; our configured kill
-- reward replaces that dust for encounter members. UE4SS writes struct out
-- parameters in place (RemoteUnrealParam:set -> UScriptStruct __newindex), so
-- zeroing LootDust here leaves every other native loot entry (items, weapons,
-- medicines, accessories) untouched and never changes another actor's loot.
local function suppress_loot_dust(total)
    local data = total:get()
    if not data:IsMappedToProperty() then return end
    if data.LootDust > 0 then data.LootDust = 0 end
end

local function sync_lion_area(self)
    local area, box = self.lion_area, self.lion_area_box
    if not Native.valid(area) or not Native.valid(box) then return end
    if Native.valid(self.player) then
        area:TryUpdateActorInTriggerState(self.player, box:IsOverlappingActor(self.player))
    end
    for _, member in ipairs(self.spawned) do
        if member.enemy and member.enemy.id == 'lion_dancer_p2' and Native.valid(member.pawn) then
            area:TryUpdateActorInTriggerState(member.pawn,
                not member.dead and member.pawn:IsAlive() and box:IsOverlappingActor(member.pawn))
        end
    end
end

local function create_lion_area(self)
    local transform = {Rotation = {X = 0, Y = 0, Z = 0, W = 1},
        Scale3D = {X = 1, Y = 1, Z = 1}, Translation = vector(self.origin)}
    local class = Native.load_class('/Game/PBZContent/Blueprint/TriggerVolume/BP_LionDance_Area.BP_LionDance_Area_C')
    local area = self.spawn_library:SpawnActorDeferred(self.player, class, transform, 2)
    assert(Native.valid(area), 'Native lion dance area spawn failed')
    self.lion_area = area
    area.ShowBorder, area.ShowBottomBorder = false, false
    self.spawn_library:FinishActorSpawning(area, transform)
    -- Map instances carry cooked spline collision; a runtime instance does not.
    -- Attach query geometry to the actual native area, not a substitute actor:
    -- FindOrCreatePole discovers it through GetOverlappingActors.
    local radius = self.config.floors.arena.boundaryRadius
    local identity = {Rotation = {X = 0, Y = 0, Z = 0, W = 1},
        Scale3D = {X = 1, Y = 1, Z = 1}, Translation = {X = 0, Y = 0, Z = 0}}
    local box = area:AddComponentByClass(Native.load_class('/Script/Engine.BoxComponent'), false, identity, true)
    assert(Native.valid(box), 'Native lion dance area query box creation failed')
    self.lion_area_box = box
    box:SetMobility(2)
    box:SetBoxExtent({X = radius, Y = radius, Z = radius}, false)
    box.bCanEverAffectNavigation = false
    box:SetHiddenInGame(true, true)
    box:SetCollisionProfileName(FName('Profile_Trigger'), false)
    box:SetCollisionResponseToChannel(1, 1) -- Native poles/links are WorldDynamic.
    box:SetCollisionEnabled(1) -- Query only; never obstruct combat or pole traces.
    box:SetGenerateOverlapEvents(true)
    area:FinishAddComponent(box, false, identity)
    area:SetEnabled(true)
    -- Feed the native trigger lifecycle from the runtime query shape. It owns
    -- player jump input/ability and the boss's OptionalObject1 blackboard entry.
    sync_lion_area(self)
end

local function destroy_lion_area(self)
    local area = self.lion_area
    if not Native.valid(area) then
        self.lion_area, self.lion_area_box = nil, nil
        return
    end
    -- Snapshot active AND pooled actors before DeactivateAllPoles moves them.
    local owned = {}
    for _, field in ipairs({'ActivatedPoles', 'DeactivatedPoles', 'ActivatedLinks',
        'DeactivatedLinks', 'ActivatedRopes', 'DeactivatedRopes'}) do
        for _, actor in ipairs(Native.array(area[field])) do
            if Native.valid(actor) then owned[actor:GetAddress()] = actor end
        end
    end
    area:DeactivateAllPoles()
    if Native.valid(self.player) then area:TryUpdateActorInTriggerState(self.player, false) end
    for _, member in ipairs(self.spawned) do
        if member.enemy and member.enemy.id == 'lion_dancer_p2' and Native.valid(member.pawn) then
            area:TryUpdateActorInTriggerState(member.pawn, false)
        end
    end
    for _, actor in pairs(owned) do
        if Native.valid(actor) then actor:K2_DestroyActor() end
    end
    area:K2_DestroyActor()
    self.lion_area, self.lion_area_box = nil, nil
end

function Battle.new(player, config, rng, origin, seed)
    assert(type(seed) == 'number' and seed == math.floor(seed), 'Battle run seed must be an integer')
    local self = setmetatable({player = player, config = config, rng = rng, seed = seed, origin = vector(origin),
        members = {}, spawned = {}, spawners = {}, classes = {}, pending = {}, groups = {}, boss_groups = {},
        cleaning = false, active = false}, Battle)
    self.npc_class = Native.load_class(npc_path)
    self.spawn_library = Native.cdo('/Script/SGameAI.Default__SGameAIFunctionLibrary')
    Native.load_class('/SGameAI/FunctionLibrary/BP_SGameAIFunctionLibrary.BP_SGameAIFunctionLibrary_C')
    self.ai_library = Native.cdo('/SGameAI/FunctionLibrary/BP_SGameAIFunctionLibrary.Default__BP_SGameAIFunctionLibrary_C')
    self.navigation = Native.cdo('/Script/NavigationSystem.Default__NavigationSystemV1')
    self.player_faction = player:GetFactionComponent()
    assert(Native.valid(self.player_faction), 'Native player faction component is unavailable')
    self.factions = Native.cdo('/Script/SGameCombatSystem.Default__FactionUtils')
    self.targeting = Native.subsystem(player, '/Script/SGameCombatSystem.TargetingWorldSubsystem')
    self.combat_target_tag = {TagName = FName('Targeting.Target.Combat')}
    self.music = BattleMusic.new(player, config.music, seed)
    self.presentation = DeathPresentation.new(self)
    self.boss_freeze = BossFreeze.new(self)
    current_battle = self
    if not hooks_installed then
        RegisterHook(npc_path .. ':Init Level', function(context)
            local battle, pawn = current_battle, context:get()
            if not battle or not Native.valid(pawn) then return end
            local member = battle.members[pawn:GetAddress()]
            if not member and battle:owns_group(pawn.MobGroup) then
                -- Boss summons join their owner's group without a configured
                -- reward entry: they are tracked and cleaned, never paid.
                member = {pawn = pawn, level = battle.level, dead = false,
                    id = pawn:GetFullName(), group = pawn.MobGroup}
                battle.members[pawn:GetAddress()] = member
                battle.spawned[#battle.spawned + 1] = member
            end
            if member then pawn.Level = member.level end
        end)
        RegisterHook(npc_path .. ':On Dead', function(context)
            local battle, pawn = current_battle, context:get()
            local member = battle and Native.valid(pawn) and battle.members[pawn:GetAddress()]
            if not member then return end
            member.dead = true
            battle.presentation:arm(member)
            -- Death notifications arrive inside the native death dispatch; only
            -- queue the wallet write and flush it from Battle:remaining/clean.
            battle:queue_reward(member)
        end)
        RegisterHook(npc_path .. ':On Dead Cancel', function(context, end_states)
            local battle, pawn = current_battle, context:get()
            local member = battle and Native.valid(pawn) and battle.members[pawn:GetAddress()]
            if not member then return end
            -- This callback receives every state exit; native NPC logic only
            -- treats leaving CharacterState.Dead as a cancelled death.
            for _, state in ipairs(Native.array(end_states:get())) do
                if Native.name(state.TagName) == 'CharacterState.Dead' then
                    member.dead = false
                    battle.presentation:cancel(member)
                    battle:cancel_reward(member)
                    break
                end
            end
        end)
        -- The post-hook parameter order differs per function and includes out
        -- structs and the return value, so locate the loot struct and owner objects
        -- by shape instead of by position.
        local function value_of(value)
            if type(value) == 'table' then return value end
            if type(value) ~= 'userdata' then return nil end
            local ok, data = pcall(function() return value:get() end)
            return ok and data or nil
        end
        local function is_object(value)
            local object = value_of(value)
            if type(object) ~= 'table' then return nil end
            local ok, valid = pcall(Native.valid, object)
            return ok and valid and object or nil
        end
        local function suppress_from_hook(context, ...)
            local battle = current_battle
            if not battle then return end
            local total
            for _, value in ipairs({context, ...}) do
                local data = value_of(value)
                if type(data) == 'table' then
                    local ok, mapped = pcall(function()
                        return data.LootDust ~= nil and data:IsMappedToProperty()
                    end)
                    if ok and mapped then total = value; break end
                end
            end
            if not total then return end
            local owned = false
            local self_object = is_object(context)
            if self_object then owned = owned_npc(battle, self_object) end
            if not owned then
                for _, value in ipairs({...}) do
                    local object = is_object(value)
                    if object and owned_npc(battle, object) then owned = true; break end
                end
            end
            if owned then suppress_loot_dust(total) end
        end
        RegisterHook(npc_native_path .. ':GetCombatLootDataBySelf', function() end,
            function(context, ...) suppress_from_hook(context, ...) end)
        RegisterHook(npc_native_path .. ':GetCombatLootDataForOwner', function() end,
            function(context, ...) suppress_from_hook(context, ...) end)
        RegisterHook(npc_native_path .. ':GetCombatLootData', function() end,
            function(context, ...) suppress_from_hook(context, ...) end)
        hooks_installed = true
    end
    return self
end

function Battle:set_health_lock(enabled)
    local library = Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary')
    if enabled then
        if self.gm_health_handle and library:IsActiveGameplayEffectHandleActive(self.gm_health_handle) then return end
        local path = '/PBZCombatAsset/Prototypes/GameplayEffects/GE_IgnoreAllDamage'
        local class = Native.load_class(path .. '.GE_IgnoreAllDamage_C')
        local defaults = Native.cdo(path .. '.Default__GE_IgnoreAllDamage_C')
        assert(defaults.DurationPolicy == 1 and defaults.StackingType == 0,
            'GM damage immunity must be an independent infinite native effect')
        local asc = library:GetAbilitySystemComponent(self.player)
        local handle = asc:BP_ApplyGameplayEffectToSelf(class, 1, {})
        assert(library:IsActiveGameplayEffectHandleActive(handle), 'Native damage immunity was not applied')
        self.gm_health_handle, self.gm_health_asc = handle, asc
    elseif self.gm_health_handle then
        if Native.valid(self.gm_health_asc) then
            self.gm_health_asc:RemoveActiveGameplayEffect(self.gm_health_handle, -1)
            assert(not library:IsActiveGameplayEffectHandleActive(self.gm_health_handle),
                'Native damage immunity could not be removed')
        end
        self.gm_health_handle, self.gm_health_asc = nil, nil
    end
end

function Battle:health_locked()
    return self.gm_health_handle ~= nil
        and Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary')
            :IsActiveGameplayEffectHandleActive(self.gm_health_handle)
end

function Battle:owns_group(group)
    if not Native.valid(group) then return false end
    local address = group:GetAddress()
    for _, owned in ipairs(self.groups) do
        if Native.valid(owned) and owned:GetAddress() == address then return true end
    end
    return false
end

function Battle:new_group()
    local group = Native.retain(Native.construct('/Script/SGameAI.MobGroup', self.domain))
    self.groups[#self.groups + 1] = group
    return group
end

function Battle:queue_reward(member)
    if self.cleaning or not member.enemy or member.paid or member.pending then return end
    member.pending = true
    self.pending[#self.pending + 1] = member
end

function Battle:cancel_reward(member)
    if not member.pending then return end
    member.pending = false
    for index = #self.pending, 1, -1 do
        if self.pending[index] == member then table.remove(self.pending, index) end
    end
end

function Battle:flush_rewards()
    if #self.pending == 0 then return end
    local pending = self.pending
    self.pending = {}
    for _, member in ipairs(pending) do
        if member.pending then
            member.pending, member.paid = false, true
            if member.reward > 0 then Economy.award(self.player, member.reward) end
        end
    end
end

local function wave_size(config, pool, floor, wave_index, rng)
    local stage = Economy.stage(config, pool, floor)
    -- Mobs advance by wave index; every boss wave uses the single boss entry.
    local index = pool == 'bosses' and 1 or wave_index
    local range = assert(stage.waves and stage.waves[index],
        string.format(Locale.text('经济表缺少 %s 第 %d 波数量', 'Economy table is missing the count for %s wave %d'), pool, index))
    local minimum, maximum = range.minimum, range.maximum
    assert(type(minimum) == 'number' and type(maximum) == 'number' and minimum % 1 == 0
        and maximum % 1 == 0 and minimum >= 1 and maximum >= minimum,
        string.format(Locale.text('经济表 %s 第 %d 波数量无效', 'Economy table has an invalid count for %s wave %d'), pool, index))
    return minimum + rng:integer(maximum - minimum + 1) - 1
end

local function eligible_enemies(config, pool, floor)
    local candidates = {}
    for _, enemy in ipairs(config.enemy_pools[pool] or {}) do
        if enemy.enabled ~= false and enemy.firstFloor <= floor then candidates[#candidates + 1] = enemy end
    end
    assert(Economy.has_candidates(config, pool, floor, candidates),
        string.format(Locale.text('第 %d 层 %s 池没有可用档位与敌人', 'Floor %d has no eligible tiers or enemies in pool %s'), floor, pool))
    return candidates
end

local function boss_name(library, texts, enemy, language)
    local name = language == 'zh'
        and Native.name(texts:Conv_TextToString(library:MakeTextByKey(enemy.nameKey)))
        or English.get(enemy.nameKey)
    assert(name ~= '' and name ~= enemy.nameKey, Locale.text('Boss 缺少原生显示名称: ', 'Boss has no native display name: ') .. enemy.id)
    return name
end

-- A GM scenario replaces random generation on its floor only. Clearing it
-- returns the battle to the configured pools without rebuilding the battle.
function Battle:set_custom_waves(custom)
    self.custom = custom
    self.boss_plan = nil
end

function Battle:boss_preview(floor)
    local language = Locale.language()
    if self.boss_plan and self.boss_plan.floor == floor and self.boss_plan.language == language then return self.boss_plan end
    local library = Native.cdo('/Script/ProjectPBZ.Default__PBZBlueprintFunctionLibrary')
    local texts = Native.cdo('/Script/Engine.Default__KismetTextLibrary')
    local custom = self.custom and self.custom.boss
    if custom then
        local plan = {floor = floor, language = language, names = {}, enemies = custom, custom = true}
        for index, enemy in ipairs(custom) do plan.names[index] = boss_name(library, texts, enemy, language) end
        self.boss_plan = plan
        return plan
    end
    -- Keep only one floor. Rebuilding after a checkpoint or cache eviction uses
    -- the run seed, never the combat RNG.
    -- Reduce the seed before mixing so saved seeds up to 2^53-1 stay exact.
    local seed = (self.seed % 2147483646 + (floor % 2147483646) * 104729 + 130363) % 2147483646
    local rng = Rng.new(seed)
    local candidates = eligible_enemies(self.config, 'bosses', floor)
    local count = wave_size(self.config, 'bosses', floor, 1, rng)
    local plan = {floor = floor, language = language, names = {}, enemies = {}}
    for index = 1, count do
        local enemy = assert(Economy.choose(self.config, 'bosses', floor, candidates, rng),
            string.format(Locale.text('第 %d 层 bosses 池没有可抽取的敌人', 'Floor %d has no eligible enemies in the bosses pool'), floor))
        plan.enemies[index], plan.names[index] = enemy, boss_name(library, texts, enemy, language)
    end
    self.boss_plan = plan
    return plan
end

function Battle:clear_native_encounters()
    local flow = Native.subsystem(self.player, '/Script/Flow.FlowSubsystem')
    local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
    local cinematic = {}
    for _, path in ipairs(self.config.floors.arena.cinematicFlows) do cinematic[path] = true end
    -- Find the configured intro flows through the flow subsystem itself. Scanning
    -- every actor's components is unsafe: level transitions leave actors pending
    -- destruction whose UE4SS array wrappers cannot be iterated.
    local function resolved(value)
        if type(value) ~= 'userdata' then return value end
        local ok, kind = pcall(function() return value:type() end)
        if ok and (kind == 'RemoteUnrealParam' or kind == 'LocalUnrealParam') then
            local unwrapped, object = pcall(function() return value:get() end)
            return unwrapped and object or nil
        end
        return value
    end
    local matches = {}
    local instances = flow:GetRootInstances()
    if type(instances) == 'table' then
        for key, value in pairs(instances) do
            local template = resolved(key)
            if Native.valid(template) and cinematic[Native.name(system:GetPathName(template))] then
                matches[#matches + 1] = {template = template, instance = resolved(value)}
            end
        end
    else
        instances:ForEach(function(key, value)
            local template = resolved(key)
            if Native.valid(template) and cinematic[Native.name(system:GetPathName(template))] then
                matches[#matches + 1] = {template = template, instance = resolved(value)}
            end
        end)
    end
    for _, entry in ipairs(matches) do
        local owner = Native.valid(entry.instance) and entry.instance:GetOwner() or nil
        if Native.valid(owner) then
            if owner:IsA('/Script/Flow.FlowComponent') then owner.bAutoStartRootFlow = false end
            flow:FinishRootFlow(owner, entry.template, 1)
            local actor = owner:IsA('/Script/Engine.Actor') and owner or nil
            if not actor and owner:IsA('/Script/Engine.ActorComponent') then actor = owner:GetOwner() end
            if Native.valid(actor) then actor:K2_DestroyActor() end
        end
    end
    -- Story spawners are cancelled through the SGameAI registry, again without
    -- walking the whole actor list.
    local ai = Native.subsystem(self.player, '/Script/SGameAI.SGameAIWorldSubsystem')
    for _, spawner in ipairs(Native.array(ai:GetAllSpawners())) do
        if Native.valid(spawner) then
            spawner:CancelPendingSpawnCompletely()
            local actor = spawner:IsA('/Script/Engine.Actor') and spawner or nil
            if not actor and spawner:IsA('/Script/Engine.ActorComponent') then actor = spawner:GetOwner() end
            if Native.valid(actor) then actor:K2_DestroyActor() end
        end
    end
end

function Battle:preload()
    local transform = {Rotation = {X = 0, Y = 0, Z = 0, W = 1}, Scale3D = {X = 1, Y = 1, Z = 1},
        Translation = vector(self.origin)}
    local domain_class = Native.load_class('/SGameAI/Tools/MobDomain/BP_MobDomain.BP_MobDomain_C')
    self.domain = self.spawn_library:SpawnActorDeferred(self.player, domain_class, transform, 2)
    assert(Native.valid(self.domain), 'Native mob domain spawn failed')
    self.domain.HiddenIngame = true
    self.domain.ShowBorder = false
    self.domain.ShowTopBorder = false
    self.domain.ShowBottomBorder = false
    self.domain:SetActorEnableCollision(false)
    self.spawn_library:FinishActorSpawning(self.domain, transform)
    -- This mode owns membership and its arena boundary, rather than the map's encounter triggers.
    self.domain:SetActorEnableCollision(false)
    self.domain.ActorsInMobDomain = {self.player}
    -- MobGroup resolves IMobDomainInterface through its Outer; a player pawn cannot serve as that owner.
    -- Mob waves share this group; every boss needs its own group so group-keyed
    -- shared health pools stay separate.
    self.mob_group = self:new_group()
    self:create_boundary()
end

function Battle:create_boundary()
    local boundary = self.config.floors.arena.stairWall
    local actor_class = Native.load_class('/Script/Engine.Actor')
    local box_class = Native.load_class('/Script/Engine.BoxComponent')
    local identity = {Translation = {X = 0, Y = 0, Z = 0},
        Rotation = {X = 0, Y = 0, Z = 0, W = 1}, Scale3D = {X = 1, Y = 1, Z = 1}}
    local first, last = boundary.start, boundary.finish
    local dx, dy = last.X - first.X, last.Y - first.Y
    local length, half_angle = math.sqrt(dx * dx + dy * dy), math.atan(dy, dx) / 2
    local transform = {
        Translation = {X = (first.X + last.X) / 2, Y = (first.Y + last.Y) / 2,
            Z = boundary.baseZ + (boundary.height - boundary.depth) / 2},
        Rotation = {X = 0, Y = 0, Z = math.sin(half_angle), W = math.cos(half_angle)},
        Scale3D = {X = 1, Y = 1, Z = 1}
    }
    local wall = self.spawn_library:SpawnActorDeferred(self.player, actor_class, transform, 2)
    assert(Native.valid(wall), 'Stairway collision wall spawn failed')
    self.wall = wall
    self.spawn_library:FinishActorSpawning(wall, transform)
    local box = wall:AddComponentByClass(box_class, false, identity, true)
    assert(Native.valid(box), 'Stairway collision box creation failed')
    box:SetMobility(2)
    box:SetBoxExtent({X = length / 2 + boundary.thickness, Y = boundary.thickness / 2,
        Z = (boundary.height + boundary.depth) / 2}, false)
    box.bCanEverAffectNavigation = false
    box.CanCharacterStepUpOn = 0
    box:SetGenerateOverlapEvents(false)
    box:SetHiddenInGame(true, true)
    box:SetCollisionObjectType(0)
    box:SetCollisionResponseToAllChannels(0)
    box:SetCollisionResponseToChannel(2, 2) -- Native player capsule.
    box:SetCollisionResponseToChannel(19, 2) -- Native AIPawn, not the player's Pawn channel.
    box:SetCollisionEnabled(3)
    wall:FinishAddComponent(box, false, identity)
    assert(Native.same(wall.RootComponent, box), 'Stairway collision box is not the actor root')
    assert(wall:K2_SetActorTransform(transform, false, {}, true), 'Stairway collision wall placement failed')
end

function Battle:spawn_point(used)
    local arena = self.config.floors.arena
    local player_location = self.player:K2_GetActorLocation()
    for _ = 1, 64 do
        local angle = self.rng:unit() * math.pi * 2
        local radius = arena.minimumPlayerDistance + self.rng:unit() * (arena.spawnRadius - arena.minimumPlayerDistance)
        local requested = {X = self.origin.X + math.cos(angle) * radius,
            Y = self.origin.Y + math.sin(angle) * radius, Z = self.origin.Z}
        local projected = {}
        local found = self.navigation:K2_ProjectPointToNavigation(self.player, requested, projected, nil, nil,
            {X = 180, Y = 180, Z = 800})
        if found and distance_squared(projected, player_location) >= arena.minimumPlayerDistance^2 then
            local separated = true
            for _, existing in ipairs(used) do
                if distance_squared(projected, existing) < arena.minimumEnemyDistance^2 then separated = false; break end
            end
            if separated then
                local path = self.navigation:FindPathToLocationSynchronously(self.player, player_location, projected, self.player, nil)
                if Native.valid(path) and path:IsValid() and not path:IsPartial() then return projected end
            end
        end
    end
    error(Locale.text('场地没有足够的可达刷怪点；请检查 floors.json 的场地与距离配置',
        'The arena has too few reachable spawn points; check the arena and distance settings in floors.json'))
end

function Battle:register_combat_target(member)
    local targets = {}
    self.targeting:GetTargetsByTag(self.combat_target_tag, false, targets)
    for _, target in ipairs(Native.array(targets)) do
        if Native.same(target, member.pawn) then return end
    end
    -- The base NPC registers during BeginPlay or CompleteSpawnAI. Deferred
    -- tower spawns have no story spawner: establish the same registry invariant
    -- after subclass initialization, without duplicating a base registration.
    self.targeting:RegisterTarget(member.pawn, self.combat_target_tag)
    member.registered_target = true
    targets = {}
    self.targeting:GetTargetsByTag(self.combat_target_tag, false, targets)
    for _, target in ipairs(Native.array(targets)) do
        if Native.same(target, member.pawn) then return end
    end
    error('Native combat target was not registered: ' .. member.id)
end

function Battle:activate_member(member)
    if member.combat_ready then return true end
    local pawn = member.pawn
    local controller = pawn:GetController()
    if not Native.valid(controller) then return false end
    local ai = controller.SGameAIComponent
    if not Native.valid(ai) or not ai.bInitialized or not Native.same(ai.Pawn, pawn) then return false end
    member.faction = pawn:GetFactionComponent()
    if not Native.valid(member.faction) then return false end
    -- Runtime members join after preload admitted the player to the arena.
    -- Deliver the native domain-entry lifecycle before encounter hostility:
    -- AIScript_PBZMisc releases its saved precombat-protection effect here,
    -- not on AI.State.Combat, and clears that protection's faction override.
    assert(self.domain:IsActorInMobDomain(self.player), 'Player is outside the encounter domain')
    ai:OnActorEnterDomain(self.player)
    -- Apply the encounter relationship after group activation, including NPCs
    -- created later by a boss. Init Level alone does not make those actors targets.
    member.faction:SetFactionRelationOverride(self.player, 2, true)
    assert(controller:BlueprintGetTeamAttitudeTowards(self.player) == 2
        and self.factions:GetFactionRelation(self.player, pawn) == 2
        and self.factions:GetFactionRelation(pawn, self.player) == 2,
        'Native lock-on hostility is not reciprocal: ' .. member.id)
    self.ai_library:ActivateAI(pawn, self.player)
    self.ai_library:ForceIntoCombat(pawn, self.player, self.player)
    self:register_combat_target(member)
    member.combat_ready = true
    return true
end

-- Keep the native spawner context for mounted enemies and subclass spawning.
-- SpawnAIDefered calls OnSpawnFromSpawner before returning, so its group must
-- already be correct. Native SpawnAI also assigns the separate spawner interface
-- before FinishActorSpawning; the deferred helper alone does not do that.
function Battle:_spawn_native(class, transform, group, enemy, spawner)
    if not spawner then
        local spawner_class = Native.load_class('/SGameAI/Tools/Spawner/BP_AISpawner.BP_AISpawner_C')
        spawner = self.spawn_library:SpawnActorDeferred(self.player, spawner_class, transform, 2)
        assert(Native.valid(spawner), 'Native AI spawner creation failed')
        self.spawners[#self.spawners + 1] = spawner
        spawner:SetActorEnableCollision(false)
        spawner:SetActorHiddenInGame(true)
        self.spawn_library:FinishActorSpawning(spawner, transform)
        spawner.MobGroup = group
        if enemy.id == 'xiaoxue' then
            -- The native shared pool respawns its anchor through this spawner.
            local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
            spawner:SetClassToSpawn(system:Conv_SoftClassPathToSoftClassRef(system:MakeSoftClassPath(enemy.class)))
        end
    end
    local pawn = self.ai_library:SpawnAIDefered(class, transform, spawner, self.player)
    assert(Native.valid(pawn), 'Native deferred AI spawn failed')
    pawn:SetAISpawnerInterface(spawner)
    return pawn
end

function Battle:start(floor, wave_index)
    assert(not self.active, 'Cannot overlap combat waves')
    local continue_mob_music = wave_index == 2 and self.wave == 1
        and self.floor == floor and self.music.held
    self:clean()
    self.floor, self.wave = floor, wave_index
    local levels = self.config.floors.level
    self.level = (levels.byFloor and levels.byFloor[tostring(floor)])
        or (levels.first + (floor - 1) * levels.perFloor)
    local wave = assert(self.config.floors.waves[wave_index],
        string.format(Locale.text('缺少第 %d 波配置', 'Missing configuration for wave %d'), wave_index))
    local pool = assert(wave.pool, string.format(Locale.text('第 %d 波缺少敌人池', 'Wave %d has no enemy pool'), wave_index))
    local boss_wave = pool == 'bosses'
    -- A GM floor supplies the exact lineup for its two mob waves and boss wave.
    local custom = self.custom and (boss_wave and self.custom.boss or (self.custom.mobs and self.custom.mobs[wave_index])) or nil
    local preview = boss_wave and not custom and self:boss_preview(floor) or nil
    local candidates
    if not boss_wave and not custom then candidates = eligible_enemies(self.config, pool, floor) end
    local count = custom and #custom or (preview and #preview.enemies or wave_size(self.config, pool, floor, wave_index, self.rng))
    -- Mobs retain their independent tier/member draws interleaved with spawn
    -- locations; bosses use the exact ordered enemies announced before combat.
    -- The first boss shares the encounter group; additional simultaneous
    -- bosses use separate groups so their group-keyed health pools cannot merge.
    local plan, points = {}, {}
    for index = 1, count do
        local enemy = custom and custom[index] or (preview and preview.enemies[index])
            or assert(Economy.choose(self.config, pool, floor, candidates, self.rng),
                string.format(Locale.text('第 %d 层 %s 池没有可抽取的敌人', 'Floor %d has no eligible enemies in pool %s'), floor, pool))
        assert(type(enemy.reward) == 'number' and enemy.reward >= 0 and enemy.reward % 1 == 0,
            Locale.text('击杀奖励配置无效: ', 'Invalid kill reward configuration: ') .. tostring(enemy.id))
        local location = self:spawn_point(points)
        points[#points + 1] = location
        local group
        if boss_wave and index > 1 then
            group = self.boss_groups[index]
            if not Native.valid(group) then
                group = self:new_group()
                self.boss_groups[index] = group
            end
        else
            if not Native.valid(self.mob_group) then self.mob_group = self:new_group() end
            group = self.mob_group
        end
        plan[index] = {enemy = enemy, location = location, group = group}
    end
    local spawn_plan = HuaShan.expand(self, plan)
    for _, entry in ipairs(plan) do
        if entry.enemy.id == 'lion_dancer_p2' then
            create_lion_area(self)
            break -- Simultaneous flame lions share one native pole area.
        end
    end
    self.music_plan, self.music_index = boss_wave and plan or nil, 1
    if not continue_mob_music then
        self.music:play(boss_wave and self.music:boss_track(plan[1].enemy.id)
            or self.music:mob_track())
    end
    local blocked = {}
    for _, entry in ipairs(plan) do
        if not blocked[entry.group] then
            entry.group:AddClearBlocker(self.player)
            blocked[entry.group] = true
        end
    end
    for _, entry in ipairs(spawn_plan) do
        local class = self.classes[entry.enemy.id] or Native.load_class(entry.enemy.class)
        self.classes[entry.enemy.id] = class
        local capsule = class:GetCDO().CapsuleComponent
        assert(Native.valid(capsule), 'Native enemy capsule is unavailable: ' .. entry.enemy.id)
        local half_height = capsule:GetScaledCapsuleHalfHeight()
        local transform = entry.transform or {Rotation = {X = 0, Y = 0, Z = 0, W = 1}, Scale3D = {X = 1, Y = 1, Z = 1},
            Translation = {X = entry.location.X, Y = entry.location.Y, Z = entry.location.Z + half_height + 5}}
        local pawn = self:_spawn_native(class, transform, entry.group, entry.enemy, entry.spawner)
        assert(Native.valid(pawn), 'Native enemy spawn failed: ' .. entry.enemy.id)
        -- OnSpawnFromSpawner runs Init Level and may already register this
        -- owned-group actor; promote that entry rather than tracking it twice.
        local member = self.members[pawn:GetAddress()]
        if not member then
            member = {pawn = pawn, level = self.level, dead = false, group = entry.group}
            self.members[pawn:GetAddress()] = member
            self.spawned[#self.spawned + 1] = member
        end
        member.id = entry.enemy.id
        if not entry.auxiliary then member.enemy, member.reward = entry.enemy, entry.enemy.reward end
        entry.member = member
        pawn.MobGroup = entry.group
        pawn.Level = self.level
        -- Placed troop members are represented by spawners, never a second pawn
        -- entry: native SoldierDead accounting must see the leader exactly once.
        if not entry.spawner then entry.group:AddRuntimeMember(pawn) end
        self.spawn_library:FinishActorSpawning(pawn, transform)
        assert(Native.valid(pawn) and pawn:IsAlive(), 'Native enemy did not initialize alive: ' .. entry.enemy.id)
        assert(pawn.Level == self.level and Native.same(pawn.MobGroup, entry.group),
            'Native enemy initialized with the wrong encounter group/level: ' .. entry.enemy.id)
        BossPhases.prepare(pawn, entry.enemy, entry.group)
        if not Native.valid(pawn:GetController()) then pawn:SpawnDefaultController() end
        local controller = pawn:GetController()
        assert(Native.valid(controller), 'Native enemy controller is unavailable: ' .. entry.enemy.id)
        local ai = controller.SGameAIComponent
        assert(Native.valid(ai) and ai.bInitialized and Native.same(ai.Pawn, pawn),
            'Native enemy AI did not initialize: ' .. entry.enemy.id)
        if entry.enemy.id == 'lion_dancer_p2' then sync_lion_area(self) end
        if entry.spawner then
            -- Original completion installs native death/combat watchers and
            -- dispatches group spawn notifications after the pawn is ready.
            entry.spawner:K2_OnAISpawnReady(pawn)
            entry.spawner.ShouldSpawn = true
        end
    end
    for _, entry in ipairs(plan) do
        if blocked[entry.group] then
            entry.group:RemoveClearBlocker(self.player, false)
            blocked[entry.group] = nil
        end
    end
    for _, entry in ipairs(plan) do
        if entry.group and not blocked[entry.group] then
            self.domain:ActivateGroupInternal(entry.group)
            blocked[entry.group] = true
        end
    end
    for _, member in ipairs(self.spawned) do
        local ready = self:activate_member(member)
        assert(ready or not member.enemy, 'Native enemy combat setup failed: ' .. member.id)
    end
    self.active = true
    local ids = {}
    for _, entry in ipairs(plan) do ids[#ids + 1] = entry.enemy.id end
    print(string.format('[PBZRogue] Floor %d wave %d (%s): %d enemies, native level %d: %s\n',
        floor, wave_index, pool, count, self.level, table.concat(ids, ', ')))
end

-- Enemies can be pushed through geometry or fall out of the arena. Recover them
-- onto reachable ground near the player so a wave cannot stall on an unreachable
-- straggler. The cooldown keeps a repeatedly escaping actor from teleporting every
-- frame while the native AI sorts itself out.
function Battle:_recovery_point(member)
    local arena = self.config.floors.arena
    local address = member.pawn:GetAddress()
    local angle = (address % 628) / 100
    local radius = arena.minimumPlayerDistance + 200
    local requested = {X = self.origin.X + math.cos(angle) * radius,
        Y = self.origin.Y + math.sin(angle) * radius, Z = self.origin.Z}
    local projected = {}
    local found = self.navigation:K2_ProjectPointToNavigation(self.player, requested, projected, nil, nil,
        {X = 180, Y = 180, Z = 800})
    if found and distance_squared(projected, self.origin) <= arena.boundaryRadius^2 then return projected end
    return vector(self.origin)
end

function Battle:_recover_member(member)
    local pawn = member.pawn
    if not Native.valid(pawn) then return end
    local position = pawn:K2_GetActorLocation()
    local arena = self.config.floors.arena
    local outside = distance_squared(position, self.origin) > arena.boundaryRadius^2
    if self.lion_area and member.enemy and member.enemy.id == 'lion_dancer_p2' then
        outside = (position.X - self.origin.X)^2 + (position.Y - self.origin.Y)^2 > arena.boundaryRadius^2
    end
    local below = position.Z < self.origin.Z - 1500
    if not outside and not below then return end
    -- Teleporting bosses legitimately blink outside the radius. Only rescue an
    -- actor that is truly unreachable: navigation must have no full path to it.
    local player_location = self.player:K2_GetActorLocation()
    local path = self.navigation:FindPathToLocationSynchronously(self.player, player_location, position, self.player, nil)
    if Native.valid(path) and path:IsValid() and not path:IsPartial() then return end
    local now = Native.cdo('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(self.player)
    if member.recovered_at and now - member.recovered_at < 5 then return end
    member.recovered_at = now
    local destination = self:_recovery_point(member)
    -- Navigation returns ground height; spawns use capsule half-height + offset.
    -- Teleporting at ground level buries the actor (invisible but alive).
    local capsule = pawn:GetClass():GetCDO().CapsuleComponent
    if Native.valid(capsule) then destination.Z = destination.Z + capsule:GetScaledCapsuleHalfHeight() + 5 end
    local moved = pawn:K2_TeleportTo(destination, pawn:K2_GetActorRotation())
    print(string.format('[PBZRogue] Recovered out-of-arena enemy %s at %.0f,%.0f,%.0f moved=%s\n',
        member.id, position.X, position.Y, position.Z, tostring(moved)))
end

function Battle:remaining()
    assert(self.active and #self.spawned > 0, 'Cannot clear a wave that never spawned')
    self.boss_freeze:update()
    sync_lion_area(self)
    local alive = 0
    for _, member in ipairs(self.spawned) do
        if not member.dead then
            if not Native.valid(member.pawn) then
                -- The pawn was destroyed without a native death event. Keep the wave
                -- alive for a short grace period, then drop the missing member so a
                -- vanished actor cannot soft-lock the run (no reward is paid).
                local now = Native.cdo('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(self.player)
                member.missing_at = member.missing_at or now
                if now - member.missing_at > 3 then
                    print('[PBZRogue] wave member vanished without a death event: ' .. member.id .. '\n')
                    member.dead = true
                else
                    alive = alive + 1
                end
            else
                if member.enemy and member.enemy.id == 'zuo_shang' then
                    BossPhases.prepare(member.pawn, member.enemy, member.group)
                end
                if not self.boss_freeze:is_held(member) then self:_recover_member(member) end
                if not self:activate_member(member) or member.pawn:IsAlive() then
                    alive = alive + 1
                else
                    -- Native death without a dispatched On Dead still counts once.
                    member.dead = true
                    self.presentation:arm(member)
                    self:queue_reward(member)
                end
            end
        end
    end
    -- Native writes stay outside the death hook; legitimate deaths are paid here.
    self:flush_rewards()
    if self.music_plan and self.music_index <= #self.music_plan
        and self.music_plan[self.music_index].member.dead then
        -- Simultaneous bosses share one soundtrack: the announced first survivor
        -- owns it. Native phase actions may change that track without replay here.
        repeat self.music_index = self.music_index + 1
        until self.music_index > #self.music_plan or not self.music_plan[self.music_index].member.dead
        if self.music_index <= #self.music_plan then
            self.music:play(self.music:boss_track(self.music_plan[self.music_index].enemy.id))
        end
    end
    if alive == 0 then
        local cleared = true
        for _, group in ipairs(self.groups) do
            if Native.valid(group) and (group:HasPendingMembers() or group:HasClearBlockers()
                or group:HasAliveRuntimeMembers()) then
                cleared = false
                break
            end
        end
        if cleared and self.presentation:complete() then
            self.active = false
            return 0
        end
    end
    return math.max(alive, 1)
end

function Battle:enforce_boundary()
    local position = self.player:K2_GetActorLocation()
    local distance = distance_squared(position, self.origin)
    if self.lion_area then
        -- Pole height alone must not teleport the player out of a valid jump.
        distance = (position.X - self.origin.X)^2 + (position.Y - self.origin.Y)^2
        if position.Z < self.origin.Z - 1500 then distance = math.huge end
    end
    if distance > self.config.floors.arena.boundaryRadius^2 then
        local destination = vector(self.origin)
        local moved = self.player:K2_TeleportTo(destination, self.player:K2_GetActorRotation())
        assert(moved, 'Cannot return player to the tower arena')
    end
end

function Battle:clean()
    -- Rewards earned by real deaths are flushed before teardown; destroying
    -- actors afterwards can neither queue nor duplicate a payment.
    self.cleaning = true
    self.boss_freeze:clear(false)
    self.presentation:clear()
    self:flush_rewards()
    self.active = false
    for _, group in ipairs(self.groups) do
        if Native.valid(group) then group:Deactivate() end
    end
    if Native.valid(self.domain) then self.domain.ActivatingGroups:Empty() end
    for _, member in ipairs(self.spawned) do
        if Native.valid(member.pawn) then
            if member.registered_target then
                self.targeting:UnregisterTarget(member.pawn, self.combat_target_tag)
            end
            if Native.valid(member.faction) then
                member.faction:ClearFactionRelationOverride(self.player)
                if Native.valid(self.player_faction) then
                    self.player_faction:ClearFactionRelationOverride(member.pawn)
                end
            end
            if Native.valid(member.group) then member.group:RemoveRuntimeMember(member.pawn) end
            member.pawn:K2_DestroyActor()
        end
    end
    for _, spawner in ipairs(self.spawners) do
        if Native.valid(spawner) then
            spawner:CancelPendingSpawnCompletely()
            spawner:K2_DestroyActor()
        end
    end
    destroy_lion_area(self)
    self.spawners = {}
    self.members, self.spawned, self.pending = {}, {}, {}
    for _, group in ipairs(self.groups) do
        if Native.valid(group) then group:ClearInvalidMembers() end
    end
    HuaShan.release(self)
    self.music_plan, self.music_index = nil, nil
    self.cleaning = false
end

function Battle:destroy(world_ended)
    if world_ended then self.boss_freeze:clear(true) end
    if not world_ended then
        self:set_health_lock(false)
        self:clean()
        self.music:stop(false)
        if Native.valid(self.domain) then self.domain:K2_DestroyActor() end
        if Native.valid(self.wall) then self.wall:K2_DestroyActor() end
    end
    self.gm_health_handle, self.gm_health_asc = nil, nil
    self.lion_area, self.lion_area_box = nil, nil
    self.huashan_groups = nil
    self.active = false
    self.members, self.spawned, self.pending, self.spawners = {}, {}, {}, {}
    self.presentation:destroy()
    for _, group in ipairs(self.groups) do Native.release(group) end
    self.groups, self.boss_groups = {}, {}
    self.mob_group, self.wall, self.domain = nil, nil, nil
    if current_battle == self then current_battle = nil end
end

return Battle
