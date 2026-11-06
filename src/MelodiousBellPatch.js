// Appended to Level/Actor/Switch/MelodiousBell.js and explicitly loaded by
// BellMenuPatch. The shipped MainStart no longer registers its old GA mixin.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const puerts = require("puerts");
    const helpers = require("../../../Library/TsHelper").default;
    const modeTag = "PBZRogue.NativeBell";
    // Unmixed native parent UFunctions, not the BP overrides installed below.
    const nativeInteract = UE.MelodiousBell.prototype.OnInteract;
    const nativeApproachCompleted = UE.PBZSwitchBase.prototype.OnApproachCompleted;
    if (typeof nativeInteract !== "function" || typeof nativeApproachCompleted !== "function")
        throw new Error("PBZRogue: native parent bell interaction functions are unavailable");
    function scoped(bell) { return bell.ActorHasTag(modeTag); }
    function signal(bell, suffix) {
        const tag = modeTag + suffix;
        if (!bell.ActorHasTag(tag))
            bell.Tags.Add(tag);
    }
    function fail(bell, error) {
        console.error(error);
        signal(bell, "Error");
        try { bell.EndSwitchInteract(); }
        catch (cleanupError) { console.error("PBZRogue: bell cleanup failed", cleanupError); }
    }
    function pushMenu(bell) {
        if (bell.pbzRogueMenuAction)
            return;
        bell.pbzRogueClosed = false;
        const player = UE.GameplayStatics.GetPlayerCharacter(bell, 0);
        if (!player || !player.ActorHasTag("PBZRogue.NativeBellPlayer"))
            throw new Error("PBZRogue: bell menu lost its run player");
        const action = UE.AsyncAction_PushContentToLayerForPlayer.PushContentToLayerForPlayer(
            UE.GameplayStatics.GetPlayerController(bell, 0),
            helpers.GetSoftClassByPath("/Game/PBZContent/UI/InGame/Bell/W_BellMenu.W_BellMenu_C"),
            helpers.constructGameplayTag("UI.Layer.Menu"), false);
        if (!action)
            throw new Error("PBZRogue: native bell menu push could not be created");
        action.BeforePush.Add(widget => {
            if (!widget || !UE.KismetSystemLibrary.IsValid(bell)) {
                action.Cancel();
                return;
            }
            widget.OwnerBell = bell;
            widget.BP_OnWidgetDeactivated.Add(bell, "EndSwitchInteract");
        });
        action.AfterPush.Add(widget => {
            if (!UE.KismetSystemLibrary.IsValid(bell))
                return;
            bell.pbzRogueMenuAction = undefined;
            if (!widget)
                signal(bell, "Error");
        });
        bell.pbzRogueMenuAction = action;
        action.Activate();
    }
    function finishApproach(bell) {
        try {
            const player = bell.pbzRoguePlayer;
            if (!player || !UE.KismetSystemLibrary.IsValid(player))
                throw new Error("PBZRogue: native bell approach lost its player");
            // StartInteractApproach uses InteractRegionComp, bypassing the BP
            // GetMoveToTarget that initializes these world-space warp caches.
            // A spawned bell otherwise feeds (0,0,0) to the montage's
            // "Interaction" target. Recompute the original socket/arc target
            // at arrival; do not replace it with the actor's local transform.
            bell.GetMoveToTarget(puerts.$ref(new UE.Vector()), puerts.$ref(new UE.Rotator()),
                puerts.$ref(0), puerts.$ref(0), puerts.$ref(0), puerts.$ref(new UE.Vector()));
            bell.AddWrapTarget();
            if (!bell.CharacterInteractAnim || player.PlayAnimMontage(bell.CharacterInteractAnim) <= 0)
                throw new Error("PBZRogue: native bell interaction montage failed");
            bell.PlayRingSound();
            // Native Send Event -> InteractAfterMove drives the original bell
            // impulse (1.2s) and PlayLoopAnim (3s), including physics blend-out.
            // DoInteract is deliberately not called: it owns native rest/save.
            bell["Send Event"]();
        } catch (error) {
            fail(bell, error);
        }
    }
    class RunBellMixin {
        OnInteract(player) {
            if (!scoped(this)) {
                // Exact original BP body: EnableTick then native parent call.
                this.EnableTick(true);
                return nativeInteract.call(this, player);
            }
            this.pbzRogueClosed = false;
            if (!player || !player.ActorHasTag("PBZRogue.NativeBellPlayer") ||
                !this.ActorHasTag(modeTag + "Ready") || !this.ActorHasTag(modeTag + "Allowed")) {
                this.EndSwitchInteract();
                return false;
            }
            try {
                this.pbzRoguePlayer = player;
                this["Interact With"] = player;
                this.InteractingPlayer = player;
                this.EnableTick(true);
                signal(this, "Interacting");
                // Keep real PBZ proximity selection, prompt/input, weapon
                // sheathing, approach and camera handling. Only the checkpoint
                // part of AMelodiousBell.OnInteract/DoInteract is bypassed.
                if (!this.StartInteractApproach(player)) {
                    this.EndSwitchInteract();
                    return false;
                }
                return true;
            } catch (error) {
                fail(this, error);
                return false;
            }
        }
        ReceiveBeginPlay() {
            this.ExecuteUbergraph_BP_MelodiousBell(2735);
            if (scoped(this))
                signal(this, "Ready");
        }
        OnApproachCompleted() {
            // StartInteractApproach sets the native approach-only flag. Its
            // completion dispatches this BlueprintNativeEvent, NOT the legacy
            // BP_FinishChangeArmedAndMoveTo event (confirmed in native code).
            if (!scoped(this))
                return nativeApproachCompleted.call(this);
            finishApproach(this);
        }
        PlayLoopAnim() {
            this.ExecuteUbergraph_BP_MelodiousBell(3102);
            if (scoped(this) && this.pbzRoguePlayer) {
                try { pushMenu(this); }
                catch (error) { fail(this, error); }
            }
        }
        RefreshBell() {
            if (!scoped(this))
                return this.ExecuteUbergraph_BP_MelodiousBell(4484);
            // Reflected secondary-return command, not a native refresh/save.
            if (this.ActorHasTag(modeTag + "Reopen")) {
                try { pushMenu(this); }
                catch (error) { fail(this, error); }
            }
        }
        EndSwitchInteract() {
            if (scoped(this)) {
                // CloseButton and BP_OnWidgetDeactivated both end interaction.
                // Cancel/stop operations may synchronously re-enter this too.
                if (this.pbzRogueClosed)
                    return;
                this.pbzRogueClosed = true;
                const action = this.pbzRogueMenuAction;
                this.pbzRogueMenuAction = undefined;
                if (action)
                    action.Cancel();
                UE.KismetSystemLibrary.K2_ClearTimer(this, "AddImpulse");
                UE.KismetSystemLibrary.K2_ClearTimer(this, "PlayLoopAnim");
                const player = this.pbzRoguePlayer;
                this.pbzRoguePlayer = undefined;
                if (player && UE.KismetSystemLibrary.IsValid(player))
                    player.StopAnimMontage(this.CharacterInteractAnim);
                signal(this, "Closed");
            }
            // Native approach/input/camera/bell-animation cleanup, unchanged.
            this.ExecuteUbergraph_BP_MelodiousBell(7564);
        }
        ["Restore BackPack Data"]() {
            if (!scoped(this))
                this.ExecuteUbergraph_BP_MelodiousBell(3432);
            // Mod bell must not restore items/ammo/health, emit ResetState,
            // advance story quests or queue the graph's delayed autosave.
        }
        FlowBellSaveGame() {
            if (!scoped(this))
                this.ExecuteUbergraph_BP_MelodiousBell(8082);
        }
    }
    const bellClass = UE.Class.Load("/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C");
    if (!bellClass)
        throw new Error("PBZRogue: native BP_MelodiousBell class is unavailable");
    puerts.blueprint.mixin(puerts.blueprint.tojs(bellClass), RunBellMixin,
        {objectTakeByNative: true, inherit: false, noMixinedWarning: true});
    exports.pbzRogueBellPolicyVersion = 1;
})();
