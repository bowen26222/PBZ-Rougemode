// Appended to UI/Widget/SystemBase.js, not to any generic dialog base.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;
    const prototype = exports.SystemBaseMixinInterface.prototype;
    // The original abort path restores the tab/quest/action controls, cancels
    // async loads and timers and calls EndForceGuide(false), never marking a
    // tutorial complete. Keep the real system menu and its own input untouched.
    prototype.maybeStartSystemTutorial = prototype.cleanupSystemTutorial;
    prototype.startSystemTutorial = prototype.cleanupSystemTutorial;
})();
