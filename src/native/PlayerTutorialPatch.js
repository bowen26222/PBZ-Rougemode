// Appended to Gameplay/RenewalPlayer.js after PlayerSavePatch.js.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const prototype = exports.RenewalPlayerinXinInterface.prototype;
    // This is a second, independent subscriber, not TutorialHint_DoubleMedicine.
    // TsBeginPlay calls it in cycle zero; the original handler waits 200 ms then
    // pushes W_TutorialBar_Hint_DoubleMedicine onto UI.Layer.Menu. Prevent the
    // subscription itself, without clearing other backpack delegates or faking
    // tutorial completion/save flags.
    prototype.tryToStartMedicineTutorial = function() {};
    // Guard the delayed/direct entry too, before AsyncAction.Activate can acquire
    // CommonUI input/pause ownership. Do not cancel medicineSendTimers: that array
    // also owns ordinary potion pickup presentation timers.
    prototype.pushDoubleMedicineHint = function() {};
})();
