[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestHeader,
    [Parameter(Mandatory = $true)][string]$OutputDll,
    [string]$CompilerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ManifestHeader = (Resolve-Path -LiteralPath $ManifestHeader -ErrorAction Stop).ProviderPath
$source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\src\native\ScriptIntegrity.cpp')).ProviderPath
$OutputDll = [IO.Path]::GetFullPath($OutputDll)
if ([IO.Path]::GetExtension($OutputDll) -ne '.dll') { throw 'OutputDll must have a .dll extension.' }
if ($OutputDll -eq $ManifestHeader -or $OutputDll -eq $source) { throw 'OutputDll cannot overwrite a build input.' }
if ($CompilerPath) { $CompilerPath = (Resolve-Path -LiteralPath $CompilerPath -ErrorAction Stop).ProviderPath }

# Use an existing x64 developer environment, or initialize one inside a child cmd.
# Merely finding cl.exe on PATH is insufficient: SDK INCLUDE/LIB must be configured.
$developerCommand = $null
$activeCompiler = Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($env:VSCMD_ARG_TGT_ARCH -eq 'x64' -and $activeCompiler -and $env:INCLUDE -and $env:LIB) {
    if (-not $CompilerPath) { $CompilerPath = $activeCompiler.Source }
} else {
    $vswhereCommand = Get-Command vswhere.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $vswhere = if ($vswhereCommand) { $vswhereCommand.Source } else { $null }
    if (-not $vswhere -and ${env:ProgramFiles(x86)}) {
        $candidate = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $vswhere = $candidate }
    }
    if (-not $vswhere) { throw 'Install Visual Studio Build Tools with C++ x64 tools and a Windows SDK, or use an x64 Developer PowerShell.' }
    $installation = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if ($LASTEXITCODE -ne 0 -or $installation.Count -ne 1 -or -not $installation[0]) {
        throw 'vswhere could not find an installation with MSVC x64 tools.'
    }
    $developerCommand = Join-Path $installation[0] 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $developerCommand -PathType Leaf)) { throw "VsDevCmd.bat is missing: $developerCommand" }
}

$outputDirectory = [IO.Path]::GetDirectoryName($OutputDll)
[void][IO.Directory]::CreateDirectory($outputDirectory)
$staging = Join-Path $outputDirectory ('.ScriptIntegrity-Build-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($staging)
    # Stage the exact bytes under the include name required by the native source.
    [IO.File]::Copy($ManifestHeader, (Join-Path $staging 'ScriptIntegrity.generated.h'))
    $builtDll = Join-Path $staging 'ScriptIntegrity.dll'
    $response = Join-Path $staging 'compile.rsp'
    $arguments = @(
        '/nologo', '/LD', '/std:c++17', '/O2', '/W4', '/WX', '/MT', '/EHsc', '/guard:cf', '/utf-8',
        ('/I"' + $staging + '"'), ('"' + $source + '"'),
        ('/Fo"' + (Join-Path $staging 'ScriptIntegrity.obj') + '"'),
        ('/Fd"' + (Join-Path $staging 'ScriptIntegrity.pdb') + '"'),
        '/link', ('/OUT:"' + $builtDll + '"'), '/MACHINE:X64', '/DYNAMICBASE', '/NXCOMPAT', '/GUARD:CF', '/INCREMENTAL:NO', 'bcrypt.lib'
    )
    # MSVC accepts BOM-marked UTF-16 response files, including Unicode paths.
    [IO.File]::WriteAllLines($response, $arguments, [Text.Encoding]::Unicode)
    $commandFile = Join-Path $staging 'compile.cmd'
    $command = @('@echo off', 'setlocal DisableDelayedExpansion')
    if ($developerCommand) {
        $command += @('call "%PBZ_INTEGRITY_VSDEV%" -no_logo -arch=x64 -host_arch=x64', 'if errorlevel 1 exit /b %errorlevel%')
    }
    $command += @('"%PBZ_INTEGRITY_COMPILER%" @"%PBZ_INTEGRITY_RESPONSE%"', 'exit /b %errorlevel%')
    [IO.File]::WriteAllLines($commandFile, $command, [Text.Encoding]::ASCII)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $env:ComSpec
    $start.Arguments = '/d /s /c ""%PBZ_INTEGRITY_COMMAND%""'
    $start.WorkingDirectory = $staging
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['PBZ_INTEGRITY_COMMAND'] = $commandFile
    $start.EnvironmentVariables['PBZ_INTEGRITY_RESPONSE'] = $response
    $start.EnvironmentVariables['PBZ_INTEGRITY_COMPILER'] = if ($CompilerPath) { $CompilerPath } else { 'cl.exe' }
    if ($developerCommand) { $start.EnvironmentVariables['PBZ_INTEGRITY_VSDEV'] = $developerCommand }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start the MSVC build process.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $buildLog = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Script integrity DLL compilation failed (exit $($process.ExitCode)):`n$buildLog" }
        Write-Verbose $buildLog
    } finally {
        $process.Dispose()
    }
    if (-not (Test-Path -LiteralPath $builtDll -PathType Leaf) -or (Get-Item -LiteralPath $builtDll).Length -eq 0) {
        throw 'MSVC reported success without producing a nonempty ScriptIntegrity.dll.'
    }
    # Never publish a partial DLL or destroy a previous good output on compile failure.
    if (Test-Path -LiteralPath $OutputDll -PathType Leaf) { [IO.File]::Replace($builtDll, $OutputDll, $null) }
    else { [IO.File]::Move($builtDll, $OutputDll) }
    Write-Output $OutputDll
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
