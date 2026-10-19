#requires -Version 5.1
<#
Collect a read-only diagnostic report for WSLg UI/RCA container discovery.
Run from Windows PowerShell. Uses the currently selected Podman connection.
#>
[CmdletBinding()]
param(
    [string]$MachineName = 'podman-machine-default',
    [string]$UIContainer = 'UIApp',
    [string[]]$RCAContainers = @('RCA1', 'RCA2'),
    [string]$WindowsAddress = '',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'diagnostics')
)

$ErrorActionPreference = 'Stop'
$script:ReportEncoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$script:ReportPath = Join-Path (Resolve-Path $OutputDirectory).Path ('wslg-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt')
[System.IO.File]::WriteAllText($script:ReportPath, 'Flexiv WSLg network diagnostics' + [Environment]::NewLine, $script:ReportEncoding)

function Save-Section {
    param([string]$Title, [string]$Text)
    # Omit raw container inspection/environment data; also scrub common log secrets.
    $Text = $Text -replace '(?i)(authorization:\s*(?:bearer|basic)\s+)\S+', '$1<REDACTED>'
    $Text = $Text -replace '(?i)((?:password|passwd|token|api[_-]?key|secret)\s*[:=]\s*)[^\s,;]+', '$1<REDACTED>'
    $section = [Environment]::NewLine + '=== ' + $Title + ' ===' + [Environment]::NewLine + $Text + [Environment]::NewLine
    [System.IO.File]::AppendAllText($script:ReportPath, $section, $script:ReportEncoding)
}

