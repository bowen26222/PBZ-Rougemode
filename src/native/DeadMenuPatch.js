// Appended to the pinned UI/Widget/DeadMenu.js, isolated runs only.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const prototype = exports.DeadMenuInterface.prototype;
    const originalActivated = prototype.BP_OnActivated;
    function painted(widget) {
        if (!widget || !UE.KismetSystemLibrary.IsValid(widget))
            return false;
        const size = UE.SlateBlueprintLibrary.GetLocalSize(widget.GetCachedGeometry());
        if (!(size.X > 0 && size.Y > 0))
            return false;
        // A constructed/activated widget can still be transparent or under a
        // collapsed ancestor. Count only the native animation's visible glyphs.
        let opacity = 1;
        for (let current = widget; current; current = current.GetParent()) {
            if (!current.IsVisible())
                return false;
            opacity *= current.GetRenderOpacity();
        }
        return opacity > 0.05;
    }
    prototype.BP_OnActivated = function (...args) {
        this.pbzRogueShownAt = undefined;
        this.pbzRogueDeathReady = false;
        this.pbzRogueYun = UE.Widget.Find("yun", this.WidgetTree);
        this.pbzRogueMing = UE.Widget.Find("ming", this.WidgetTree);
        return originalActivated.apply(this, args);
    };
    prototype.Tick = function () {
        // Keep the native visual pacing. The rest of the original Tick is the
        // streaming/respawn state machine; its Blueprint tick2 export is empty.
        this.applyNightmareMaskPace();
        if (!this.IsActivated() || !this.IsVisible() || this.GetRenderOpacity() <= 0)
            return;
        const player = UE.GameplayStatics.GetPlayerCharacter(this, 0);
        if (!player || !player.ActorHasTag("PBZRogue.DeathLocked"))
            return;
        const now = UE.GameplayStatics.GetRealTimeSeconds(this);
        if (this.pbzRogueShownAt === undefined) {
            if (!painted(this.pbzRogueYun) || !painted(this.pbzRogueMing))
                return;
            this.pbzRogueShownAt = now;
            player.Tags.Add("PBZRogue.DeathShown");
            return;
        }
        if (!this.pbzRogueDeathReady && now - this.pbzRogueShownAt >= 1) {
            this.pbzRogueDeathReady = true;
            player.Tags.Add("PBZRogue.DeathReady");
        }
    };
    prototype.Destruct = function () {
        // Native Destruct calls finishCheckStreaming -> Death Component.Respawn
        // even if the widget is merely popped. Keep cleanup, never resurrection.
        TeleportCover.end(this);
        if (this.fadeOutSoundTimer) {
            clearTimeout(this.fadeOutSoundTimer);
            this.fadeOutSoundTimer = 0;
        }
        if (this.deactivateDelayTimer) {
            clearTimeout(this.deactivateDelayTimer);
            this.deactivateDelayTimer = 0;
        }
        this.animFinishGens = {};
        if (this.PreviousStreamingActor) {
            this.StreamingComponent = undefined;
            this.PreviousStreamingActor.K2_DestroyActor();
            this.PreviousStreamingActor = undefined;
        }
        this.pbzRogueYun = this.pbzRogueMing = undefined;
    };
})();
