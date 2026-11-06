[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OriginalScript,
    [Parameter(Mandatory = $true)][string]$OriginalBellMenu,
    [Parameter(Mandatory = $true)][string]$OriginalMelodiousBell,
    [Parameter(Mandatory = $true)][string]$OriginalModeUiRoot,
    [Parameter(Mandatory = $true)][string]$OriginalTutorialFlowRoot,
    [Parameter(Mandatory = $true)][string]$OriginalStartMenu,
    [Parameter(Mandatory = $true)][string]$OriginalPlayer,
    [Parameter(Mandatory = $true)][string]$OriginalDeadMenu,
    [Parameter(Mandatory = $true)][string]$BellBlueprintExport,
    [Parameter(Mandatory = $true)][string]$Repak,
    [Parameter(Mandatory = $true)][string]$Retoc,
    [string]$OutputPak
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $OutputPak) { $OutputPak = Join-Path $PSScriptRoot '..\.local\pakchunk999-PBZRogueSkills_P.pak' }
# Steam build 26367565 / CL-302256_JKS-17280: pin freshly exported shipped
# modules, preserving their native changes before appending the run-only policy.
$expectedHash = '805DEE1B74D00CC8738BDC4DDFA045A9F72C32DA3A22DD0843BAB793B37690B4'
if ((Get-FileHash -LiteralPath $OriginalScript -Algorithm SHA256).Hash -ne $expectedHash) {
    throw 'AbilityWidget.js does not match the supported game build. Reinspect native skill logic before rebuilding.'
}
# The actor patch calls unchanged, argument-free BP event trampolines by their
# exported entry offsets. Pin that evidence as strictly as the native JS modules.
if ((Get-FileHash -LiteralPath $BellBlueprintExport -Algorithm SHA256).Hash -ne
    '78E905880475435C703D850BDF2221C9F1C7C1AD12E206B314569A11E7DB8482') {
    throw 'BP_MelodiousBell export does not match the supported native event graph.'
}
$additionalScripts = @(
    @{ Source = $OriginalBellMenu; Hash = '34B7BB9EEE0C729F8E81E961D8AC8606C4F11DCAC938846E914A66F51B7B5C7A'
       Relative = 'UI\Widget\BellMenu.js'; Patch = 'BellMenuPatch.js' },
    @{ Source = $OriginalMelodiousBell; Hash = 'EF721D6D4639EE22820A9664CD18370DAD6E690B3C0067056F2B358D82496BF1'
       Relative = 'Level\Actor\Switch\MelodiousBell.js'; Patch = 'MelodiousBellPatch.js' },
    @{ Source = (Join-Path $OriginalModeUiRoot 'System\TutorialHint_DoubleMedicine.js'); Hash = 'CE3AD00EA6FB1758230A5829C224479065CAA63AC99DBD455E15F18DD660D6AD'
       Relative = 'System\TutorialHint_DoubleMedicine.js'; Patch = 'native\TutorialHintPatch.js' },
    @{ Source = (Join-Path $OriginalModeUiRoot 'System\TutorialHint_Potion.js'); Hash = '2AB689CAB748BFF91C2F91EE84D270FFCFC134F09CBB1BADF264765DAE3FCC31'
       Relative = 'System\TutorialHint_Potion.js'; Patch = 'native\TutorialHintPatch.js' },
    @{ Source = (Join-Path $OriginalModeUiRoot 'System\TutorialHint_Ultimate.js'); Hash = 'E1CBA8287E16294D98903DB17EE5FE71EEC20C7200E35B4CAB1D76420844D1D8'
       Relative = 'System\TutorialHint_Ultimate.js'; Patch = 'native\TutorialHintPatch.js' },
    @{ Source = (Join-Path $OriginalModeUiRoot 'System\TutorialHint_WeaponSwitch.js'); Hash = 'A6FB34829D530FB1D4647D2D585470354A4D61B2EDBFBC0E315F916D4E05AC56'
       Relative = 'System\TutorialHint_WeaponSwitch.js'; Patch = 'native\TutorialHintPatch.js' },
    @{ Source = (Join-Path $OriginalModeUiRoot 'UI\Widget\TutorialComplex.js'); Hash = 'C1BFA6BECCB01482F2BCCFA7811B5AF5F5795F069316EE35ECD103D9DF465428'
       Relative = 'UI\Widget\TutorialComplex.js'; Patch = 'native\TutorialComplexPatch.js' },
    @{ Source = (Join-Path $OriginalTutorialFlowRoot 'FlowNode\PlayComplexTutorialNode.js'); Hash = '57BC36666CD2515FB88E1DFD8DE28A46ACA79A0A02ABEB4E64C71795BB010FE5'
       Relative = 'FlowNode\PlayComplexTutorialNode.js'; Patch = 'native\PlayComplexTutorialNodePatch.js' },
    @{ Source = (Join-Path $OriginalTutorialFlowRoot 'UI\Widget\SystemBase.js'); Hash = '60FCBD08FC0594177C18AEC4447D489179B146EC73E813A2E0007B32834D5D7C'
       Relative = 'UI\Widget\SystemBase.js'; Patch = 'native\SystemTutorialPatch.js' },
    @{ Source = (Join-Path $OriginalModeUiRoot 'UI\Widget\EntitlementNotify.js'); Hash = 'C928CC11E0C8F923AF2554EA46131AFF579630391E0875371FA31B30D879AB13'
       Relative = 'UI\Widget\EntitlementNotify.js'; Patch = 'native\EntitlementNotifyPatch.js' },
    @{ Source = (Join-Path $OriginalModeUiRoot 'UI\Widget\FirstLaunchSettingsFlow.js'); Hash = '8E855ECBB71D06D9E59B8476E2E5110CD9D233359166FE0BB4CEFCA3C61AB98C'
       Relative = 'UI\Widget\FirstLaunchSettingsFlow.js'; Patch = 'native\FirstLaunchSettingsFlowPatch.js' },
    @{ Source = $OriginalStartMenu; Hash = '1B76D61E28A654A4BB22F0AC476B4EC624A321E0A6D748AD7EF8192919485080'
       Relative = 'UI\Widget\StartMenu.js'; Patch = @('native\StartMenuPopupPatch.js', 'native\UIInputPatch.js') },
    @{ Source = $OriginalPlayer; Hash = 'B3831D68BC4978001CF3A891A1512D1B408BD7D11E054349EC01DB0FF4A008F5'
       Relative = 'Gameplay\RenewalPlayer.js'; Patch = @('native\PlayerSavePatch.js', 'native\PlayerTutorialPatch.js', 'native\PlayerDeathPatch.js') },
    @{ Source = $OriginalDeadMenu; Hash = '2342C4EF0F7D9ADEFC8621D702B65F9714205C850C6F4154D0552414FAAEB1D9'
       Relative = 'UI\Widget\DeadMenu.js'; Patch = 'native\DeadMenuPatch.js' }
)
foreach ($script in $additionalScripts) {
    if ((Get-FileHash -LiteralPath $script.Source -Algorithm SHA256).Hash -ne $script.Hash) {
        throw "Native script does not match the supported game build: $($script.Relative)"
    }
}