function Invoke-PodmanCapture {
    param([string[]]$NativeArguments)
    # Expected failures (ping loss, missing optional tools) must not stop collection.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $lines = @(& $script:PodmanExe @NativeArguments 2>&1)
        $code = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $code
            Text = (($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
        }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Text = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Write-PodmanProbe {
    param([string]$Title, [string[]]$NativeArguments)
    Write-Host ('Collecting: ' + $Title)
    $result = Invoke-PodmanCapture -NativeArguments $NativeArguments
    Save-Section $Title ('Command: podman ' + ($NativeArguments -join ' ') + [Environment]::NewLine + 'Exit code: ' + $result.ExitCode + [Environment]::NewLine + $result.Text)
    return $result
}

function Write-PingProbe {
    param([string]$Title, [string]$SourceContainer, [string]$TargetAddress)
    $result = Write-PodmanProbe $Title @('exec', $SourceContainer, 'ping', '-n', '-c', '2', '-W', '2', $TargetAddress)
    $verdict = 'FAILED (see command output)'
    if ($result.ExitCode -eq 0) {
        $verdict = 'REPLIES'
    } elseif ($result.Text -match '(?i)operation not permitted|permission denied') {
        $verdict = 'PERMISSION DENIED'
    } elseif ($result.Text -match '(?i)100% packet loss|destination .*unreachable') {
        $verdict = 'NO REPLY'
    }
    $script:PingSummary.Add($Title + ': ' + $verdict)
}

Write-Host ('Writing report to ' + $script:ReportPath)
Save-Section 'Scope' ('Time: ' + (Get-Date -Format o) + [Environment]::NewLine + 'Windows address supplied: ' + $WindowsAddress + [Environment]::NewLine + 'Selected machine for host probes: ' + $MachineName + [Environment]::NewLine + 'Container probes use the current Podman connection. No routes, firewall rules, capabilities, or container settings are changed.')

$script:PodmanExe = (Get-Command podman -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$null = Write-PodmanProbe 'Podman client version' @('--version')
$null = Write-PodmanProbe 'Current connections (compare with Podman Desktop)' @('system', 'connection', 'list')
$null = Write-PodmanProbe 'Machine settings' @('machine', 'inspect', '--format', 'Name={{.Name}} State={{.State}} Rootful={{.Rootful}} UserModeNetworking={{.UserModeNetworking}}', $MachineName)
$null = Write-PodmanProbe 'Selected engine rootless status' @('info', '--format', '{{.Host.Security.Rootless}}')
$null = Write-PodmanProbe 'Selected engine network backend' @('info', '--format', '{{.Host.NetworkBackend}}')

try {
    $windowsInfo = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength)
    Save-Section 'Windows IPv4 addresses' ($windowsInfo | ConvertTo-Json -Depth 4)
    Save-Section 'Windows IPv4 routes' (@(Get-NetRoute -AddressFamily IPv4 | Select-Object DestinationPrefix, NextHop, InterfaceIndex, RouteMetric) | ConvertTo-Json -Depth 4)
} catch {
    Save-Section 'Windows network collection error' $_.Exception.Message
}

$containers = @{}
$networkNames = New-Object 'System.Collections.Generic.HashSet[string]'
$networkIds = @{}
$script:PingSummary = New-Object 'System.Collections.Generic.List[string]'
$allNames = @($UIContainer) + $RCAContainers
foreach ($name in $allNames) {
    Write-Host ('Collecting: container ' + $name)
    $result = Invoke-PodmanCapture @('inspect', $name)
    if ($result.ExitCode -ne 0) {
        Save-Section ('Container unavailable: ' + $name) $result.Text
        continue
    }
    try {
        $container = @($result.Text | ConvertFrom-Json)[0]
        $containers[$name] = $container
        $memberships = @()
        foreach ($network in $container.NetworkSettings.Networks.PSObject.Properties) {
            $null = $networkNames.Add($network.Name)
            $identity = $network.Value.NetworkID
            if (-not $identity) { $identity = $network.Name }
            $networkIds[$name + '/' + $network.Name] = $identity
            $memberships += [pscustomobject]@{
                Name = $network.Name
                ID = $identity
                IPAddress = $network.Value.IPAddress
                Gateway = $network.Value.Gateway
                MACAddress = $network.Value.MacAddress
            }
        }
        $selected = [ordered]@{
            Name = $container.Name
            Status = $container.State.Status
            Running = $container.State.Running
            NetworkMode = $container.HostConfig.NetworkMode
            AddedCapabilities = $container.HostConfig.CapAdd
            EffectiveCapabilities = $container.EffectiveCaps
            Networks = $memberships
        }
        Save-Section ('Container state: ' + $name) ($selected | ConvertTo-Json -Depth 8)
    } catch {
        Save-Section ('Cannot parse container inspection: ' + $name) $_.Exception.Message
    }
}

foreach ($networkName in $networkNames) {
    $null = Write-PodmanProbe ('Network configuration: ' + $networkName) @('network', 'inspect', $networkName)
}

$containerProbe = @'
id
grep Cap /proc/self/status
if command -v ip >/dev/null 2>&1; then
    ip -4 address
    ip -4 route
    ip neigh
else
    ifconfig -a
    route -n
    arp -n
fi
cat /proc/net/igmp
netstat -anu
'@
$containerProbe = $containerProbe.Replace([string][char]13, '')
foreach ($name in $allNames) {
    if (-not $containers.ContainsKey($name)) { continue }
    $null = Write-PodmanProbe ('Container interfaces, routes, multicast groups and sockets: ' + $name) @('exec', $name, 'sh', '-c', $containerProbe)
    $null = Write-PodmanProbe ('Container stdout/stderr tail: ' + $name) @('logs', '--tail', '60', $name)
}

if ($containers.ContainsKey($UIContainer)) {
    Write-PingProbe 'UI loopback ping' $UIContainer '127.0.0.1'
    foreach ($name in $RCAContainers) {
        if (-not $containers.ContainsKey($name)) { continue }
        foreach ($network in $containers[$name].NetworkSettings.Networks.PSObject.Properties) {
            $targetIP = $network.Value.IPAddress
            $parsedAddress = $null
            if (-not [System.Net.IPAddress]::TryParse($targetIP, [ref]$parsedAddress)) { continue }
            if ($parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            Write-PingProbe ('UI -> ' + $name + ' at ' + $targetIP) $UIContainer $targetIP
        }
    }
    $null = Write-PodmanProbe 'UI ARP table after ping attempts' @('exec', $UIContainer, 'cat', '/proc/net/arp')
}

foreach ($name in $RCAContainers) {
    if (-not $containers.ContainsKey($name)) { continue }
    $logProbe = 'ls -t /opt/flexiv/RobotControlApp-Sim/log/RobotControlApp_*.log 2>/dev/null | head -n 1 | xargs -r tail -n 100'
    $null = Write-PodmanProbe ('Latest RCA application log tail: ' + $name) @('exec', $name, 'sh', '-c', $logProbe)
}

# Separate SSH commands avoid depending on remote-shell quoting of sh -c payloads.
$null = Write-PodmanProbe 'Machine IPv4 interfaces' @('machine', 'ssh', $MachineName, 'ip', '-4', 'address')
$null = Write-PodmanProbe 'Machine IPv4 routes' @('machine', 'ssh', $MachineName, 'ip', '-4', 'route')
$null = Write-PodmanProbe 'Machine neighbors' @('machine', 'ssh', $MachineName, 'ip', 'neigh')
$null = Write-PodmanProbe 'Machine bridge ports' @('machine', 'ssh', $MachineName, 'bridge', 'link')
$null = Write-PodmanProbe 'Machine IP forwarding' @('machine', 'ssh', $MachineName, 'sysctl', 'net.ipv4.ip_forward')
$null = Write-PodmanProbe 'Machine nftables rules' @('machine', 'ssh', $MachineName, 'sudo', '-n', 'nft', 'list', 'ruleset')
$null = Write-PodmanProbe 'Machine iptables forwarding rules' @('machine', 'ssh', $MachineName, 'sudo', '-n', 'iptables', '-S', 'FORWARD')
Save-Section 'Ping summary (does not test application discovery)' ($script:PingSummary -join [Environment]::NewLine)
Save-Section 'Network membership IDs' ($networkIds | ConvertTo-Json -Depth 4)
Write-Host ''
Write-Host ($script:PingSummary -join [Environment]::NewLine)
Write-Host ('Done. Attach this file to the chat: ' + $script:ReportPath)
