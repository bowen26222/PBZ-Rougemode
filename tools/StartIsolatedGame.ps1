[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameRoot,
    [string]$ProfileDirectory,
    [switch]$WaitForGameExit,
    [string]$ReadyFile,
    [ValidateSet('Launch', 'Checkpoint', 'Discard')]
    [string]$Operation = 'Launch',
    # Internal explicit-profile override; normal Launch selects the latest run.
    [switch]$Resume,
    [string]$CheckpointId,
    [string]$JobId,
    [ValidateSet('zh', 'en')]
    [string]$Language = 'en'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:launchWindow = $null
$script:launchLabel = $null
$script:profileLock = $null
$script:operationResultPath = $null
$script:operationTemporaryPath = $null
$script:operationCancelPath = $null
$script:operationReceiptWritten = $false

function Get-LaunchText([string]$Chinese, [string]$English) {
    if ($Language -eq 'zh') { return $Chinese }
    return $English
}

function Show-LaunchProgress([string]$Message) {
    if (-not $ReadyFile) { return }
    if ($null -eq $script:launchWindow) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $script:launchWindow = [Windows.Forms.Form]::new()
        $script:launchWindow.Text = Get-LaunchText '无尽修炼 — 正在切换独立存档' 'Endless Trials — Switching to an isolated save'
        $script:launchWindow.ClientSize = [Drawing.Size]::new(600, 150)
        $script:launchWindow.StartPosition = 'CenterScreen'
        $script:launchWindow.FormBorderStyle = 'FixedDialog'
        $script:launchWindow.ControlBox = $false
        $script:launchLabel = [Windows.Forms.Label]::new()
        $script:launchLabel.Location = [Drawing.Point]::new(24, 24)
        $script:launchLabel.Size = [Drawing.Size]::new(552, 104)
        $script:launchLabel.Font = [Drawing.Font]::new('Microsoft YaHei UI', 11)
        $script:launchWindow.Controls.Add($script:launchLabel)
        $script:launchWindow.Show()
    }
    $script:launchLabel.Text = $Message
    [Windows.Forms.Application]::DoEvents()
}

function Close-LaunchProgress {
    if ($null -ne $script:launchWindow) {
        $script:launchWindow.Close()
        $script:launchWindow.Dispose()
        $script:launchWindow = $null
    }
}

function Wait-ModeEntry([Diagnostics.Process]$GameProcess, [string]$Profile) {
    $statePath = Join-Path $Profile 'run-state.json'
    $windowShown = $false
    while ($true) {
        if ($GameProcess.HasExited) {
            throw (Get-LaunchText "独立游戏在完成模式初始化前退出（退出码 $($GameProcess.ExitCode)）。请查看原生错误提示和 UE4SS.log。存档目录：$Profile" "The isolated game exited before mode initialization finished (exit code $($GameProcess.ExitCode)). Check the native error dialog and UE4SS.log. Save directory: $Profile")
        }
        $state = $null
        if ([IO.File]::Exists($statePath)) {
            # The game rewrites this small record; an in-progress write is not a failure.
            try { $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json } catch { }
        }
        if ($null -ne $state -and $null -ne $state.PSObject.Properties['phase']) {
            if ($state.phase -eq 'failed') {
                $reason = Get-LaunchText '详情见 UE4SS.log' 'See UE4SS.log for details'
                if ($null -ne $state.PSObject.Properties['error']) { $reason = ($state.error -split "`n")[0] }
                throw (Get-LaunchText "爬塔初始化失败：$reason`n独立存档目录：$Profile" "Endless Trials initialization failed: $reason`nIsolated save directory: $Profile")
            }
            if ($state.phase -in @('ready', 'between', 'combat', 'rest', 'bell', 'shop', 'skills', 'ended')) {
                Write-LaunchStatus 'entered' $Profile
                Close-LaunchProgress
                return
            }
        }
        $GameProcess.Refresh()
        if (-not $windowShown -and $GameProcess.MainWindowHandle -ne 0) {
            # Let the player acknowledge native startup dialogs without an overlapping window.
            $script:launchWindow.Hide()
            $windowShown = $true
        }
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
    }
}

function Write-LaunchStatus([string]$State, [string]$Detail) {
    if (-not [string]::IsNullOrWhiteSpace($ReadyFile)) {
        [IO.File]::WriteAllText($ReadyFile, $State + "`n" + $Detail, [Text.UTF8Encoding]::new($false))
    }
}

function Assert-LaunchNotCancelled {
    if ($ReadyFile -and [IO.File]::Exists($ReadyFile + '.cancel')) {
        throw (Get-LaunchText '上一个游戏进程已取消模式启动。' 'Mode launch was cancelled by the previous game process.')
    }
}

