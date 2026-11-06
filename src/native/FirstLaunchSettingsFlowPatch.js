// Appended to the shipped UI/Widget/FirstLaunchSettingsFlow.js in the isolated-mode pak.
(() => {
    if (!/(?:^|\s)-PBZRogue(?=\s|$)/i.test(UE.KismetSystemLibrary.GetCommandLine()))
        return;

    // Do not enter UPBZFirstLaunchFlow at all: it owns the gamma/language/graphics
    // modal stack. Leave its account completion bit and session-once state alone.
    pushFirstLaunchSettings = function() {};
    tryStartFirstLaunchGuide = function() {};
    exports.pushFirstLaunchSettings = pushFirstLaunchSettings;
    exports.tryStartFirstLaunchGuide = tryStartFirstLaunchGuide;
})();
