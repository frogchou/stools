param(
    [string]$ApiBaseUrl = "http://jp.frogchou.com:8000/api/v1/ipsearch",
    [int]$TimeoutSeconds = 5,
    [switch]$ShowAll
)

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
if ($PSVersionTable.PSEdition -eq "Desktop") {
    chcp 65001 | Out-Null
}

function Test-ExternalIPv4 {
    param([string]$Ip)

    if (-not ($Ip -match '^\d{1,3}(\.\d{1,3}){3}$')) {
        return $false
    }

    $parts = $Ip.Split('.') | ForEach-Object { [int]$_ }
    if ($parts | Where-Object { $_ -lt 0 -or $_ -gt 255 }) {
        return $false
    }

    if ($Ip -eq "0.0.0.0" -or $Ip -eq "255.255.255.255") { return $false }
    if ($parts[0] -eq 10) { return $false }
    if ($parts[0] -eq 127) { return $false }
    if ($parts[0] -eq 169 -and $parts[1] -eq 254) { return $false }
    if ($parts[0] -eq 172 -and $parts[1] -ge 16 -and $parts[1] -le 31) { return $false }
    if ($parts[0] -eq 192 -and $parts[1] -eq 168) { return $false }
    if ($parts[0] -eq 100 -and $parts[1] -ge 64 -and $parts[1] -le 127) { return $false }
    if ($parts[0] -ge 224) { return $false }

    return $true
}

function Get-IpLocation {
    param([string]$Ip)

    if ($script:LocationCache.ContainsKey($Ip)) {
        return $script:LocationCache[$Ip]
    }

    $url = "$ApiBaseUrl/$Ip"
    try {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.UserAgent = "ip-netstat-windows/1.0"

        $webResponse = $request.GetResponse()
        try {
            $stream = $webResponse.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $rawText = $reader.ReadToEnd()
        } finally {
            if ($reader) { $reader.Close() }
            if ($webResponse) { $webResponse.Close() }
        }

        $response = $rawText | ConvertFrom-Json

        if ($response -is [string]) {
            $location = $response
        } elseif ($response -is [System.Array]) {
            $location = ($response | ForEach-Object {
                if ($_ -is [string]) {
                    $_
                } else {
                    $_ | ConvertTo-Json -Compress -Depth 6
                }
            }) -join " | "
        } elseif ($response.data) {
            if ($response.data -is [System.Array]) {
                $location = ($response.data | ForEach-Object {
                    if ($_ -is [string]) {
                        $_
                    } else {
                        $_ | ConvertTo-Json -Compress -Depth 6
                    }
                }) -join " | "
            } else {
                $location = ($response.data | ConvertTo-Json -Compress -Depth 6)
            }
        } else {
            $location = ($response | ConvertTo-Json -Compress -Depth 6)
        }

        if ([string]::IsNullOrWhiteSpace($location)) {
            $location = "-"
        }
    } catch {
        $message = $_.Exception.Message -replace '\s+', ' '
        $location = "LookupFailed: $message"
    }

    $script:LocationCache[$Ip] = $location
    return $location
}

function Get-ProcessNameSafe {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return "-"
    }

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($process) {
        return $process.ProcessName
    }

    return "-"
}

$script:LocationCache = @{}

$netstatLines = netstat -ano
$allConnections = foreach ($line in $netstatLines) {
    $trimmed = $line.Trim()
    if ($trimmed -notmatch '^TCP\s+') {
        continue
    }

    $columns = $trimmed -split '\s+'
    if ($columns.Count -lt 5) {
        continue
    }

    $foreign = $columns[2]
    if ($foreign -match '^\[.*\]') {
        $remoteAddress = $foreign
        $remotePort = ""
    } elseif ($foreign -match '^(.+):(\d+)$') {
        $remoteAddress = $matches[1]
        $remotePort = $matches[2]
    } else {
        $remoteAddress = $foreign
        $remotePort = ""
    }

    [PSCustomObject]@{
        Proto         = $columns[0]
        LocalAddress  = $columns[1]
        RemoteAddress = $remoteAddress
        RemotePort    = $remotePort
        RemoteFull    = $foreign
        State         = $columns[3]
        OwningProcess = [int]$columns[4]
    }
}

$allConnections = $allConnections |
    Sort-Object RemoteAddress, RemotePort, LocalAddress

if ($ShowAll) {
    $allRows = foreach ($conn in $allConnections) {
        [PSCustomObject]@{
            Proto          = $conn.Proto
            LocalAddress   = $conn.LocalAddress
            ForeignAddress = $conn.RemoteFull
            State          = $conn.State
            PID            = $conn.OwningProcess
            Process        = Get-ProcessNameSafe -ProcessId $conn.OwningProcess
            ExternalIPv4   = Test-ExternalIPv4 $conn.RemoteAddress
        }
    }

    $allRows | Format-Table -AutoSize
    exit 0
}

$connections = $allConnections |
    Where-Object { $_.State -eq "ESTABLISHED" -and (Test-ExternalIPv4 $_.RemoteAddress) }

$rows = foreach ($conn in $connections) {
    [PSCustomObject]@{
        Proto          = $conn.Proto
        LocalAddress   = $conn.LocalAddress
        ForeignAddress = $conn.RemoteFull
        State          = $conn.State
        PID            = $conn.OwningProcess
        Process        = Get-ProcessNameSafe -ProcessId $conn.OwningProcess
        Location       = Get-IpLocation $conn.RemoteAddress
    }
}

if (-not $rows) {
    Write-Host "No established external IPv4 TCP connections found."
    Write-Host "Tip: open a website or keep an app connected, then run again."
    Write-Host "Debug: run .\list_ip_connections_windows.ps1 -ShowAll to view all TCP connections."
    exit 0
}

$rows | Format-Table -AutoSize
