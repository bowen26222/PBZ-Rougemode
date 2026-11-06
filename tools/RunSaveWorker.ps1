[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GameRoot,
    [Parameter(Mandatory = $true)][string]$ProfileDirectory,
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{32}$')][string]$WorkerId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProfileDirectory = [IO.Path]::GetFullPath($ProfileDirectory).TrimEnd('\', '/')
$runs = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PBZRogue\Runs')).TrimEnd('\', '/')
if (-not ([IO.Path]::GetDirectoryName($ProfileDirectory).Equals($runs, [StringComparison]::OrdinalIgnoreCase)) -or
    [IO.Path]::GetFileName($ProfileDirectory) -notmatch '^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$') {
    throw 'Save worker requires an isolated run profile.'
}
$ancestor = Get-Item -LiteralPath $ProfileDirectory -Force
while ($null -ne $ancestor) {
    if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Save worker profile must not traverse a reparse point.' }
    $ancestor = $ancestor.Parent
}
$game = [Diagnostics.Process]::GetProcessById($GameProcessId)
$ready = Join-Path $ProfileDirectory ('save-worker-' + $WorkerId + '.ready')
$entry = Join-Path $PSScriptRoot 'StartIsolatedGame.ps1'
if (-not [IO.File]::Exists($entry)) { throw 'Checkpoint worker entry is missing.' }

function Write-FailureReceipt([string]$Id, [string]$Operation, [object]$Checkpoint, [string]$Message) {
    $path = Join-Path $ProfileDirectory ('operation-' + $Id + '.json')
    if ([IO.File]::Exists($path)) { return }
    $temporary = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $result = @{schema = 1; id = $Id; operation = $Operation; checkpoint = $Checkpoint; success = $false; error = $Message}
        [IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        try { [IO.File]::Move($temporary, $path) }
        catch { if (-not [IO.File]::Exists($path)) { throw } }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

try {
    [IO.File]::WriteAllText($ready + '.tmp', (@{schema = 1; worker = $WorkerId; process = $PID} | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($ready + '.tmp', $ready)
    while ($true) {
        foreach ($request in @(Get-ChildItem -LiteralPath $ProfileDirectory -Filter 'operation-*.request.json' -File)) {
            if ($request.Name -notmatch '^operation-([0-9]+-[0-9]+)\.request\.json$') { continue }
            $id = $Matches[1]
            if ($request.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Save request must not be a reparse point.' }
            $job = [IO.File]::ReadAllText($request.FullName) | ConvertFrom-Json
            if ($job.worker -cne $WorkerId) { continue }
            if ($job.schema -ne 1 -or $job.id -cne $id -or $job.operation -cnotin @('Checkpoint', 'Discard')) {
                throw 'Invalid save request.'
            }
            $checkpoint = $null
            if ($job.operation -ceq 'Checkpoint') {
                $checkpoint = $job.checkpoint
                if ($checkpoint -notmatch '^[0-9]+-[0-9]+$') { throw 'Invalid checkpoint request.' }
            }
            $result = Join-Path $ProfileDirectory ('operation-' + $id + '.json')
            try {
                if (-not [IO.File]::Exists($result)) {
                    $start = [Diagnostics.ProcessStartInfo]::new()
                    $start.FileName = Join-Path $PSHOME 'powershell.exe'
                    $start.UseShellExecute = $false
                    $start.CreateNoWindow = $true
                    $start.RedirectStandardOutput = $true
                    $start.RedirectStandardError = $true
                    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $entry +
                        '" -GameRoot "' + $GameRoot + '" -ProfileDirectory "' + $ProfileDirectory +
                        '" -Operation ' + $job.operation + ' -JobId ' + $id
                    if ($null -ne $checkpoint) { $start.Arguments += ' -CheckpointId ' + $checkpoint }
                    $child = [Diagnostics.Process]::Start($start)
                    if ($null -eq $child) { throw 'Cannot start checkpoint worker.' }
                    try {
                        $stdout = $child.StandardOutput.ReadToEndAsync()
                        $stderr = $child.StandardError.ReadToEndAsync()
                        $child.WaitForExit()
                        [void]$stdout.GetAwaiter().GetResult()
                        $errorText = $stderr.GetAwaiter().GetResult()
                        if (-not [IO.File]::Exists($result)) {
                            throw ('Checkpoint worker exited without a receipt (exit ' + $child.ExitCode + '): ' + $errorText)
                        }
                    } finally { $child.Dispose() }
                }
            } catch {
                Write-FailureReceipt $id $job.operation $checkpoint $_.Exception.Message
            } finally {
                [IO.File]::Delete($request.FullName)
            }
        }
        $game.Refresh()
        if ($game.HasExited) { break }
        Start-Sleep -Milliseconds 50
    }
} finally {
    if ([IO.File]::Exists($ready)) { [IO.File]::Delete($ready) }
    $game.Dispose()
}
