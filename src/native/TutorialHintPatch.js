// Appended to each shipped System/TutorialHint_* module before mixin registration.
// Command-line scope is available before the character/component is constructed.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const tutorial = exports.TutorialHint_DoubleMedicineInterface ||
        exports.TutorialHint_PotionInterface || exports.TutorialHint_UltimateInterface ||
        exports.TutorialHint_WeaponSwitchInterface;
    const prototype = tutorial.prototype;
    // Native Cleanup cancels pending loads/timers/tag listeners, unregisters the
    // CombatHint extension and removes only this tutorial's delegate bindings.
    // Do not fake completion counts, save sections or gameplay unlocks.
    prototype.InitTutorial = prototype.Cleanup;
    prototype.tryShowHint = prototype.Cleanup;
    if (prototype.onHintWidgetLoaded)
        prototype.onHintWidgetLoaded = prototype.Cleanup;
    if (prototype.Refresh)
        prototype.Refresh = prototype.Cleanup;
})();
