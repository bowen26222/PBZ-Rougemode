local Native = require('Native')
local HuaShan = {}
local root = '/PBZCombatAsset/ActorData/Mobs/035_HuaShan/'
local common = '/PBZCombatAsset/ActorData/Mobs/Common/SGameAIExtension/'
local spawner_path = '/SGameAI/Tools/Spawner/BP_AISpawner.BP_AISpawner_C'

-- Original placed spawner order and world-axis offsets from each leader.
-- Zhengdaodaying DefaultGroup / Pangzhen PBZ_MobDomain10; terrain height is
-- projected onto this arena rather than copying the original map's elevation.
local formations = {
    hua_shan_blue = {
        follower = 'BP_Monster_HuaShan_White',
        slots = {
            {-534.931, 428.420, 85}, {-854.150, 636.650, 75}, {-1162.523, 884.120, 75},
            {0, 0, 100, leader = true}, {301.930, 239.090, 120},
            {216.602, 403.850, 115}, {-80.504, 823.390, 120},
        },
    },
    hua_shan_red_troop_big_bro = {
        follower = 'BP_Monster_HuaShan_RedTroop_Soldier',
        slots = {
            {-558.345, 1019.865, -93.01113}, {1301.461, 429.815, -143.14662},
            {-62.675, 417.285, -282.31198}, {584.070, 211.525, -202.31198},
            {0, 0, -112.31198, leader = true}, {-279.975, 1392.705, -22.31198},
            {804.685, 1133.425, -112.31198},
        },
    },
}

local function script(path, group)
    local name = path:match('/([^/]+)$')
    return Native.construct(path .. '.' .. name .. '_C', group)
end

function HuaShan.expand(battle, plan)
    local expanded = {}
    local system = Native.cdo('/Script/Engine.Default__KismetSystemLibrary')
    for _, leader in ipairs(plan) do
        local formation = formations[leader.enemy.id]
        if not formation then
            expanded[#expanded + 1] = leader
        else
            -- Never reuse a group carrying a latent native phase-completion task
            -- for another encounter, including a GM replacement of this wave.
            local group = battle:new_group()
            leader.group = group
            battle.huashan_groups = battle.huashan_groups or {}
            battle.huashan_groups[#battle.huashan_groups + 1] = group
            local scripts = {}
            local blue = leader.enemy.id == 'hua_shan_blue'
            if blue then
                scripts[#scripts + 1] = script('/SGameAI/Tools/MobDomain/MobGroupScript_CombatNotify', group)
                local phase = script(common .. 'Customize/MobGroupScript_BossCombat_JianZhen_Phase1', group)
                -- Keep the native terminal condition/task/deactivation, not its
                -- story tags, cutscenes or independently selected JianOu phase.
                phase.EventTag = {GameplayTags = {}, ParentTags = {}}
                scripts[#scripts + 1] = phase
                local tags = script(common .. 'MobGroupScript_PlayerCombatTags', group)
                tags.Tags = {GameplayTags = {
                    {TagName = FName('CharacterState.Camera.InUnavoidableCombat')},
                    {TagName = FName('CharacterState.AbilityState.Troop.Player.InCombat')},
                }}
                scripts[#scripts + 1] = tags
            else
                scripts[#scripts + 1] = script('/SGameAI/Tools/MobDomain/MobGroupScript_SetShouldNotSpawnOnClear', group)
            end
            group.Scripts = scripts
            local members = {}
            for index, slot in ipairs(formation.slots) do
                local entry = leader
                if not slot.leader then
                    local requested = {X = leader.location.X + slot[1], Y = leader.location.Y + slot[2], Z = leader.location.Z}
                    local projected = {}
                    assert(battle.navigation:K2_ProjectPointToNavigation(battle.player, requested, projected,
                        nil, nil, {X = 180, Y = 180, Z = 800}), 'Cannot place native HuaShan formation')
                    entry = {enemy = {id = leader.enemy.id .. '_troop_' .. index,
                        class = root .. formation.follower .. '.' .. formation.follower .. '_C'},
                        location = projected, group = group, auxiliary = true}
                end
                local class = Native.load_class(entry.enemy.class)
                local capsule = class:GetCDO().CapsuleComponent
                assert(Native.valid(capsule), 'Native HuaShan capsule is unavailable')
                local angle = math.rad(slot[3]) / 2
                local transform = {Rotation = {X = 0, Y = 0, Z = math.sin(angle), W = math.cos(angle)},
                    Scale3D = {X = 1, Y = 1, Z = 1}, Translation = {X = entry.location.X,
                        Y = entry.location.Y, Z = entry.location.Z + capsule:GetScaledCapsuleHalfHeight() + 5}}
                local spawner = battle.spawn_library:SpawnActorDeferred(battle.player, Native.load_class(spawner_path), transform, 2)
                assert(Native.valid(spawner), 'Native HuaShan spawner creation failed')
                battle.spawners[#battle.spawners + 1] = spawner
                spawner.InitialSpawn = false
                spawner.ShouldSpawn = false
                spawner:SetActorEnableCollision(false)
                spawner:SetActorHiddenInGame(true)
                battle.spawn_library:FinishActorSpawning(spawner, transform)
                spawner.MobGroup = group
                spawner:SetClassToSpawn(system:Conv_SoftClassPathToSoftClassRef(system:MakeSoftClassPath(entry.enemy.class)))
                spawner.SetShouldNotSpawnAfterDead = not blue and slot.leader == true
                spawner.SpawnInfo.bHiddenByDefault = false
                if blue then
                    spawner.SpawnInfo.DefaultGameplayTags = {GameplayTags = {
                        {TagName = FName('CharacterState.AbilityState.Troop.TroopMob')},
                    }}
                    if slot.leader then
                        local center = script('/SGameAI/Core/AIScript/AIScript_AssignBlackBoardVector', spawner)
                        center.ActorLocationToAssign = battle.domain
                        center.LocationBlackboardKey = {TagName = FName('AI.BlackboardKey.Vector.DomainCenter')}
                        spawner.SpawnInfo.ExtraScripts = {center}
                    end
                end
                entry.spawner, entry.transform = spawner, transform
                members[#members + 1] = system:Conv_ObjectToSoftObjectReference(spawner)
                expanded[#expanded + 1] = entry
            end
            group.Members = members
            group:InitializeScripts()
        end
    end
    return expanded
end

function HuaShan.release(battle)
    for _, group in ipairs(battle.huashan_groups or {}) do
        if Native.valid(group) then group.Members:Empty() end
        for index = #battle.groups, 1, -1 do
            if Native.same(battle.groups[index], group) then table.remove(battle.groups, index); break end
        end
        Native.release(group)
    end
    battle.huashan_groups = nil
end

return HuaShan