trap {
    $message = $_.Exception.Message
    if ($null -ne $script:operationResultPath -and -not $script:operationReceiptWritten) {
        try { Write-OperationReceipt $false $message }
        catch { Write-Warning ((Get-LaunchText '无法发布操作失败回执：' 'Could not publish operation failure receipt: ') + $_.Exception.Message) }
    }
    Exit-ProfileLock
    Write-LaunchStatus 'error' $message
    if ($null -ne $script:launchWindow) {
        $script:launchWindow.Show()
        [void][Windows.Forms.MessageBox]::Show($script:launchWindow, $message, (Get-LaunchText '无尽修炼启动失败' 'Endless Trials launch failed'),
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
        Close-LaunchProgress
    }
    Write-Error $_
    exit 1
}

function Assert-NoReparsePoint([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        try {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (Get-LaunchText "存档路径经过重解析点：$current" "Profile path traverses a reparse point: $current")
            }
        } catch [IO.FileNotFoundException] {
        } catch [IO.DirectoryNotFoundException] {
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Assert-Outside([string]$Path, [string]$ProtectedRoot) {
    $root = [IO.Path]::GetFullPath($ProtectedRoot).TrimEnd('\', '/')
    if ($Path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw (Get-LaunchText "独立存档必须位于原游戏数据目录之外：$root" "Profile must be outside the original game's data: $root")
    }
}

function Assert-RunProfile([string]$Profile) {
    Assert-Outside $Profile $GameRoot
    Assert-Outside $Profile (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ProjectPBZ')
    Assert-NoReparsePoint $Profile
    if (-not [IO.Path]::GetDirectoryName($Profile).Equals($runsRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Profile) -notmatch $guidPattern) {
        throw (Get-LaunchText '独立存档必须是隔离 Runs 目录下的 GUID 子目录。' 'Profile must be a GUID directory directly under the isolated Runs namespace.')
    }
}

function Enter-ProfileLock([string]$Profile) {
    Assert-RunProfile $Profile
    $lockPath = Join-Path $Profile '.save-operation.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    while ($true) {
        Assert-NoReparsePoint $lockPath
        if ([IO.Directory]::Exists($lockPath)) { throw (Get-LaunchText '存档操作锁必须是文件。' 'The save operation lock must be a file.') }
        try {
            return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if (($_.Exception.HResult -band 0xffff) -notin @(32, 33)) { throw }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw (Get-LaunchText "等待存档操作完成超时：$Profile" "Timed out waiting for the profile's save operation to finish: $Profile")
            }
        }
        if ($Operation -eq 'Launch') {
            Assert-LaunchNotCancelled
            if ($null -ne $script:launchWindow) { [Windows.Forms.Application]::DoEvents() }
        }
        Start-Sleep -Milliseconds 100
    }
}

function Exit-ProfileLock {
    if ($null -ne $script:profileLock) {
        $script:profileLock.Dispose()
        $script:profileLock = $null
    }
}

function Test-RunDead([string]$Profile) {
    $marker = Join-Path $Profile 'run-dead'
    Assert-NoReparsePoint $marker
    if ([IO.Directory]::Exists($marker)) { throw (Get-LaunchText 'run-dead 标记必须是文件。' 'The run-dead marker must be a file.') }
    return [IO.File]::Exists($marker)
}

function Get-SafeFiles([string]$Directory) {
    Assert-NoReparsePoint $Directory
    foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Force)) {
        Assert-NoReparsePoint $entry.FullName
        if ($entry.PSIsContainer) { Get-SafeFiles $entry.FullName }
        else { $entry }
    }
}

function Remove-ProfilePath([string]$Path) {
    Assert-NoReparsePoint $Path
    if ([IO.Directory]::Exists($Path)) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force)) {
            Remove-ProfilePath $entry.FullName
        }
        [IO.Directory]::Delete($Path)
    } elseif ([IO.File]::Exists($Path)) {
        [IO.File]::Delete($Path)
    }
}

function Remove-DeadRunPayload([string]$Profile) {
    # The caller owns the profile lock; checkpoint rollback must not acquire it recursively.
    Assert-RunProfile $Profile
    if (-not (Test-RunDead $Profile)) { throw (Get-LaunchText '清理存档需要已有的 run-dead 标记。' 'Discard requires an existing run-dead marker.') }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Profile -Force)) {
        if ($entry.Name -eq 'NativeSaveGames') {
            Assert-NoReparsePoint $entry.FullName
            if (-not $entry.PSIsContainer) { throw (Get-LaunchText 'NativeSaveGames 必须是目录。' 'NativeSaveGames must be a directory.') }
            foreach ($nativeEntry in @(Get-ChildItem -LiteralPath $entry.FullName -Force)) {
                Assert-NoReparsePoint $nativeEntry.FullName
                # Preferences survive an in-process restart; campaign payload never does.
                if ($nativeEntry.Name -in @('PBZSharedSetting.sav', 'PBZLocalSetting.sav', 'EnhancedInputUserSettings.sav') -and
                    -not $nativeEntry.PSIsContainer) { continue }
                Remove-ProfilePath $nativeEntry.FullName
            }
        } elseif ($entry.Name -in @('checkpoint.json', 'Checkpoints') -or
            $entry.Name -match '^pending-.*\.json$' -or
            $entry.Name -match '^checkpoint\.json\.[0-9]+-[0-9]+$' -or
            $entry.Name -match '^NativeSaveGames\.(previous|restore)-[0-9a-f]{32}$') {
            Remove-ProfilePath $entry.FullName
        }
    }
    # Never delete the profile or tombstone: its creation time prevents older-run fallback.
}

