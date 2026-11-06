// Appended to the pinned Gameplay/RenewalPlayer.js, isolated runs only.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const prototype = exports.RenewalPlayerinXinInterface.prototype;
    const originalRespawn = prototype.Respawn;
    const deadTag = "PBZRogue.DeathLocked";
    prototype.Respawn = function (...args) {
        // Death is terminal even if another native caller requests resurrection.
        if (this.ActorHasTag(deadTag))
            return;
        return originalRespawn.apply(this, args);
    };
    prototype.PushWidgetAndChangeData = function () {
        if (this.pbzRogueDeathPushed)
            return;
        this.pbzRogueDeathPushed = true;
        if (!this.ActorHasTag(deadTag))
            this.Tags.Add(deadTag);
        this.respawnPendingGroup = 0;
        const save = UE.SubsystemBlueprintLibrary.GetGameInstanceSubsystem(this, UE.PBZSaveLoadSubsystem.StaticClass());
        // Lua invalidates the checkpoint before any asynchronous UI load begins.
        save.RecordFiredDelegateForTest("PBZRogue.Death|" + UE.KismetSystemLibrary.GetPathName(this), new UE.JsonObjectWrapper(), 0, false);
        if (UE.PBZBlueprintFunctionLibrary.GetDiffcultMode(this) === UE.EDifficultMode.NightMare) {
            this.RemainingDaysBeforeDeath = this.RemainingDays;
            this.RemainingDays = UE.KismetMathLibrary.Clamp(this.RemainingDays - 1, 0, 66);
            this.onReamingDaysChanged();
            this.clearBuff();
            this.randomActivateDeadBuff();
        }
        const softPath = UE.KismetSystemLibrary.MakeSoftClassPath("/Game/PBZContent/UI/InGame/Dead/W_PlayerDead.W_PlayerDead_C");
        const widgetClass = UE.KismetSystemLibrary.Conv_SoftClassPathToSoftClassRef(softPath);
        const action = UE.AsyncAction_PushContentToLayerForPlayer.PushContentToLayerForPlayer(
            UE.GameplayStatics.GetPlayerController(this, 0), widgetClass,
            TsHelper_1.default.constructGameplayTag("UI.Layer.Menu"));
        const actionName = action.GetName();
        action.BeforePush.Add(widget => {
            this["Death Widget"] = widget;
            const gameSystem = TsHelper_1.default.getWorldSubsystem(this, UE.PBZGameSystem.StaticClass());
            const transform = (0, puerts_1.$ref)(undefined);
            const rotation = (0, puerts_1.$ref)(undefined);
            gameSystem.GetReviveTransform(transform, rotation);
            widget.ReviveTransform = (0, puerts_1.$unref)(transform);
            // Preserve the original page/animation, not its respawn/bad-ending routes.
            widget.IsFinishDead = false;
            widget.StartFadeOut.Clear();
            widget.EndFadeOut.Clear();
        });
        action.AfterPush.Add(widget => {
            // Unlike the native callback, never ResetAllLayers/InitHud/CompleteRevive
            // after removal: those deferred actions would erase the mod restart page.
            widget.BP_OnWidgetDeactivated.Add(() => this.removeAsyncActionByName(actionName));
        });
        action.Activate();
        this.AsyncActions.Add(action);
    };
})();
