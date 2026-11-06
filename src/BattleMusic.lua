local Native = require('Native')
local Locale = require('Locale')
local Rng = require('Rng')
local BattleMusic = {}
BattleMusic.__index = BattleMusic
local property_registered = false
local fade_seconds = 2.0 -- Original BP_PlayerAudioComponent ClearMusic duration.

function BattleMusic.new(player, config, seed)
    if not property_registered then
        -- main.lua's native adapter verifies the exact Steam 26367565 EXE SHA256
        -- before loading Run. In that binary DisableGameplayMusic writes this byte.
        -- Read only: all changes still use the native API, never a raw field write.
        RegisterCustomProperty({Name = 'PBZRogue_GameplayMusicDisabled', Type = PropertyTypes.ByteProperty,
            BelongsToClass = '/Script/ProjectPBZ.MusicSubsystem', OffsetInternal = 0xF1})
        property_registered = true
    end
    return setmetatable({player = player, config = config, rng = Rng.new(seed),
        subsystem = Native.subsystem(player, '/Script/ProjectPBZ.MusicSubsystem')}, BattleMusic)
end

function BattleMusic:mob_track()
    -- Cosmetic draws must not change enemy, spawn-location, or shop randomness.
    return self.config.mobs[self.rng:integer(#self.config.mobs)]
end

function BattleMusic:boss_track(id)
    return self.config.bosses[id] or self:mob_track()
end

function BattleMusic:play(track)
    local event, state = Native.load_object(track.event), Native.load_object(track.state)
    assert(event:IsA('/Script/AkAudio.AkAudioEvent') and state:IsA('/Script/AkAudio.AkStateValue'),
        Locale.text('战斗音乐配置必须引用原生 AkAudioEvent / AkStateValue',
            'Battle music must reference native AkAudioEvent / AkStateValue assets'))
    if not self.held then
        local previous = self.subsystem.PBZRogue_GameplayMusicDisabled
        assert(previous == 0 or previous == 1, 'Unexpected native gameplay-music flag')
        self.previous_disabled, self.held = previous == 1, true
        self.subsystem:DisableGameplayMusic(true)
    end
    -- Suppress arena-volume arbitration, not native forced boss phase changes.
    -- No delayed callbacks or tick-loop replay; native settings/mix remain intact.
    self.subsystem:PlayMusicAndSetState(event, state, 1, true)
end

function BattleMusic:stop(restore_scene)
    if not self.held then return end
    if not Native.valid(self.subsystem) then
        self.held, self.previous_disabled = nil, nil
        return
    end
    local previous = self.previous_disabled
    local cleared, message = pcall(function() self.subsystem:ClearMusic(fade_seconds, true, false) end)
    self.subsystem:DisableGameplayMusic(previous)
    self.held, self.previous_disabled = nil, nil
    assert(cleared, message)
    if restore_scene and not previous then
        self.subsystem:UpdateGameplayMusicWithDelay(fade_seconds)
    end
end

return BattleMusic