function Clear-DeadRunProfile([string]$Profile) {
    $handle = Enter-ProfileLock $Profile
    try {
        if (Test-RunDead $Profile) { Remove-DeadRunPayload $Profile }
    } finally { $handle.Dispose() }
}

function Assert-CheckpointActive([string]$Profile) {
    if (Test-RunDead $Profile) { throw (Get-LaunchText '无法保存已结束的本局。' 'Cannot save an ended run.') }
    Assert-NoReparsePoint $script:operationCancelPath
    if ([IO.Directory]::Exists($script:operationCancelPath)) { throw (Get-LaunchText '操作取消标记必须是文件。' 'The operation cancellation marker must be a file.') }
    if ([IO.File]::Exists($script:operationCancelPath)) { throw (Get-LaunchText '检查点保存操作已取消。' 'Checkpoint operation was cancelled.') }
}

function Assert-CheckpointState([object]$State, [string]$Id) {
    if ($State.schema -ne 1 -or $State.checkpoint -ne $Id -or
        $State.wave -notin @(1, 2, 3) -or $State.nativeSlot -notmatch '^ManualSave[0-9]+$') {
        throw (Get-LaunchText '存档中的波次边界无效。' 'Invalid saved run boundary.')
    }
    $equipment = $State.equipment
    if ($null -eq $equipment -or $equipment.floor -ne $State.floor -or $equipment.wave -ne $State.wave -or
        $equipment.sections -isnot [Array]) {
        throw (Get-LaunchText '装备快照与已完成的波次不匹配。' 'Equipment snapshot does not match the completed wave.')
    }
    $shop = $equipment.PSObject.Properties['shop']
    if ($State.wave -eq 1) {
        if ($equipment.sections.Count -ne 0 -or ($null -ne $shop -and $shop.Value -cne $false)) {
            throw (Get-LaunchText '第一波不能包含已开启的商店。' 'Wave one cannot contain an active shop.')
        }
    } elseif ($equipment.sections.Count -eq 0 -or ($null -ne $shop -and $shop.Value -cne $true)) {
        throw (Get-LaunchText '铃铛检查点缺少当前商店。' 'Bell checkpoint is missing its current shop.')
    }
}

