local Native = require('Native')
local BossPhases = {}
local story_health_lock
local zuo_shang_floors

-- ZuoShang's story phase ladder installs new floors during combat, so his
-- owned encounter actor also comes through here on the existing battle tick.
-- Remove only these four source effects; execution/move invulnerability stays.
-- Other bosses retain their existing opt-in, spawn-time GE_LockHealth release.
function BossPhases.prepare(pawn, enemy, group)
    local zuo_shang = enemy.id == 'zuo_shang'
    if not zuo_shang and not enemy.releaseStoryHealthLock then return end
    assert(enemy.enabled ~= false and Native.valid(pawn) and Native.same(pawn.MobGroup, group),
        'Story phase health gate may only be released on an owned encounter actor')
    assert(Native.same(pawn:GetClass(), Native.load_class(enemy.class)),
        'Story phase class does not match its catalog entry')
    local asc = Native.cdo('/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary')
        :GetAbilitySystemComponent(pawn)
    assert(Native.valid(asc), 'Native boss ability system is unavailable: ' .. enemy.id)
    if zuo_shang then
        if not zuo_shang_floors then
            zuo_shang_floors = {}
            for _, percent in ipairs({'80', '60', '40', '04'}) do
                local name = 'GE_ZuoShang_MinHealth_' .. percent
                zuo_shang_floors[#zuo_shang_floors + 1] = Native.load_class(
                    '/PBZCombatAsset/ActorData/Mobs/054_ZuoShang/AIConfig/' .. name .. '.' .. name .. '_C')
            end
        end
        for _, effect in ipairs(zuo_shang_floors) do
            asc:RemoveActiveGameplayEffectBySourceEffect(effect, nil, -1)
        end
    else
        if not Native.valid(story_health_lock) then
            story_health_lock = Native.load_class(
                '/PBZCombatAsset/Prototypes/GameplayEffects/GE_LockHealth.GE_LockHealth_C')
        end
        asc:RemoveActiveGameplayEffectBySourceEffect(story_health_lock, nil, -1)
    end
end

return BossPhases
