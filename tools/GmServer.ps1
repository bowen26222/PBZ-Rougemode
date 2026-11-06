[CmdletBinding()]
param(
    [string]$GameRoot,
    [int]$Port = 8765,
    [switch]$Open
)

# Local-only control panel for Endless Trials. No external runtime is required:
# the bridge is a pair of JSON files in the active isolated profile, and this
# script serves the page plus a small JSON API over loopback.
$ErrorActionPreference = 'Stop'
$script:serverVersion = 1
$script:bodyLimit = 256KB

function Find-GameRoot {
    param([string]$Requested)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Requested) { $candidates.Add($Requested) }
    if ($env:PBZ_GAME_ROOT) { $candidates.Add($env:PBZ_GAME_ROOT) }
    $candidates.Add((Join-Path $PSScriptRoot '..\..\..\..\..'))
    $steamPath = $null
    try { $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath } catch { }
    if ($steamPath) {
        $candidates.Add((Join-Path $steamPath 'steamapps\common\PBZ'))
        $libraryFile = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile) {
            foreach ($match in [regex]::Matches((Get-Content -LiteralPath $libraryFile -Raw), '"path"\s+"([^"]+)"')) {
                $candidates.Add((Join-Path ($match.Groups[1].Value -replace '\\\\', '\') 'steamapps\common\PBZ'))
            }
        }
    }
    $candidates.Add('D:\Steam\steamapps\common\PBZ')
    $candidates.Add('C:\Program Files (x86)\Steam\steamapps\common\PBZ')
    $candidates.Add('E:\SteamLibrary\steamapps\common\PBZ')
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        try { $full = [IO.Path]::GetFullPath($candidate) } catch { continue }
        if (Test-Path -LiteralPath (Join-Path $full 'platform\steam\ue4ss\Mods\PBZRogue\config\enemy_pools.json')) {
            return $full
        }
    }
    return $null
}