# Checked-in evidence is restricted to these fifteen modules; release builds do
# not depend on the local executable-inspection workspace.
$supported = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ScriptIntegrity.Steam26367565.json') -Raw | ConvertFrom-Json
$integrityScripts = @(@{ Source = $OriginalScript; Relative = 'UI\Widget\AbilityWidget.js' }) + $additionalScripts
if ($supported.records.Count -ne 15 -or $integrityScripts.Count -ne 15) {
    throw 'The supported script integrity scope must contain exactly fifteen modules.'
}
function Get-ScriptFingerprint([string]$Path) {
    $raw = [IO.File]::ReadAllBytes($Path)
    $prefix = [Text.Encoding]::ASCII.GetBytes('(function (exports, require, module, __filename, __dirname) { ')
    $suffix = [Text.Encoding]::ASCII.GetBytes("`n});")
    $wrapped = [byte[]]::new($prefix.Length + $raw.Length + $suffix.Length)
    [Buffer]::BlockCopy($prefix, 0, $wrapped, 0, $prefix.Length)
    [Buffer]::BlockCopy($raw, 0, $wrapped, $prefix.Length, $raw.Length)
    [Buffer]::BlockCopy($suffix, 0, $wrapped, $prefix.Length + $raw.Length, $suffix.Length)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        [PSCustomObject]@{
            rawLength = $raw.LongLength
            wrappedLength = $wrapped.LongLength
            rawSHA256 = [BitConverter]::ToString($sha.ComputeHash($raw)).Replace('-', '').ToLowerInvariant()
            wrappedSHA256 = [BitConverter]::ToString($sha.ComputeHash($wrapped)).Replace('-', '').ToLowerInvariant()
        }
    } finally { $sha.Dispose() }
}
function ConvertTo-CppHash([string]$Hash) {
    if ($Hash -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid SHA256 in script integrity data.' }
    return '{ ' + ((0..31 | ForEach-Object { '0x' + $Hash.Substring($_ * 2, 2) }) -join ', ') + ' }'
}
function ConvertTo-CppFingerprint($Fingerprint) {
    return '{ ' + $Fingerprint.rawLength + 'ULL, ' + $Fingerprint.wrappedLength + 'ULL, ' +
        (ConvertTo-CppHash $Fingerprint.rawSHA256) + ', ' + (ConvertTo-CppHash $Fingerprint.wrappedSHA256) + ' }'
}
foreach ($script in $integrityScripts) {
    $script.ManifestPath = 'project/' + $script.Relative.Replace('\', '/').ToLowerInvariant()
    $records = @($supported.records | Where-Object { $_.path -ceq $script.ManifestPath })
    if ($records.Count -ne 1) { throw "Missing or duplicate supported integrity record: $($script.ManifestPath)" }
    $original = Get-ScriptFingerprint $script.Source
    foreach ($field in @('rawLength', 'wrappedLength', 'rawSHA256', 'wrappedSHA256')) {
        if ($original.$field -ne $records[0].$field) {
            throw "Unsupported original script fingerprint ($field): $($script.ManifestPath)"
        }
    }
    $script.OriginalFingerprint = $original
}
$version = & $Repak --version
if ($LASTEXITCODE -ne 0 -or $version.Trim() -ne 'repak_cli 0.2.3') { throw 'This builder requires repak_cli 0.2.3.' }
$version = & $Retoc --version
if ($LASTEXITCODE -ne 0 -or $version.Trim() -ne 'retoc_cli 0.1.5') { throw 'This builder requires retoc_cli 0.1.5.' }
$utf8 = [Text.UTF8Encoding]::new($false)
$source = [IO.File]::ReadAllText($OriginalScript, $utf8)
foreach ($anchor in @(
    'exports.abilityWidgetMixinInterface = abilityWidgetMixinInterface;',
    'checkNodeActivationConditions(nodeID, nodeType, abilityNodeComponent, abilityNodeManager, nodeTableData)',
    'executeActivateNode()',
    'BP_OnActivated()'
)) {
    if (-not $source.Contains($anchor)) { throw "Native skill patch anchor is missing: $anchor" }
}
$patch = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\AbilityWidgetPatch.js'), $utf8)
$sourceMap = '//# sourceMappingURL=AbilityWidget.js.map'
$index = $source.IndexOf($sourceMap, [StringComparison]::Ordinal)
if ($index -ge 0) { $source = $source.Substring(0, $index) + "`n" + $patch + "`n" + $source.Substring($index) }
else { $source += "`n" + $patch + "`n" }

$OutputPak = [IO.Path]::GetFullPath($OutputPak)
# File.Replace requires source and destination on the same volume.
$staging = Join-Path ([IO.Path]::GetDirectoryName($OutputPak)) ('.PBZRogue-Build-' + [Guid]::NewGuid().ToString('N'))
$temporaryPak = $OutputPak + '.building-' + [Guid]::NewGuid().ToString('N')
$preserveStaging = $false
try {
    $target = Join-Path $staging 'ProjectPBZ\Content\JavaScript\UI\Widget\AbilityWidget.js'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::WriteAllText($target, $source, $utf8)
    foreach ($script in $additionalScripts) {
        $native = [IO.File]::ReadAllText($script.Source, $utf8)
        $scriptPatch = (@(foreach ($patchPath in @($script.Patch)) {
            [IO.File]::ReadAllText((Join-Path $PSScriptRoot ('..\src\' + $patchPath)), $utf8)
        }) -join "`n")
        $map = '//# sourceMappingURL=' + [IO.Path]::GetFileName($script.Relative) + '.map'
        $mapIndex = $native.IndexOf($map, [StringComparison]::Ordinal)
        if ($mapIndex -ge 0) {
            $native = $native.Substring(0, $mapIndex) + "`n" + $scriptPatch + "`n" + $native.Substring($mapIndex)
        } else {
            $native += "`n" + $scriptPatch + "`n"
        }
        $scriptTarget = Join-Path $staging ('ProjectPBZ\Content\JavaScript\' + $script.Relative)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($scriptTarget))
        [IO.File]::WriteAllText($scriptTarget, $native, $utf8)
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPak))
    & $Repak pack --version V11 --mount-point '../../../' $staging $temporaryPak
    if ($LASTEXITCODE -ne 0) { throw 'Native skill patch packing failed.' }
    # This game rejects standalone paks when the paired IoStore container is absent.
    # Match the shipped TOC8/header5 format (retoc's UE5_6 profile), with a new container ID.
    $emptyInput = Join-Path $staging 'empty'
    $containerDirectory = Join-Path $staging 'container'
    [void][IO.Directory]::CreateDirectory($emptyInput)
    [void][IO.Directory]::CreateDirectory($containerDirectory)
    $temporaryToc = Join-Path $containerDirectory ([IO.Path]::ChangeExtension([IO.Path]::GetFileName($OutputPak), '.utoc'))
    & $Retoc to-zen $emptyInput $temporaryToc --version UE5_6
    if ($LASTEXITCODE -ne 0) { throw 'Native skill IoStore container generation failed.' }
    & $Retoc verify $temporaryToc
    if ($LASTEXITCODE -ne 0) { throw 'Native skill IoStore container verification failed.' }
    $pakHash = (Get-FileHash -LiteralPath $temporaryPak -Algorithm SHA256).Hash
    $header = @(
        '#pragma once'
        '#include <cstdint>'
        'namespace pbz_integrity {'
        'struct Fingerprint { uint64_t raw_length; uint64_t wrapped_length; unsigned char raw_hash[32]; unsigned char wrapped_hash[32]; };'
        'struct Patch { const wchar_t* path; Fingerprint original; Fingerprint patched; };'
        ('inline constexpr unsigned char executable_hash[32] = ' + (ConvertTo-CppHash $supported.exeSHA256) + ';')
        ('inline constexpr unsigned char pak_hash[32] = ' + (ConvertTo-CppHash $pakHash) + ';')
        'inline constexpr Patch patches[] = {'
        foreach ($script in ($integrityScripts | Sort-Object { $_.ManifestPath })) {
            $patched = Get-ScriptFingerprint (Join-Path $staging ('ProjectPBZ\Content\JavaScript\' + $script.Relative))
            '    { L"' + $script.ManifestPath + '", ' + (ConvertTo-CppFingerprint $script.OriginalFingerprint) +
                ', ' + (ConvertTo-CppFingerprint $patched) + ' },'
        }
        '};'
        '}'
    ) -join "`n"
    $manifestHeader = Join-Path $staging 'ScriptIntegrity.generated.h'
    [IO.File]::WriteAllText($manifestHeader, $header + "`n", $utf8)
    $temporaryDll = Join-Path $staging 'ScriptIntegrity.dll'
    & (Join-Path $PSScriptRoot 'BuildScriptIntegrity.ps1') -ManifestHeader $manifestHeader -OutputDll $temporaryDll | Out-Null

    # Compile and validate every member before publishing. Keep rollback copies
    # so a failed replacement cannot leave a new pak paired with an old adapter.
    $bundle = @(
        @{ Source = [IO.Path]::ChangeExtension($temporaryToc, '.ucas'); Extension = '.ucas' }
        @{ Source = $temporaryToc; Extension = '.utoc' }
        @{ Source = $temporaryDll; Extension = '.dll' }
        @{ Source = $temporaryPak; Extension = '.pak' }
    )
    foreach ($member in $bundle) {
        if (-not [IO.File]::Exists($member.Source) -or ([IO.FileInfo]::new($member.Source)).Length -eq 0) {
            throw "Native skill bundle output is missing: $($member.Extension)"
        }
        $member.Destination = if ($member.Extension -eq '.pak') { $OutputPak } else { [IO.Path]::ChangeExtension($OutputPak, $member.Extension) }
        $member.Backup = Join-Path $staging ('previous' + $member.Extension)
        $member.Existed = [IO.File]::Exists($member.Destination)
        if ($member.Existed) { [IO.File]::Copy($member.Destination, $member.Backup) }
    }
    $published = [Collections.Generic.List[object]]::new()
    try {
        foreach ($member in $bundle) {
            if ($member.Existed) { [IO.File]::Replace($member.Source, $member.Destination, [NullString]::Value) }
            else { [IO.File]::Move($member.Source, $member.Destination) }
            $published.Add($member)
        }
    } catch {
        $publishError = $_
        for ($i = $published.Count - 1; $i -ge 0; $i--) {
            $member = $published[$i]
            try {
                if ($member.Existed) { [IO.File]::Replace($member.Backup, $member.Destination, [NullString]::Value) }
                else { [IO.File]::Delete($member.Destination) }
            } catch {
                $preserveStaging = $true
                Write-Warning "Bundle rollback failed for $($member.Destination); recovery copies retained in $staging"
            }
        }
        throw $publishError
    }
    [PSCustomObject]@{
        Path = $OutputPak
        TocPath = [IO.Path]::ChangeExtension($OutputPak, '.utoc')
        ContainerPath = [IO.Path]::ChangeExtension($OutputPak, '.ucas')
        DLLPath = [IO.Path]::ChangeExtension($OutputPak, '.dll')
        NativeSourceSHA256 = $expectedHash
        AdditionalSourceSHA256 = @($additionalScripts | ForEach-Object { $_.Hash })
        SHA256 = $pakHash
    }
}
finally {
    if ([IO.File]::Exists($temporaryPak)) { [IO.File]::Delete($temporaryPak) }
    if (-not $preserveStaging -and [IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $true) }
}
