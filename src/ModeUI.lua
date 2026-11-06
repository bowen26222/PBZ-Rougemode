local Native = require('Native')
local ModeUI = {}
local hooks_installed = false

local hint_classes = {
    'BP_TutorialHint_DoubleMedicine_C', 'BP_TutorialHint_Potion_C',
    'BP_TutorialHint_Ultimate_C', 'BP_TutorialHint_WeaponSwitch_C',
}
local tutorial_widget_classes = {
    'WB_Hud_tutorial_Complex_C',
    'WB_HudTutorialComplex_OnlyBell_C',
    'WB_HudTutorialComplex_Tutorial_GameInputMode_C',
    'WB_hud_tutorial_ForceGuide_C',
    -- RenewalPlayer.pushDoubleMedicineHint uses this Menu-layer activatable,
    -- independently of the similarly named, nonmodal tutorial hint component.
    'W_TutorialBar_Hint_DoubleMedicine_C',
}

local function isolated_mode()
    local command_line = Native.name(Native.cdo('/Script/Engine.Default__KismetSystemLibrary'):GetCommandLine())
    for token in command_line:gmatch('%S+') do
        if token:lower() == '-pbzrogue' then return true end
    end
    return false
end

-- Install before loading the arena: these native UFUNCTIONs already exist even
-- when no Blueprint tutorial widget/player has been constructed.
function ModeUI.setup()
    if hooks_installed or not isolated_mode() then return end
    RegisterHook('/Script/ProjectPBZ.PBZForceGuideWidget:StartForceGuide', function() end,
        function(context)
            local guide = context:get()
            if not Native.valid(guide) then return end
            -- This class is UCommonUserWidget, not an activatable/dialog:
            -- EndForceGuide owns preprocessor release; removal alone does not.
            if guide:IsGuideActive() then guide:EndForceGuide(false) end
            guide:RemoveFromParent()
            -- Hosts use the native boolean result to decide whether to attach
            -- tutorial key listeners/start steps. Report the aborted start.
            return false
        end)
    RegisterHook('/Script/Flow.FlowNode:TriggerOutputPin', function() end,
        function(context, pin)
            local node = context:get()
            if not Native.valid(node) then return end
            local class = StaticFindObject(
                '/Game/PBZContent/Blueprint/FlowGraph/FlowGraphNode/PlayTutorialUI_ForceGuide.PlayTutorialUI_ForceGuide_C')
            if not Native.same(node:GetClass(), class)
                or Native.name(pin:get().PinName) ~= '立即执行' then return end
            -- Legacy Blueprint guides are PBZActivatableWidget, not the newer
            -- PBZForceGuideWidget. Bytecode binds its close delegate before this
            -- output (offsets 1284/1307 -> 1348), so synchronous deactivation here
            -- both releases CommonUI ownership and completes the native flow.
            local widget = node['As WB Hud Tutorial']
            if Native.valid(widget) and widget:IsActivated() then
                widget:StopAllAnimations()
                widget:DeactivateWidget()
                Native.cdo('/Script/CommonGame.Default__CommonUIExtensions'):PopContentFromLayer(widget)
            end
        end)
    hooks_installed = true
end

-- Call once after the local player is ready and before opening the run's start
-- confirmation. Native JS guards prevent later tutorial trigger acquisition.
function ModeUI.cleanup(context)
    if not isolated_mode() then return end
    ModeUI.setup()
    local gameplay = Native.cdo('/Script/Engine.Default__GameplayStatics')
    local instance = gameplay:GetGameInstance(context)
    assert(Native.valid(instance), 'Tutorial cleanup requires a live game instance')
    for _, class_name in ipairs(hint_classes) do
        for _, hint in ipairs(FindAllOf(class_name) or {}) do
            if Native.valid(hint) and Native.same(gameplay:GetGameInstance(hint), instance) then
                hint:Cleanup()
            end
        end
    end
    -- Close tutorial-only activatables through their native lifecycle. That
    -- releases their menu input/pause ownership and runs the flow close delegates;
    -- removing visuals or setting GameOnly would leave those owners alive.
    local ui = Native.cdo('/Script/CommonGame.Default__CommonUIExtensions')
    for _, class_name in ipairs(tutorial_widget_classes) do
        for _, widget in ipairs(FindAllOf(class_name) or {}) do
            if Native.valid(widget) and Native.same(gameplay:GetGameInstance(widget), instance)
                and widget:IsActivated() then
                widget:DeactivateWidget()
                ui:PopContentFromLayer(widget)
            end
        end
    end
    for _, guide in ipairs(FindAllOf('PBZForceGuideWidget') or {}) do
        if Native.valid(guide) and Native.same(gameplay:GetGameInstance(guide), instance)
            and guide:IsGuideActive() then
            guide:EndForceGuide(false)
            guide:RemoveFromParent()
        end
    end
    instance:EndTutorial()
    local router = Native.subsystem(context, '/Script/ProjectPBZ.PBZUIActionRouterBase')
    router:CompleteTutorialInputPreProcesser()
end

return ModeUI