$gameRoot = Find-GameRoot -Requested $GameRoot
if (-not $gameRoot) {
    throw '找不到影之刃零安装目录。请从游戏根目录运行，或传入 -GameRoot "D:\Steam\steamapps\common\PBZ"。'
}
$modRoot = Join-Path $gameRoot 'platform\steam\ue4ss\Mods\PBZRogue'
$runsRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PBZRogue\Runs'
$logPath = Join-Path $gameRoot 'platform\steam\ue4ss\UE4SS.log'
$htmlPath = Join-Path $PSScriptRoot 'gm.html'
if (-not (Test-Path -LiteralPath $htmlPath)) {
    $installedHtml = Join-Path $modRoot 'ui\gm.html'
    if (Test-Path -LiteralPath $installedHtml) { $htmlPath = $installedHtml }
}
if (-not (Test-Path -LiteralPath $htmlPath)) { throw "GM 页面缺失：$htmlPath" }

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Write-JsonAtomic {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Depth 24 -Compress
    $temporary = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary, $json, ([Text.UTF8Encoding]::new($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
    [IO.File]::Move($temporary, $Path)
}

function Get-Profiles {
    if (-not (Test-Path -LiteralPath $runsRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $runsRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-f]{32}$' } |
        Sort-Object -Property LastWriteTimeUtc -Descending)
}

function Get-ActiveProfile {
    $profiles = @(Get-Profiles)
    if ($profiles.Count -eq 0) { return $null }
    $scored = foreach ($profile in $profiles) {
        $stamp = $profile.LastWriteTimeUtc
        $stateFile = Join-Path $profile.FullName 'run-state.json'
        if (Test-Path -LiteralPath $stateFile) {
            $stateStamp = (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc
            if ($stateStamp -gt $stamp) { $stamp = $stateStamp }
        }
        $statusFile = Join-Path $profile.FullName 'gm\status.json'
        if (Test-Path -LiteralPath $statusFile) {
            $statusStamp = (Get-Item -LiteralPath $statusFile).LastWriteTimeUtc
            if ($statusStamp -gt $stamp) { $stamp = $statusStamp }
        }
        [PSCustomObject]@{ Profile = $profile; Stamp = $stamp }
    }
    return ($scored | Sort-Object -Property Stamp -Descending | Select-Object -First 1).Profile
}

function Get-GameRunning {
    return @(Get-Process -Name PBZ -ErrorAction SilentlyContinue).Count -gt 0
}

function Get-GmLog {
    param([int]$Lines = 40)
    if (-not (Test-Path -LiteralPath $logPath)) { return '' }
    try {
        $tail = Get-Content -LiteralPath $logPath -Tail 800 -Encoding UTF8 -ErrorAction SilentlyContinue
        $selected = @($tail | Where-Object { $_ -match '\[PBZRogue\]' } | Select-Object -Last $Lines)
        # The log is external text: strip control bytes before handing it to the
        # browser, and never feed it through ConvertTo-Json (5.1 can stall on
        # malformed sequences from native stdout).
        return (($selected | ForEach-Object { $_ -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '' }) -join "`n")
    } catch { return '' }
}

function Get-Catalog {
    $pools = Read-JsonFile -Path (Join-Path $modRoot 'config\enemy_pools.json')
    $shop = Read-JsonFile -Path (Join-Path $modRoot 'config\shop.json')
    $mobs = @()
    $bosses = @()
    foreach ($enemy in @($pools.mobs)) {
        $mobs += [ordered]@{
            id = $enemy.id; name = $enemy.name; tier = $enemy.tier; firstFloor = $enemy.firstFloor
            reward = $enemy.reward; enabled = ($enemy.enabled -ne $false); reason = $enemy.unavailableReason
        }
    }
    foreach ($enemy in @($pools.bosses)) {
        $bosses += [ordered]@{
            id = $enemy.id; name = $enemy.name; tier = $enemy.tier; firstFloor = $enemy.firstFloor
            reward = $enemy.reward; enabled = ($enemy.enabled -ne $false); reason = $enemy.unavailableReason
        }
    }
    return [ordered]@{
        mobs = $mobs
        bosses = $bosses
        shop = $shop
        limits = [ordered]@{ wave = 12; boss = 3; count = 8; floor = 999 }
        gameRoot = $gameRoot
    }
}

function Get-StatePayload {
    $profile = Get-ActiveProfile
    $payload = [ordered]@{
        server = [ordered]@{ version = $script:serverVersion; port = $Port; gameRoot = $gameRoot }
        game = [ordered]@{ running = (Get-GameRunning) }
        profile = $null
    }
    if ($profile) {
        [void][IO.Directory]::CreateDirectory((Join-Path $profile.FullName 'gm'))
        $profileState = [ordered]@{
            path = $profile.FullName
            name = $profile.Name
            run = Read-JsonFile -Path (Join-Path $profile.FullName 'run-state.json')
            gm = Read-JsonFile -Path (Join-Path $profile.FullName 'gm\status.json')
            command = Read-JsonFile -Path (Join-Path $profile.FullName 'gm\command.json')
        }
        $payload.profile = $profileState
    }
    return $payload
}

function Send-Response {
    param($Stream, [int]$Status, [string]$ContentType, [byte[]]$Body)
    $reasons = @{ 200 = 'OK'; 400 = 'Bad Request'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 409 = 'Conflict'; 500 = 'Internal Server Error' }
    $reason = $reasons[$Status]
    if (-not $reason) { $reason = 'Error' }
    $header = "HTTP/1.1 $Status $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Json {
    param($Stream, [int]$Status, $Value)
    $json = if ($Value -is [string]) { $Value } else { $Value | ConvertTo-Json -Depth 24 -Compress }
    Send-Response -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

function Send-Error {
    param($Stream, [int]$Status, [string]$Message)
    Send-Json -Stream $Stream -Status $Status -Value ([ordered]@{ ok = $false; error = $Message })
}

function Send-GmCommand {
    param($Stream, [System.Collections.IDictionary]$Fields)
    if (-not (Get-GameRunning)) {
        Send-Error $Stream 409 '游戏未运行。请先点击“启动游戏”，或从游戏菜单进入无尽修炼。'
        return
    }
    $profile = Get-ActiveProfile
    if (-not $profile) {
        Send-Error $Stream 409 '尚未找到独立存档。请先从游戏菜单进入无尽修炼。'
        return
    }
    if ($Fields.Contains('controls')) {
        $status = Read-JsonFile -Path (Join-Path $profile.FullName 'gm\status.json')
        foreach ($key in @('health', 'shachi')) {
            if (-not $Fields.controls.Contains($key)) { continue }
            $maximum = if ($key -eq 'health') { $status.maxHealth } else { $status.shachiMax }
            $minimum = if ($key -eq 'health') { 1 } else { 0 }
            if ($null -eq $maximum -or
                ($maximum -isnot [int] -and $maximum -isnot [long] -and $maximum -isnot [double] -and $maximum -isnot [decimal]) -or
                [double]::IsNaN([double]$maximum) -or [double]::IsInfinity([double]$maximum) -or [double]$maximum -lt $minimum) {
                Send-Error $Stream 409 "$key 尚无有效上限，请等待游戏状态更新。"
                return
            }
            if ($Fields.controls[$key] -gt [double]$maximum) {
                Send-Error $Stream 400 "$key 不能超过当前有效上限 $maximum"
                return
            }
        }
    }
    if ($Fields.Contains('equipment')) {
        $status = Read-JsonFile -Path (Join-Path $profile.FullName 'gm\status.json')
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (-not (Test-JsonInteger $status.updated) -or $now - $status.updated -gt 10 -or
            $status.updated - $now -gt 2 -or $status.equipment.canReplace -isnot [bool] -or
            $status.equipment.canReplace -ne $true) {
            Send-Error $Stream 409 '装备状态未就绪或已过期，请等待游戏内可替换装备时的最新状态。'; return
        }
        $request = $Fields.equipment
        $items = @($status.equipment.catalog.($request.kind) | Where-Object { $_.id -ceq $request.item })
        $slots = @($status.equipment.slots | Where-Object { $_.kind -ceq $request.kind -and $_.slot -eq $request.slot })
        if ($items.Count -ne 1 -or $slots.Count -ne 1) {
            Send-Error $Stream 400 '物品或目标槽位不在当前游戏装备目录中，请刷新状态。'; return
        }
        $item = $items[0]
        if (-not (Test-JsonInteger $item.minLevel) -or -not (Test-JsonInteger $item.maxLevel) -or
            $item.minLevel -gt $item.maxLevel -or $item.soulSupported -isnot [bool]) {
            Send-Error $Stream 409 '当前装备目录不完整，请等待游戏状态更新。'; return
        }
        if ($request.level -lt $item.minLevel -or $request.level -gt $item.maxLevel) {
            Send-Error $Stream 400 "该物品原生等级范围为 $($item.minLevel)–$($item.maxLevel)。"; return
        }
        if ($request.soul -and -not $item.soulSupported) {
            Send-Error $Stream 400 '该物品不支持铸魂。'; return
        }
        $duplicate = @($status.equipment.slots | Where-Object {
            $_.kind -ceq $request.kind -and $_.slot -ne $request.slot -and $_.id -ceq $request.item
        })
        if ($duplicate.Count -gt 0) {
            Send-Error $Stream 400 '该物品已装备在其他同类槽位，不能复制或自动移动。'; return
        }
    }
    $gmDir = Join-Path $profile.FullName 'gm'
    [void][IO.Directory]::CreateDirectory($gmDir)
    $previous = 0
    $oldCommand = Read-JsonFile -Path (Join-Path $gmDir 'command.json')
    $oldStatus = Read-JsonFile -Path (Join-Path $gmDir 'status.json')
    foreach ($value in @($oldCommand.seq, $oldStatus.appliedSeq)) {
        if ($value -is [int] -or $value -is [long] -or $value -is [double]) {
            if ([double]$value -gt $previous) { $previous = [double]$value }
        }
    }
    $seq = [long]([math]::Floor($previous) + 1)
    $command = [ordered]@{
        schema = 1
        seq = $seq
        queued = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    foreach ($key in $Fields.Keys) { $command[$key] = $Fields[$key] }
    Write-JsonAtomic -Path (Join-Path $gmDir 'command.json') -Value $command
    Send-Json -Stream $Stream -Status 200 -Value ([ordered]@{ ok = $true; seq = $seq; profile = $profile.Name })
}

function Invoke-Apply {
    param($Stream, [string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { Send-Error $Stream 400 '缺少请求内容'; return }
    try { $payload = $Body | ConvertFrom-Json } catch { Send-Error $Stream 400 '请求不是有效的 JSON'; return }
    if ($null -eq $payload -or $null -eq $payload.scenario) { Send-Error $Stream 400 '缺少 scenario 字段'; return }
    Send-GmCommand -Stream $Stream -Fields ([ordered]@{ scenario = $payload.scenario })
}

function Invoke-Controls {
    param($Stream, [string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { Send-Error $Stream 400 '缺少请求内容'; return }
    try { $payload = $Body | ConvertFrom-Json } catch { Send-Error $Stream 400 '请求不是有效的 JSON'; return }
    if ($payload -isnot [PSCustomObject] -or $payload.controls -isnot [PSCustomObject]) {
        Send-Error $Stream 400 'controls 必须是非空对象'; return
    }
    $controls = [ordered]@{}
    foreach ($property in $payload.controls.PSObject.Properties) {
        $key, $value = $property.Name, $property.Value
        if (@('health', 'maxHealth', 'attack', 'lockHealth', 'shachi') -cnotcontains $key) {
            Send-Error $Stream 400 "未知角色控制字段：$key"; return
        }
        if ($key -ceq 'lockHealth') {
            if ($value -isnot [bool]) { Send-Error $Stream 400 "$key 必须是布尔值"; return }
        } else {
            $minimum = if ($key -ceq 'shachi') { 0 } else { 1 }
            if (($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) -or
                [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or [double]$value -lt $minimum) {
                Send-Error $Stream 400 "$key 必须是不小于 $minimum 的有限数值"; return
            }
            if ([double]$value -gt 1000000) {
                Send-Error $Stream 400 "$key 不能超过 1000000"; return
            }
        }
        $controls[$key] = $value
    }
    if ($controls.Count -eq 0) { Send-Error $Stream 400 'controls 必须是非空对象'; return }
    if ($controls.Contains('health') -and $controls.Contains('maxHealth')) {
        Send-Error $Stream 400 '当前生命和基础生命上限请分别应用，等待有效上限更新后再修改当前生命。'; return
    }
    Send-GmCommand -Stream $Stream -Fields ([ordered]@{ action = 'controls'; controls = $controls })
}

function Test-JsonInteger {
    param($Value)
    return (($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) -and
        -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value) -and
        [math]::Abs([double]$Value) -le 9007199254740991 -and [math]::Floor([double]$Value) -eq [double]$Value)
}

function Invoke-Equipment {
    param($Stream, [string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { Send-Error $Stream 400 '缺少请求内容'; return }
    if (-not $Body.TrimStart().StartsWith('{')) { Send-Error $Stream 400 '请求必须是 JSON 对象'; return }
    try { $payload = $Body | ConvertFrom-Json } catch { Send-Error $Stream 400 '请求不是有效的 JSON'; return }
    if ($payload -isnot [PSCustomObject] -or @($payload.PSObject.Properties).Count -ne 1 -or
        @($payload.PSObject.Properties.Name) -cnotcontains 'equipment' -or $payload.equipment -isnot [PSCustomObject]) {
        Send-Error $Stream 400 '请求必须仅包含 equipment 对象'; return
    }
    $equipment = [ordered]@{}
    $keys = @('kind', 'item', 'slot', 'level', 'soul')
    foreach ($property in $payload.equipment.PSObject.Properties) {
        if ($keys -cnotcontains $property.Name) {
            Send-Error $Stream 400 "未知装备字段：$($property.Name)"; return
        }
        $equipment[$property.Name] = $property.Value
    }
    if ($equipment.Count -ne $keys.Count) { Send-Error $Stream 400 '装备请求必须包含 kind、item、slot、level、soul'; return }
    if ($equipment.kind -isnot [string] -or @('weapons', 'shadow', 'accessory', 'medicine') -cnotcontains $equipment.kind) {
        Send-Error $Stream 400 '未知装备种类'; return
    }
    if ($equipment.item -isnot [string] -or [string]::IsNullOrWhiteSpace($equipment.item)) {
        Send-Error $Stream 400 'item 必须是目录中的非空物品 ID'; return
    }
    if (-not (Test-JsonInteger $equipment.slot) -or $equipment.slot -lt 1 -or
        -not (Test-JsonInteger $equipment.level)) {
        Send-Error $Stream 400 'slot 必须是从 1 开始的有限整数；level 必须是有限整数'; return
    }
    if ($equipment.soul -isnot [bool]) { Send-Error $Stream 400 'soul 必须是布尔值'; return }
    if ($equipment.soul -and @('accessory', 'medicine') -ccontains $equipment.kind) {
        Send-Error $Stream 400 '饰品和药品不支持铸魂，soul 必须为 false'; return
    }
    Send-GmCommand -Stream $Stream -Fields ([ordered]@{ action = 'equipment'; equipment = $equipment })
}

function Invoke-Launch {
    param($Stream)
    if (Get-GameRunning) { Send-Error $Stream 409 '游戏已在运行，请直接在游戏内使用 GM。'; return }
    $launcher = Join-Path $modRoot 'StartIsolatedGame.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) { Send-Error $Stream 500 '独立启动脚本缺失，请重新安装模组。'; return }
    $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -GameRoot "{1}" -Language zh' -f $launcher, $gameRoot
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory $gameRoot | Out-Null
    Send-Json -Stream $Stream -Status 200 -Value ([ordered]@{ ok = $true; starting = $true })
}

function Read-RequestBody {
    param($Reader, [int]$Length)
    if ($Length -le 0) { return '' }
    if ($Length -gt $script:bodyLimit) { throw '请求体过大' }
    $buffer = New-Object char[] $Length
    $offset = 0
    while ($offset -lt $Length) {
        $read = $Reader.Read($buffer, $offset, $Length - $offset)
        if ($read -le 0) { break }
        $offset += $read
    }
    if ($offset -le 0) { return '' }
    return (-join $buffer[0..($offset - 1)])
}

function Invoke-Request {
    param($Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 8000
    $reader = New-Object IO.StreamReader($stream, ([Text.UTF8Encoding]::new($false)), $false, 8192, $true)
    $requestLine = $reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($requestLine)) { return }
    $parts = $requestLine.Split(' ')
    if ($parts.Length -lt 2) { Send-Error $stream 400 '无效请求'; return }
    $method, $target = $parts[0].ToUpperInvariant(), $parts[1]
    $contentLength = 0
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line -or $line -eq '') { break }
        if ($line -match '^(?i)Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
    }
    $path = $target.Split('?')[0]
    Write-Host ("{0} {1}" -f $method, $path)

    try {
        switch ($path) {
            '/' {
                $html = Get-Content -LiteralPath $htmlPath -Raw -Encoding UTF8
                Send-Response -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($html))
                return
            }
            '/api/state' {
                if ($method -ne 'GET') { Send-Error $stream 405 '仅支持 GET'; return }
                Send-Json -Stream $stream -Status 200 -Value (Get-StatePayload)
                Write-Host 'state sent'
                return
            }
            '/api/log' {
                if ($method -ne 'GET') { Send-Error $stream 405 '仅支持 GET'; return }
                $text = Get-GmLog -Lines 40
                Send-Response -Stream $stream -Status 200 -ContentType 'text/plain; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($text))
                return
            }
            '/api/catalog' {
                if ($method -ne 'GET') { Send-Error $stream 405 '仅支持 GET'; return }
                Send-Json -Stream $stream -Status 200 -Value (Get-Catalog)
                return
            }
            '/api/apply' {
                if ($method -ne 'POST') { Send-Error $stream 405 '仅支持 POST'; return }
                $body = Read-RequestBody -Reader $reader -Length $contentLength
                Invoke-Apply -Stream $stream -Body $body
                return
            }
            '/api/controls' {
                if ($method -ne 'POST') { Send-Error $stream 405 '仅支持 POST'; return }
                $body = Read-RequestBody -Reader $reader -Length $contentLength
                Invoke-Controls -Stream $stream -Body $body
                return
            }
            '/api/equipment' {
                if ($method -ne 'POST') { Send-Error $stream 405 '仅支持 POST'; return }
                $body = Read-RequestBody -Reader $reader -Length $contentLength
                Invoke-Equipment -Stream $stream -Body $body
                return
            }
            '/api/launch' {
                if ($method -ne 'POST') { Send-Error $stream 405 '仅支持 POST'; return }
                Invoke-Launch -Stream $stream
                return
            }
            default {
                Send-Error $stream 404 '未知接口'
                return
            }
        }
    } catch {
        Write-Host ('请求处理失败：' + $_.Exception.Message)
        try { Send-Error $stream 500 ('请求处理失败：' + $_.Exception.Message) } catch { }
    }
}

$listener = $null
try {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
} catch {
    throw "无法监听 127.0.0.1:$Port，端口可能被占用：$($_.Exception.Message)"
}

Write-Host ''
Write-Host '无尽修炼 · GM 控制台'
Write-Host "  地址：http://127.0.0.1:$Port/"
Write-Host "  游戏：$gameRoot"
Write-Host '  按 Ctrl+C 停止。'
Write-Host ''
if ($Open) { Start-Process "http://127.0.0.1:$Port/" | Out-Null }

try {
    while ($true) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 15; continue }
        $client = $listener.AcceptTcpClient()
        try { Invoke-Request -Client $client } catch { Write-Host ('请求失败：' + $_.Exception.Message) } finally { $client.Close() }
    }
} finally {
    $listener.Stop()
}
