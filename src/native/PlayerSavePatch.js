// Receive disk completion through Puerts; never marshal FScriptDelegate from Lua.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const prototype = exports.RenewalPlayerinXinInterface.prototype;
    const originalSaveLoad = prototype.SaveLoad;
    const originalEndPlay = prototype.ReceiveEndPlay;
    const readyTag = "PBZRogue.SaveBridgeReady2";
    const requestPrefix = "PBZRogue.SaveRequest.";
    const completePrefix = "PBZRogue.SaveComplete.";
    const detachedPrefix = "PBZRogue.SaveDetachedComplete.";
    function unbind(session) {
        if (!session) return;
        if (isNativeObjectAlive(session.subsystem)) {
            session.subsystem.PBZStartSaveGame.Remove(session.started);
            session.subsystem.PBZFinishSaveGame.Remove(session.finished);
        }
        session.player = undefined;
    }
    function completeDetached(session, slot) {
        const subsystem = session.subsystem;
        unbind(session);
        subsystem.RecordFiredDelegateForTest(detachedPrefix + slot, new UE.JsonObjectWrapper(), 0, true);
    }
    prototype.SaveLoad = function (...args) {
        const result = originalSaveLoad.apply(this, args);
        unbind(this.pbzRogueSaveSession);
        const subsystem = UE.SubsystemBlueprintLibrary.GetGameInstanceSubsystem(this, UE.PBZSaveLoadSubsystem.StaticClass());
        if (!subsystem || !subsystem.PBZStartSaveGame || !subsystem.PBZFinishSaveGame ||
            typeof subsystem.RecordFiredDelegateForTest !== "function")
            throw new Error("PBZRogue: native disk completion events are unavailable");
        const session = { player: this, subsystem, requested: undefined, slot: undefined };
        this.pbzRogueSaveSession = session;
        session.started = param => {
            // Reason 13 samples memory only and has no paired disk completion.
            if (param.Reason === 13) return;
            session.slot = undefined;
            const slot = String(param.SaveSlotName);
            const player = session.player;
            const requested = player && isNativeObjectAlive(player)
                ? player.ActorHasTag(requestPrefix + slot) : session.requested === slot;
            if (param.Reason === 4 && /^ManualSave\d+$/.test(slot) && requested) {
                session.slot = slot;
                // Detached requests retain the disk gate but cannot sample a
                // destroyed world's equipment or publish a new custom snapshot.
                if (player)
                    subsystem.RecordFiredDelegateForTest(slot, new UE.JsonObjectWrapper(), 0, false);
            }
        };
        session.finished = success => {
            const slot = session.slot;
            session.slot = undefined;
            // Failed native writes stay queued for retry; keep the deletion gate.
            if (success !== true || !slot) return;
            const player = session.player;
            if (!player) {
                if (session.requested === slot) completeDetached(session, slot);
                return;
            }
            if (!isNativeObjectAlive(player) || !player.ActorHasTag(requestPrefix + slot)) return;
            if (!player.ActorHasTag(completePrefix + slot)) player.Tags.Add(completePrefix + slot);
        };
        subsystem.PBZStartSaveGame.Add(session.started);
        subsystem.PBZFinishSaveGame.Add(session.finished);
        if (!this.ActorHasTag(readyTag)) this.Tags.Add(readyTag);
        return result;
    };
    prototype.ReceiveEndPlay = function (...args) {
        const session = this.pbzRogueSaveSession;
        if (session) {
            // Read while EndPlay still owns the actor. Future callbacks keep
            // only the GameInstance subsystem and plain slot names alive.
            for (let index = 0; index < this.Tags.Num(); ++index) {
                const tag = String(this.Tags.Get(index));
                if (tag.startsWith(requestPrefix)) session.requested = tag.slice(requestPrefix.length);
            }
            const completed = session.requested && this.ActorHasTag(completePrefix + session.requested);
            session.player = undefined;
            this.pbzRogueSaveSession = undefined;
            if (completed) completeDetached(session, session.requested);
            else if (!session.requested) unbind(session);
        }
        return originalEndPlay.apply(this, args);
    };
})();