function Write-DurableFile([string]$Path, [byte[]]$Bytes) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Copy-GamePreferences([string]$GameSaved, [string]$UserSaved, [string]$Profile) {
    # Never copy a Saved tree: it also contains campaign progress and cloud metadata.
    $files = @(
        @{Source = (Join-Path $UserSaved 'Config\Windows\GameUserSettings.ini'); Target = 'Saved\Config\Windows\GameUserSettings.ini'}
    )
    foreach ($name in @('PBZSharedSetting.sav', 'PBZLocalSetting.sav', 'EnhancedInputUserSettings.sav')) {
        $files += @{Source = (Join-Path $GameSaved $name); Target = ('NativeSaveGames\' + $name)}
    }
    foreach ($file in $files) {
        Assert-NoReparsePoint $file.Source
        if (-not [IO.File]::Exists($file.Source)) { continue }
        $destination = Join-Path $Profile $file.Target
        Assert-NoReparsePoint $destination
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        Write-DurableFile $destination ([IO.File]::ReadAllBytes($file.Source))
    }
}

function Write-OperationReceipt([bool]$Success, [string]$ErrorMessage) {
    Assert-NoReparsePoint $script:operationResultPath
    Assert-NoReparsePoint $script:operationTemporaryPath
    $checkpoint = $null
    if ($Operation -eq 'Checkpoint') { $checkpoint = $CheckpointId }
    $failure = $null
    if (-not $Success) { $failure = $ErrorMessage }
    $json = [ordered]@{
        schema = 1; id = $JobId; operation = $Operation; checkpoint = $checkpoint
        success = $Success; error = $failure
    } | ConvertTo-Json -Compress
    try {
        Write-DurableFile $script:operationTemporaryPath ([Text.Encoding]::UTF8.GetBytes($json))
        # Receipt publication is the terminal boundary. No payload writes may follow it.
        if ($Success -and $Operation -eq 'Checkpoint') { Assert-CheckpointActive $ProfileDirectory }
        # A terminal receipt is immutable, including duplicate JobId failures.
        [IO.File]::Move($script:operationTemporaryPath, $script:operationResultPath)
        $script:operationReceiptWritten = $true
    } catch {
        Remove-ProfilePath $script:operationTemporaryPath
        throw
    }
}

function Read-Checkpoint([string]$Profile) {
    Assert-RunProfile $Profile
    if (Test-RunDead $Profile) { throw (Get-LaunchText '本局已结束，无法继续。' 'This run has ended and cannot be resumed.') }
    $pointerPath = Join-Path $Profile 'checkpoint.json'
    Assert-NoReparsePoint $pointerPath
    $pointer = [IO.File]::ReadAllText($pointerPath) | ConvertFrom-Json
    if ($pointer.schema -ne 1 -or $pointer.id -notmatch '^[0-9]+-[0-9]+$') { throw (Get-LaunchText '检查点指针无效。' 'Invalid checkpoint pointer.') }
    $directory = Join-Path $Profile ('Checkpoints\' + $pointer.id)
    Assert-NoReparsePoint $directory
    $manifestPath = Join-Path $directory 'complete.json'
    Assert-NoReparsePoint $manifestPath
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.id -ne $pointer.id) { throw (Get-LaunchText '检查点不完整。' 'Incomplete checkpoint.') }
    if (-not ($manifest.files.path -contains 'state.json')) { throw (Get-LaunchText '完成清单缺少自定义模式状态。' 'Custom run state is absent from completion manifest.') }
    foreach ($entry in $manifest.files) {
        if ($entry.path -notmatch '^(state\.json|NativeSaveGames/[A-Za-z0-9_./-]+)$' -or $entry.path.Contains('..')) { throw (Get-LaunchText '检查点路径不安全。' 'Unsafe checkpoint path.') }
        $file = Join-Path $directory $entry.path
        Assert-NoReparsePoint $file
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.sha256) { throw (Get-LaunchText "检查点数据已损坏：$($entry.path)" "Checkpoint data is damaged: $($entry.path)") }
    }
    $state = [IO.File]::ReadAllText((Join-Path $directory 'state.json')) | ConvertFrom-Json
    Assert-CheckpointState $state $pointer.id
    if ($manifest.nativeContainer -notmatch '^NativeSaveGames/[A-Za-z0-9_/-]+/PBZSaveGame\.sav$' -or
        -not ($manifest.files.path -contains $manifest.nativeContainer)) { throw (Get-LaunchText '完成清单缺少原生存档容器。' 'Native save container is absent from completion manifest.') }
    return [PSCustomObject]@{Directory = $directory; State = $state; Manifest = $manifest}
}

$runsRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PBZRogue\Runs')).TrimEnd('\', '/')
$guidPattern = '^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
Assert-NoReparsePoint $runsRoot
if ($Operation -ne 'Launch' -and ([string]::IsNullOrWhiteSpace($ProfileDirectory) -or $Resume)) {
    throw (Get-LaunchText 'Checkpoint 和 Discard 需要明确指定存档目录，且不能使用 Resume。' 'Checkpoint and Discard require an explicit profile and cannot use Resume.')
}
if ($Resume -and [string]::IsNullOrWhiteSpace($ProfileDirectory)) { throw (Get-LaunchText 'Resume 需要明确指定存档目录。' 'Resume requires an explicit profile.') }
if ($Operation -ne 'Checkpoint' -and $CheckpointId) { throw (Get-LaunchText 'CheckpointId 仅适用于 Checkpoint。' 'CheckpointId is only valid for Checkpoint.') }
if ($Operation -eq 'Launch') {
    if ($PSBoundParameters.ContainsKey('JobId')) { throw (Get-LaunchText 'JobId 不适用于 Launch。' 'JobId is not valid for Launch.') }
} elseif ($JobId -notmatch '^[0-9]+-[0-9]+$') {
    throw (Get-LaunchText 'Checkpoint 和 Discard 需要数字-数字格式的 JobId。' 'Checkpoint and Discard require a JobId formatted as digits-digits.')
}

$GameRoot = (Resolve-Path -LiteralPath $GameRoot).ProviderPath.TrimEnd('\', '/')
if ($Operation -ne 'Launch') {
    $ProfileDirectory = [IO.Path]::GetFullPath($ProfileDirectory).TrimEnd('\', '/')
    Assert-RunProfile $ProfileDirectory
    if (-not [IO.Directory]::Exists($ProfileDirectory)) { throw (Get-LaunchText '后台操作需要已存在的独立存档目录。' 'Worker operations require an existing isolated profile directory.') }
    $resultPath = Join-Path $ProfileDirectory ('operation-' + $JobId + '.json')
    $temporaryPath = $resultPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    $cancelPath = Join-Path $ProfileDirectory ('operation-' + $JobId + '.cancel')
    Assert-NoReparsePoint $resultPath
    Assert-NoReparsePoint $temporaryPath
    Assert-NoReparsePoint $cancelPath
    if ([IO.Directory]::Exists($resultPath)) { throw (Get-LaunchText '操作回执必须是文件。' 'The operation receipt must be a file.') }
    $script:operationTemporaryPath = $temporaryPath
    $script:operationCancelPath = $cancelPath
    $script:operationResultPath = $resultPath
    $script:profileLock = Enter-ProfileLock $ProfileDirectory
    if ([IO.File]::Exists($resultPath)) { throw (Get-LaunchText '此 JobId 已有回执，每次操作必须使用唯一的 JobId。' 'This JobId already has a receipt; every operation requires a unique JobId.') }
}
$gameExecutable = Join-Path $GameRoot 'platform\steam\PBZ.exe'
if (-not (Test-Path -LiteralPath $gameExecutable -PathType Leaf)) {
    throw (Get-LaunchText "找不到游戏可执行文件：$gameExecutable" "Game executable not found: $gameExecutable")
}
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($gameExecutable).ProductVersion
if ($version -ne 'CL-302256_JKS-17280') {
    throw (Get-LaunchText "尚未验证此游戏版本的存档目录覆盖功能：$version" "Save-directory overrides have not been verified for this game version: $version")
}

$profiles = @()
if ($Operation -eq 'Launch') {
    $running = @(Get-Process -Name PBZ -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.Equals($gameExecutable, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($running.Count -gt 0 -and -not $WaitForGameExit) {
        throw (Get-LaunchText '请先关闭正在运行的游戏，或通过菜单切换时使用 -WaitForGameExit。' 'Close the running game first, or use -WaitForGameExit for a menu-initiated switch.')
    }
    Assert-LaunchNotCancelled
    if ([IO.Directory]::Exists($runsRoot)) {
        $profiles = @(Get-ChildItem -LiteralPath $runsRoot -Directory -Force |
            Where-Object { $_.Name -match $guidPattern } |
            Sort-Object -Property @{Expression = 'CreationTimeUtc'; Descending = $true}, @{Expression = 'Name'; Descending = $true})
        foreach ($candidate in $profiles) {
            Assert-RunProfile $candidate.FullName
            Clear-DeadRunProfile $candidate.FullName
        }
    }
    if ([string]::IsNullOrWhiteSpace($ProfileDirectory) -and $profiles.Count -gt 0) {
        # Select the latest attempt, not the latest surviving checkpoint. A dead or
        # never-checkpointed attempt permanently prevents fallback to an older run.
        $latest = $profiles[0].FullName
        $script:profileLock = Enter-ProfileLock $latest
        try {
            $pointer = Join-Path $latest 'checkpoint.json'
            Assert-NoReparsePoint $pointer
            if (-not (Test-RunDead $latest) -and
                ([IO.File]::Exists($pointer) -or [IO.Directory]::Exists($pointer))) {
                $ProfileDirectory = $latest
                $Resume = $true
            }
        } finally { Exit-ProfileLock }
    }
}

if ([string]::IsNullOrWhiteSpace($ProfileDirectory)) {
    $ProfileDirectory = Join-Path $runsRoot ([Guid]::NewGuid().ToString('N'))
}
$ProfileDirectory = [IO.Path]::GetFullPath($ProfileDirectory).TrimEnd('\', '/')
if ($ProfileDirectory -eq [IO.Path]::GetPathRoot($ProfileDirectory).TrimEnd('\', '/')) {
    throw (Get-LaunchText '不能将驱动器根目录用作模式存档。' 'A drive root cannot be a mode profile.')
}
Assert-RunProfile $ProfileDirectory

if ($Operation -eq 'Discard') {
    Remove-DeadRunPayload $ProfileDirectory
    Write-OperationReceipt $true $null
    Exit-ProfileLock
    exit 0
}

if ($Operation -eq 'Checkpoint') {
    if ($CheckpointId -notmatch '^[0-9]+-[0-9]+$') { throw (Get-LaunchText '检查点标识无效。' 'Invalid checkpoint identifier.') }
    $staging = $null
    $complete = $null
    $temporary = $null
    $stagingOwned = $false
    $completeOwned = $false
    $temporaryOwned = $false
    $published = $false
    $previousPointer = $null
    $hadPreviousPointer = $false
    try {
        Assert-CheckpointActive $ProfileDirectory
        $statePath = Join-Path $ProfileDirectory ('pending-' + $CheckpointId + '.json')
        Assert-NoReparsePoint $statePath
        $stateBytes = [IO.File]::ReadAllBytes($statePath)
        $state = [Text.Encoding]::UTF8.GetString($stateBytes) | ConvertFrom-Json
        Assert-CheckpointState $state $CheckpointId
        $source = Join-Path $ProfileDirectory 'NativeSaveGames'
        Assert-NoReparsePoint $source
        $nativeFiles = @(Get-SafeFiles $source | Where-Object { $_.Name -notmatch '^PBZRogueProbe_[0-9a-f]{32}\.sav$' })
        $containers = @($nativeFiles | Where-Object { $_.Name -eq 'PBZSaveGame.sav' })
        if ($containers.Count -ne 1) { throw (Get-LaunchText '独立原生存档容器数量应为一个。' 'Expected one isolated native save container.') }
        Assert-NoReparsePoint $containers[0].FullName
        $nativeContainer = 'NativeSaveGames/' + $containers[0].FullName.Substring($source.Length + 1).Replace('\', '/')
        $checkpointRoot = Join-Path $ProfileDirectory 'Checkpoints'
        Assert-NoReparsePoint $checkpointRoot
        [void][IO.Directory]::CreateDirectory($checkpointRoot)
        $staging = Join-Path $checkpointRoot ($CheckpointId + '.pending')
        $complete = Join-Path $checkpointRoot $CheckpointId
        $pointer = Join-Path $ProfileDirectory 'checkpoint.json'
        $temporary = $pointer + '.' + $CheckpointId
        foreach ($path in @($staging, $complete, $temporary)) {
            Assert-NoReparsePoint $path
            if ([IO.Directory]::Exists($path) -or [IO.File]::Exists($path)) { throw (Get-LaunchText '此检查点代次已存在。' 'Checkpoint generation already exists.') }
        }
        Assert-NoReparsePoint $pointer
        if ([IO.Directory]::Exists($pointer)) { throw (Get-LaunchText '检查点指针必须是文件。' 'The checkpoint pointer must be a file.') }
        $hadPreviousPointer = [IO.File]::Exists($pointer)
        if ($hadPreviousPointer) { $previousPointer = [IO.File]::ReadAllBytes($pointer) }
        [void][IO.Directory]::CreateDirectory($staging)
        $stagingOwned = $true
        $files = [Collections.Generic.List[object]]::new()
        foreach ($file in $nativeFiles) {
            Assert-CheckpointActive $ProfileDirectory
            Assert-NoReparsePoint $file.FullName
            $relative = 'NativeSaveGames/' + $file.FullName.Substring($source.Length + 1).Replace('\', '/')
            $target = Join-Path $staging $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            Write-DurableFile $target ([IO.File]::ReadAllBytes($file.FullName))
            $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $hash) { throw (Get-LaunchText '捕获已完成波次的检查点期间，原生存档发生变化。' 'Native save changed during completed-wave checkpoint capture.') }
            $files.Add(@{path = $relative; sha256 = $hash})
        }
        $targetState = Join-Path $staging 'state.json'
        Write-DurableFile $targetState $stateBytes
        $files.Add(@{path = 'state.json'; sha256 = (Get-FileHash -LiteralPath $targetState -Algorithm SHA256).Hash})
        foreach ($entry in $files) {
            Assert-CheckpointActive $ProfileDirectory
            if ($entry.path -eq 'state.json') { continue }
            $original = Join-Path $source $entry.path.Substring(16)
            Assert-NoReparsePoint $original
            if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ne $entry.sha256) { throw (Get-LaunchText '检查点完成前，原生文件发生变化。' 'Native files changed before checkpoint completion.') }
        }
        $manifest = @{schema = 1; id = $CheckpointId; nativeContainer = $nativeContainer; files = @($files.ToArray())} | ConvertTo-Json -Depth 8 -Compress
        Write-DurableFile (Join-Path $staging 'complete.json') ([Text.Encoding]::UTF8.GetBytes($manifest))
        Assert-CheckpointActive $ProfileDirectory
        [IO.Directory]::Move($staging, $complete)
        $completeOwned = $true
        $stagingOwned = $false
        $temporaryOwned = $true
        Write-DurableFile $temporary ([Text.Encoding]::UTF8.GetBytes((@{schema = 1; id = $CheckpointId} | ConvertTo-Json -Compress)))
        Assert-CheckpointActive $ProfileDirectory
        if ($hadPreviousPointer) { [IO.File]::Replace($temporary, $pointer, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $pointer) }
        $published = $true
        Assert-CheckpointActive $ProfileDirectory
        [IO.File]::Delete($statePath)
        # This also checks cancellation/death after flushing the receipt temporary file.
        Write-OperationReceipt $true $null
    } catch {
        $captureError = $_
        if (Test-RunDead $ProfileDirectory) {
            Remove-DeadRunPayload $ProfileDirectory
        } else {
            if ($published) {
                Assert-NoReparsePoint $pointer
                if ($hadPreviousPointer) {
                    Write-DurableFile $temporary $previousPointer
                    # A death marker always wins, including one arriving during rollback.
                    if (-not (Test-RunDead $ProfileDirectory)) {
                        if ([IO.File]::Exists($pointer)) { [IO.File]::Replace($temporary, $pointer, [NullString]::Value) }
                        else { [IO.File]::Move($temporary, $pointer) }
                    }
                } else {
                    [IO.File]::Delete($pointer)
                }
            }
            # Only this attempt's paths are eligible for rollback; older generations survive.
            if ($stagingOwned) { Remove-ProfilePath $staging }
            if ($completeOwned) { Remove-ProfilePath $complete }
            if ($temporaryOwned) { Remove-ProfilePath $temporary }
            if (Test-RunDead $ProfileDirectory) { Remove-DeadRunPayload $ProfileDirectory }
        }
        throw $captureError
    }
    Exit-ProfileLock
    exit 0
}

# Release this preflight lock before asking the old game to exit: it may still
# need to finish a queued worker before it can acknowledge the launch handshake.
[void][IO.Directory]::CreateDirectory($ProfileDirectory)
$script:profileLock = Enter-ProfileLock $ProfileDirectory
$nativeSaveDirectory = Join-Path $ProfileDirectory 'NativeSaveGames'
Assert-NoReparsePoint $nativeSaveDirectory
if ($Resume) {
    $saved = Read-Checkpoint $ProfileDirectory
} elseif ([IO.File]::Exists((Join-Path $ProfileDirectory 'checkpoint.json')) -or
    (Test-RunDead $ProfileDirectory) -or
    ([IO.Directory]::Exists($nativeSaveDirectory) -and @(Get-ChildItem -LiteralPath $nativeSaveDirectory -Force).Count -gt 0)) {
    throw (Get-LaunchText '开始新一局需要空的独立存档；请使用 -Resume 继续检查点。' 'A new run requires an empty independent profile; use -Resume to continue a checkpoint.')
}
[IO.Directory]::CreateDirectory($nativeSaveDirectory) | Out-Null
# PBZ silently falls back to its normal save directory if this override is unwritable.
# Reject that condition before launching, rather than accepting a failed override.
$probe = Join-Path $nativeSaveDirectory ('.write-probe-' + [Guid]::NewGuid().ToString('N'))
$stream = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $stream.WriteByte(1)
    $stream.Flush($true)
}
finally {
    $stream.Dispose()
    [IO.File]::Delete($probe)
}
Exit-ProfileLock

Assert-LaunchNotCancelled
Show-LaunchProgress (Get-LaunchText "为保护主线存档，即将正常关闭当前游戏，并重新启动独立的爬塔实例。`n`n这不是闪退，请等待新游戏窗口出现。" "To protect your story saves, the current game will close normally and restart in an isolated Endless Trials instance.`n`nThis is not a crash. Please wait for the new game window.")
Write-LaunchStatus 'ready' $ProfileDirectory
foreach ($process in $running) {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while (-not $process.WaitForExit(500)) {
        Assert-LaunchNotCancelled
        if ($null -ne $script:launchWindow) { [Windows.Forms.Application]::DoEvents() }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw (Get-LaunchText '上一个游戏进程未退出，未启动独立实例。' 'The previous game process did not exit. No isolated instance was launched.')
        }
    }
}
Assert-LaunchNotCancelled
# A closing native process can recreate its dead run's save container after the
# first cleanup. Purge it again once the normal-to-isolated exit handshake ends.
foreach ($candidate in $profiles) {
    Clear-DeadRunProfile $candidate.FullName
}
$script:profileLock = Enter-ProfileLock $ProfileDirectory
if ($Resume) {
    # Do not replace a native namespace while any previous game can still write it.
    $saved = Read-Checkpoint $ProfileDirectory
    $restored = Join-Path $ProfileDirectory ('NativeSaveGames.restore-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($restored)
    foreach ($entry in $saved.Manifest.files) {
        if (-not $entry.path.StartsWith('NativeSaveGames/')) { continue }
        $destination = Join-Path $restored $entry.path.Substring(16)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        Write-DurableFile $destination ([IO.File]::ReadAllBytes((Join-Path $saved.Directory $entry.path)))
    }
    if ([IO.Directory]::Exists($nativeSaveDirectory)) {
        [IO.Directory]::Move($nativeSaveDirectory, $nativeSaveDirectory + '.previous-' + [Guid]::NewGuid().ToString('N'))
    }
    [IO.Directory]::Move($restored, $nativeSaveDirectory)
}
if (-not $Resume -and ([IO.File]::Exists((Join-Path $ProfileDirectory 'checkpoint.json')) -or
    (Test-RunDead $ProfileDirectory) -or
    ([IO.Directory]::Exists($nativeSaveDirectory) -and @(Get-ChildItem -LiteralPath $nativeSaveDirectory -Force).Count -gt 0))) {
    throw (Get-LaunchText '等待上一个游戏退出期间，独立存档发生变化。' 'The independent profile changed while waiting for the previous game to exit.')
}
if (-not $Resume) {
    Copy-GamePreferences (Join-Path $GameRoot 'ProjectPBZ\Saved') `
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ProjectPBZ\Saved') $ProfileDirectory
}
# A copied settings file cannot prove the native backend honored SaveGamesDir.
# A one-use random slot is checked through GameplayStatics, then removed by Lua.
$namespaceProbe = 'PBZRogueProbe_' + [Guid]::NewGuid().ToString('N')
Write-DurableFile (Join-Path $nativeSaveDirectory ($namespaceProbe + '.sav')) ([byte[]]@(0))
[IO.File]::Delete((Join-Path $ProfileDirectory 'run-state.json'))
Show-LaunchProgress (Get-LaunchText "正在启动独立的爬塔实例。`n`n新窗口出现后，请处理游戏原有的启动提示；完成模式初始化后此提示自动关闭。" "Starting the isolated Endless Trials instance.`n`nWhen the new window appears, acknowledge the game's startup prompts. This message closes automatically after mode initialization.")

$workerScript = Join-Path $PSScriptRoot 'RunSaveWorker.ps1'
if (-not [IO.File]::Exists($workerScript)) { throw (Get-LaunchText '缺少隐藏存档后台脚本。' 'Hidden save worker script is missing.') }
$workerId = [Guid]::NewGuid().ToString('N')

# The licensed Steam client must already be running. Without app identity, the native
# executable asks Steam to relaunch it, losing the two storage-directory arguments.
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $gameExecutable
$start.WorkingDirectory = Split-Path -Parent $gameExecutable
$start.UseShellExecute = $true
$baseDirectory = Join-Path $GameRoot 'ProjectPBZ\Binaries\Win64'
$start.Arguments = 'ProjectPBZ -basedir="' + $baseDirectory + '" -pc-platform=Steam -UserDir="' +
    $ProfileDirectory + '" -SaveGamesDir="' + $nativeSaveDirectory + '" -PBZRogue'
$start.Arguments += ' -PBZRogueWorker=' + $workerId
$start.Arguments += ' -PBZRogueProbe=' + $namespaceProbe
if ($Resume) { $start.Arguments += ' -PBZRogueResume' }
$previousAppId = $env:SteamAppId
$previousGameId = $env:SteamGameId
try {
    $env:SteamAppId = '4115450'
    $env:SteamGameId = '4115450'
    $process = [Diagnostics.Process]::Start($start)
}
finally {
    $env:SteamAppId = $previousAppId
    $env:SteamGameId = $previousGameId
}
if ($null -eq $process) {
    throw (Get-LaunchText '无法启动原生游戏进程。' 'The native game process could not be started.')
}
Exit-ProfileLock
# Warm up a GUI-less queue receiver once; saves never launch cmd.exe from PBZ.
$workerStart = [Diagnostics.ProcessStartInfo]::new()
$workerStart.FileName = Join-Path $PSHOME 'powershell.exe'
$workerStart.UseShellExecute = $false
$workerStart.CreateNoWindow = $true
$workerStart.RedirectStandardOutput = $true
$workerStart.RedirectStandardError = $true
$workerStart.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $workerScript +
    '" -GameRoot "' + $GameRoot + '" -ProfileDirectory "' + $ProfileDirectory +
    '" -GameProcessId ' + $process.Id + ' -WorkerId ' + $workerId
$background = [Diagnostics.Process]::Start($workerStart)
if ($null -eq $background) { throw (Get-LaunchText '无法启动隐藏存档后台进程。' 'Cannot start hidden save worker.') }
try {
    $workerOutput = $background.StandardOutput.ReadToEndAsync()
    $workerError = $background.StandardError.ReadToEndAsync()
    $workerReady = Join-Path $ProfileDirectory ('save-worker-' + $workerId + '.ready')
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not [IO.File]::Exists($workerReady)) {
        if ($background.HasExited) { throw ((Get-LaunchText '隐藏存档后台进程在就绪前退出：' 'Hidden save worker exited before readiness: ') + $workerError.GetAwaiter().GetResult()) }
        if ([DateTime]::UtcNow -ge $deadline) { throw (Get-LaunchText '等待隐藏存档后台进程就绪超时。' 'Hidden save worker readiness timed out.') }
        Start-Sleep -Milliseconds 50
    }
} finally { $background.Dispose() }
Write-LaunchStatus 'started' $ProfileDirectory
[PSCustomObject]@{
    ProcessId = $process.Id
    ProfileDirectory = $ProfileDirectory
    NativeSaveDirectory = $nativeSaveDirectory
} | ConvertTo-Json -Compress
if ($ReadyFile) { Wait-ModeEntry $process $ProfileDirectory }
