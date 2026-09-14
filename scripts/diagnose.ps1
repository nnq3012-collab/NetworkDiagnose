<#
.SYNOPSIS
  Full network troubleshooting sweep: local link, captive portal, DNS, routing,
  jitter, IPv6 health, MTU, and single-vs-multi-connection throughput (detects
  per-flow ISP throttling). Ends with a plain-language summary and a diff
  against your last run.
.USAGE
  powershell -ExecutionPolicy Bypass -File diagnose.ps1
  Optional: -TargetHost "8.8.8.8" -ThroughputUrl "https://proof.ovh.net/files/10Mb.dat"
            -WifiAdapterName "Wi-Fi" -DnsTestHost "google.com"
            -CheckMtu      (adds path-MTU discovery; slower, off by default)
            -CheckAsn      (tags traceroute hops with ISP/ASN via ip-api.com; needs internet, off by default)
#>
param(
    [string]$TargetHost = "8.8.8.8",
    [string]$ThroughputUrl = "https://proof.ovh.net/files/10Mb.dat",
    [string]$WifiAdapterName = "Wi-Fi",
    [string]$DnsTestHost = "google.com",
    [switch]$CheckMtu,
    [switch]$CheckAsn
)

$ErrorActionPreference = "SilentlyContinue"
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$reportDir = Join-Path $PSScriptRoot "..\reports"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir | Out-Null }
$baselinePath = Join-Path $reportDir "baseline.json"
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$reportPath = Join-Path $reportDir "diagnostic_$stamp.txt"
$findings = @()   # collected plain-language findings, filled in as each section runs
$metrics  = @{}   # numeric metrics saved to baseline.json for run-over-run comparison

function Section($title) {
    "`n===== $title =====" | Tee-Object -FilePath $reportPath -Append
}

function Get-Jitter($values) {
    if (-not $values -or $values.Count -lt 2) { return 0 }
    $avg = ($values | Measure-Object -Average).Average
    $variance = ($values | ForEach-Object { [math]::Pow($_ - $avg, 2) } | Measure-Object -Average).Average
    [math]::Round([math]::Sqrt($variance), 1)
}

"NETWORK DIAGNOSTIC REPORT - $(Get-Date)" | Tee-Object -FilePath $reportPath

Section "1. Default Gateway"
$gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" | Sort-Object RouteMetric | Select-Object -First 1).NextHop
"Gateway: $gw" | Tee-Object -FilePath $reportPath -Append
$gwPing = Test-Connection -ComputerName $gw -Count 10
$gwTimes = $gwPing.ResponseTime
$gwStats = $gwPing | Measure-Object -Property ResponseTime -Average -Maximum -Minimum
$gwJitter = Get-Jitter $gwTimes
"Average: $([math]::Round($gwStats.Average,1)) ms   Maximum: $($gwStats.Maximum) ms   Minimum: $($gwStats.Minimum) ms   Jitter (stdev): $gwJitter ms" |
    Tee-Object -FilePath $reportPath -Append
$gwLoss = 10 - $gwPing.Count
"Packet loss: $gwLoss/10" | Tee-Object -FilePath $reportPath -Append
$metrics.GatewayAvgMs = [math]::Round($gwStats.Average, 1)
$metrics.GatewayLoss  = $gwLoss
if ($gwLoss -gt 0) {
    $findings += "PROBLEM: Local Wi-Fi/LAN is dropping packets ($gwLoss/10 lost to your router). This points to a local Wi-Fi issue (interference, distance, driver), not your ISP."
} elseif ($gwStats.Average -gt 10) {
    $findings += "MINOR: Ping to your router is higher than expected ($([math]::Round($gwStats.Average,1)) ms avg). A healthy local network is usually under ~5 ms."
} else {
    $findings += "OK: Local Wi-Fi/LAN to your router is healthy (0 loss, $([math]::Round($gwStats.Average,1)) ms avg)."
}

Section "2. Captive Portal / Internet Access Check"
$captiveUrl = "http://www.msftconnecttest.com/connecttest.txt"
$captiveExpected = "Microsoft Connect Test"
try {
    $captiveResp = Invoke-WebRequest -Uri $captiveUrl -UseBasicParsing -TimeoutSec 8 -MaximumRedirection 0 -ErrorAction Stop
    $statusCode = [int]$captiveResp.StatusCode
    $bodyOk = $captiveResp.Content.Trim() -eq $captiveExpected
} catch {
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    } else {
        $statusCode = 0
    }
    $bodyOk = $false
}
"GET $captiveUrl -> HTTP $statusCode" | Tee-Object -FilePath $reportPath -Append
if ($statusCode -eq 200 -and $bodyOk) {
    "Result: Open internet access, no captive portal." | Tee-Object -FilePath $reportPath -Append
    $findings += "OK: internet access is open (no captive portal / login page in the way)."
} elseif ($statusCode -ge 300 -and $statusCode -lt 400) {
    "Result: Redirected - a login page is intercepting traffic." | Tee-Object -FilePath $reportPath -Append
    $findings += "PROBLEM: a captive portal is intercepting traffic (got redirected). Open a browser and log in via the portal page (common on hotel/cafe/office Wi-Fi) before troubleshooting anything else."
} elseif ($statusCode -eq 0) {
    "Result: No response - possible total outage or DNS/firewall block." | Tee-Object -FilePath $reportPath -Append
    $findings += "PROBLEM: no response at all from the captive-portal check. This suggests DNS, firewall, or a total connectivity outage rather than a slowdown."
} else {
    "Result: Unexpected response ($statusCode) - internet reachable but this specific check is inconclusive." | Tee-Object -FilePath $reportPath -Append
    $findings += "MINOR: captive-portal check returned an unexpected status ($statusCode). Not necessarily a problem, but not a clean pass either."
}

Section "3. Wi-Fi Signal & Channel"
$wlanRaw = netsh wlan show interfaces
$wlanRaw | Select-String "SSID|Signal|Channel|Radio type|Rssi|rate" |
    Tee-Object -FilePath $reportPath -Append
$signalLine = $wlanRaw | Select-String "^\s*Signal\s*:\s*(\d+)%"
$radioLine  = $wlanRaw | Select-String "^\s*Radio type\s*:\s*(.+)$"
$rssiLine   = $wlanRaw | Select-String "^\s*Rssi\s*:\s*(-?\d+)"
$radioCaps = @{
    "802.11n"  = @{ Name = "Wi-Fi 4"; RealWorldMbps = 150 }
    "802.11ac" = @{ Name = "Wi-Fi 5"; RealWorldMbps = 400 }
    "802.11ax" = @{ Name = "Wi-Fi 6"; RealWorldMbps = 600 }
    "802.11a"  = @{ Name = "Wi-Fi 2"; RealWorldMbps = 25 }
    "802.11g"  = @{ Name = "Wi-Fi 3"; RealWorldMbps = 25 }
    "802.11b"  = @{ Name = "Wi-Fi 1"; RealWorldMbps = 5 }
}
if ($radioLine) {
    $radioType = $radioLine.Matches[0].Groups[1].Value.Trim()
    if ($radioCaps.ContainsKey($radioType)) {
        $cap = $radioCaps[$radioType]
        $findings += "NOTE: connected via $radioType ($($cap.Name)). Real-world throughput over this radio typically tops out around ~$($cap.RealWorldMbps) Mbps, regardless of your ISP plan speed."
    }
}
if ($signalLine) {
    $signalPct = [int]($signalLine.Matches[0].Groups[1].Value)
    $metrics.WifiSignalPct = $signalPct
    if ($signalPct -lt 50) {
        $findings += "PROBLEM: Wi-Fi signal is weak ($signalPct%). Move closer to the router or use 5GHz/a wired connection."
    } else {
        $findings += "OK: Wi-Fi signal is strong ($signalPct%)."
    }
}
if ($rssiLine) {
    $rssi = [int]($rssiLine.Matches[0].Groups[1].Value)
    $metrics.WifiRssi = $rssi
    if ($rssi -lt -70) {
        $findings += "PROBLEM: RSSI is $rssi dBm, which is a weak/unreliable signal (below -70 dBm). Expect drops and slow speeds; move closer to the AP."
    }
}

Section "4. DNS Resolution"
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -eq $WifiAdapterName } |
    Format-Table InterfaceAlias, ServerAddresses | Out-String | Tee-Object -FilePath $reportPath -Append
Clear-DnsClientCache
$dnsUncached = Measure-Command { Resolve-DnsName $DnsTestHost -ErrorAction SilentlyContinue | Out-Null }
$dnsCached   = Measure-Command { Resolve-DnsName $DnsTestHost -ErrorAction SilentlyContinue | Out-Null }
$uncachedMs = [math]::Round($dnsUncached.TotalMilliseconds, 1)
$cachedMs   = [math]::Round($dnsCached.TotalMilliseconds, 1)
"Uncached lookup for $DnsTestHost (hits upstream resolver): $uncachedMs ms" | Tee-Object -FilePath $reportPath -Append
"Cached lookup for $DnsTestHost (hits local cache): $cachedMs ms" | Tee-Object -FilePath $reportPath -Append
$metrics.DnsUncachedMs = $uncachedMs
if ($uncachedMs -gt 100) {
    $findings += "MINOR: DNS lookups are slow ($uncachedMs ms uncached). This is a noticeable browsing bottleneck (every new domain pays this cost). Switching to Cloudflare (1.1.1.1) or Google (8.8.8.8) DNS can help."
} else {
    $findings += "OK: DNS resolution is fast ($uncachedMs ms uncached, $cachedMs ms cached)."
}

Section "5. Latency, Jitter & Loss to Internet Target ($TargetHost)"
$extPing = Test-Connection -ComputerName $TargetHost -Count 15
$extTimes = $extPing.ResponseTime
$extStats = $extPing | Measure-Object -Property ResponseTime -Average -Maximum -Minimum
$extJitter = Get-Jitter $extTimes
"Average: $([math]::Round($extStats.Average,1)) ms   Maximum: $($extStats.Maximum) ms   Minimum: $($extStats.Minimum) ms   Jitter (stdev): $extJitter ms" |
    Tee-Object -FilePath $reportPath -Append
$extLoss = 15 - $extPing.Count
"Packet loss: $extLoss/15" | Tee-Object -FilePath $reportPath -Append
$metrics.ExtAvgMs = [math]::Round($extStats.Average, 1)
$metrics.ExtLoss  = $extLoss
$metrics.ExtJitterMs = $extJitter
if ($extLoss -gt 0) {
    $findings += "PROBLEM: Losing packets to the internet ($extLoss/15) even though the local network is fine. This points to your ISP or a hop along the route, not your Wi-Fi."
} elseif ($extStats.Average -gt 60) {
    $findings += "MINOR: Internet latency is high ($([math]::Round($extStats.Average,1)) ms avg). Fine for browsing, may cause lag in real-time apps (calls, gaming)."
} else {
    $findings += "OK: Internet latency and loss to $TargetHost are healthy ($([math]::Round($extStats.Average,1)) ms avg, 0 loss)."
}
if ($extJitter -gt 20) {
    $findings += "PROBLEM: Jitter is high ($extJitter ms stdev). Even though average ping may look fine, expect stutter/choppy audio in VoIP calls (Zoom, Teams) and gaming."
} else {
    $findings += "OK: Jitter is low ($extJitter ms stdev) - stable enough for calls and gaming."
}

Section "6. Traceroute (find bad hops)"
$traceOut = tracert -d -h 15 $TargetHost
$traceOut | Tee-Object -FilePath $reportPath -Append
if ($CheckAsn) {
    $hopIps = @()
    foreach ($line in $traceOut) {
        if ($line -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s*$') {
            $ip = $Matches[1]
            if ($ip -notmatch '^(10\.|127\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|169\.254\.)' -and $hopIps -notcontains $ip) {
                $hopIps += $ip
            }
        }
    }
    if ($hopIps.Count -gt 0) {
        try {
            $body = ($hopIps | ForEach-Object { @{ query = $_; fields = "query,isp,as" } }) | ConvertTo-Json
            $asnResults = Invoke-RestMethod -Uri "http://ip-api.com/batch" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 8 -ErrorAction Stop
            "--- ASN / ISP tags for public hops ---" | Tee-Object -FilePath $reportPath -Append
            foreach ($r in $asnResults) {
                "$($r.query)  ->  $($r.as) - $($r.isp)" | Tee-Object -FilePath $reportPath -Append
            }
        } catch {
            "(ASN lookup unavailable - ip-api.com unreachable or rate-limited)" | Tee-Object -FilePath $reportPath -Append
        }
    }
} else {
    "(Run with -CheckAsn to tag each public hop with its ISP/ASN, e.g. 'AS45899 - VNPT')" | Tee-Object -FilePath $reportPath -Append
}

Section "7. IPv6 vs IPv4 Throughput/Handshake (detects PMTU black holes)"
"--- IPv4 ---" | Tee-Object -FilePath $reportPath -Append
$v4out = curl.exe -4 -o NUL -s -w "Connect:%{time_connect}s TLS:%{time_appconnect}s TTFB:%{time_starttransfer}s Total:%{time_total}s Speed:%{speed_download} B/s" "https://www.google.com" --max-time 15
$v4out | Tee-Object -FilePath $reportPath -Append
"--- IPv6 ---" | Tee-Object -FilePath $reportPath -Append
$v6out = curl.exe -6 -o NUL -s -w "Connect:%{time_connect}s TLS:%{time_appconnect}s TTFB:%{time_starttransfer}s Total:%{time_total}s Speed:%{speed_download} B/s" "https://www.google.com" --max-time 15
$v6out | Tee-Object -FilePath $reportPath -Append
"(Disable IPv6 on the adapter if flagged below: Disable-NetAdapterBinding -Name '$WifiAdapterName' -ComponentID ms_tcpip6)" |
    Tee-Object -FilePath $reportPath -Append
$v4total = 0; $v6total = 0; $v6speed = 0
if ($v4out -match "Total:([\d.]+)s") { $v4total = [double]$Matches[1] }
if ($v6out -match "Total:([\d.]+)s") { $v6total = [double]$Matches[1] }
if ($v6out -match "Speed:([\d.]+) B/s") { $v6speed = [double]$Matches[1] }
if ($v6speed -eq 0 -or $v6total -eq 0) {
    "IPv6 state: Unavailable" | Tee-Object -FilePath $reportPath -Append
    $findings += "NOTE: IPv6 is unavailable on this connection (no response). Not a problem by itself since IPv4 still works, but rules out IPv6-specific fixes."
} elseif ($v6total -gt ($v4total * 2)) {
    "IPv6 state: Blackhole/Slow" | Tee-Object -FilePath $reportPath -Append
    $findings += "PROBLEM: IPv6 is a 'PMTU black hole' - it connects but is more than 2x slower than IPv4 ($v6total s vs $v4total s). This is a classic cause of browsers hanging/stalling on some sites. Fix: run `"Disable-NetAdapterBinding -Name '$WifiAdapterName' -ComponentID ms_tcpip6`" in an admin PowerShell."
} elseif ($v6total -le ($v4total * 1.2)) {
    "IPv6 state: Healthy" | Tee-Object -FilePath $reportPath -Append
    $findings += "OK: IPv6 is healthy - within 20% of IPv4's speed, no black hole."
} else {
    "IPv6 state: Degraded" | Tee-Object -FilePath $reportPath -Append
    $findings += "MINOR: IPv6 is somewhat slower than IPv4 ($v6total s vs $v4total s) but not a clear black hole. Worth watching."
}

Section "8. Single-stream vs Multi-stream Throughput (detects per-connection ISP throttling)"
"--- 1 connection ---" | Tee-Object -FilePath $reportPath -Append
$single = curl.exe -4 -o NUL -s -w "%{speed_download}" $ThroughputUrl --max-time 20
$singleMbps = [math]::Round(([double]$single) * 8 / 1MB, 1)
"Single-stream speed: $single B/s (~$singleMbps Mbps)" | Tee-Object -FilePath $reportPath -Append

"--- 4 parallel connections ---" | Tee-Object -FilePath $reportPath -Append
$jobs = 1..4 | ForEach-Object {
    Start-Job -ScriptBlock { param($u) curl.exe -4 -o NUL -s -w "%{speed_download}" $u --max-time 20 } -ArgumentList $ThroughputUrl
}
$results = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job
$total = 0
$results | ForEach-Object { $total += [double]$_ }
$totalMbps = [math]::Round($total * 8 / 1MB, 1)
"Per-stream speeds (B/s): $($results -join ', ')" | Tee-Object -FilePath $reportPath -Append
"Aggregate 4-stream speed: $total B/s (~$totalMbps Mbps)" | Tee-Object -FilePath $reportPath -Append
$ratio = if ([double]$single -gt 0) { [math]::Round($total / [double]$single, 2) } else { 0 }
"Scaling factor (4-stream / 1-stream): $ratio  (near 4x = per-connection throttling likely; near 1x = true bandwidth cap)" |
    Tee-Object -FilePath $reportPath -Append
$metrics.SingleStreamMbps = $singleMbps
$metrics.ScalingFactor = $ratio
if ($ratio -ge 3) {
    $findings += "LIKELY ISP THROTTLING: single connection got only ~$singleMbps Mbps, but 4 parallel connections got ~$totalMbps Mbps (${ratio}x scaling). Your ISP is likely capping speed per-connection, not overall. Fill in templates/isp_evidence_template.md and call your ISP."
} elseif ($ratio -le 1.3) {
    $findings += "OK: throughput does not scale with more connections (${ratio}x) - you're at a real bandwidth ceiling (~$singleMbps Mbps), not being throttled per-connection. A plan upgrade would help more than a support ticket."
} else {
    $findings += "UNCLEAR: some scaling with more connections (${ratio}x) - mild throttling possible but not conclusive. Re-run the test at a different time to confirm."
}

Section "9. Proxy / VPN / Security Software Sanity Check"
$proxyRaw = netsh winhttp show proxy
$proxyRaw | Tee-Object -FilePath $reportPath -Append
$vpnAdapters = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "VPN|TAP|Cisco|Fortinet|Pulse|GlobalProtect" -and $_.Status -eq "Up" }
$vpnAdapters | Format-Table Name, InterfaceDescription, Status | Out-String | Tee-Object -FilePath $reportPath -Append
if ($proxyRaw -match "Direct access") {
    $findings += "OK: no system proxy configured."
} else {
    $findings += "NOTE: a system proxy is configured. This can add latency or break some sites - worth checking if it's intentional."
}
if ($vpnAdapters) {
    $findings += "NOTE: an active VPN adapter was found ($($vpnAdapters.Name -join ', ')). VPNs add overhead and can be the real cause of slowness - try testing with it off."
}

Section "10. Path MTU Discovery"
if ($CheckMtu) {
    $size = 1472
    $workingSize = $null
    while ($size -gt 1200) {
        $pingOut = & ping.exe -f -l $size -n 1 $TargetHost
        if ($pingOut -match "Received = 1" -and $pingOut -notmatch "fragmented") {
            $workingSize = $size
            break
        }
        $size -= 10
    }
    if ($workingSize) {
        $fullMtu = $workingSize + 28
        "Largest unfragmented payload to ${TargetHost}: $workingSize bytes -> functional MTU: $fullMtu bytes" |
            Tee-Object -FilePath $reportPath -Append
        $metrics.PathMtu = $fullMtu
        if ($fullMtu -lt 1500) {
            $findings += "NOTE: functional path MTU to $TargetHost is $fullMtu bytes (standard is 1500). If using a VPN, set its MTU to $fullMtu or slightly below to avoid fragmentation stalls."
        } else {
            $findings += "OK: full 1500-byte MTU path is clear to $TargetHost, no fragmentation issues."
        }
    } else {
        "Could not determine a working MTU size down to 1200 bytes - possible heavy filtering of ICMP." |
            Tee-Object -FilePath $reportPath -Append
        $findings += "MINOR: path MTU discovery was inconclusive (ICMP may be filtered along the route)."
    }
} else {
    "(Skipped - run with -CheckMtu to auto-discover the functional MTU for VPN configuration)" |
        Tee-Object -FilePath $reportPath -Append
}

Section "11. Plain-Language Summary & Diagnosis"
$problems = $findings | Where-Object { $_ -match "^PROBLEM|^LIKELY" }
$minor    = $findings | Where-Object { $_ -match "^MINOR|^UNCLEAR|^NOTE" }
$ok       = $findings | Where-Object { $_ -match "^OK" }

if ($problems.Count -gt 0) {
    "Overall: ISSUES FOUND ($($problems.Count))" | Tee-Object -FilePath $reportPath -Append
} elseif ($minor.Count -gt 0) {
    "Overall: MOSTLY FINE, minor notes below" | Tee-Object -FilePath $reportPath -Append
} else {
    "Overall: EVERYTHING LOOKS HEALTHY" | Tee-Object -FilePath $reportPath -Append
}
"" | Tee-Object -FilePath $reportPath -Append
if ($problems.Count -gt 0) {
    "--- Problems to act on ---" | Tee-Object -FilePath $reportPath -Append
    $problems | ForEach-Object { "- $_" | Tee-Object -FilePath $reportPath -Append }
    "" | Tee-Object -FilePath $reportPath -Append
}
if ($minor.Count -gt 0) {
    "--- Notes / minor items ---" | Tee-Object -FilePath $reportPath -Append
    $minor | ForEach-Object { "- $_" | Tee-Object -FilePath $reportPath -Append }
    "" | Tee-Object -FilePath $reportPath -Append
}
"--- Passed checks ---" | Tee-Object -FilePath $reportPath -Append
$ok | ForEach-Object { "- $_" | Tee-Object -FilePath $reportPath -Append }

Section "12. Change Since Last Run"
if (Test-Path $baselinePath) {
    try {
        $prev = Get-Content $baselinePath -Raw | ConvertFrom-Json
        $prevTime = $prev.Timestamp
        "Comparing against baseline from: $prevTime" | Tee-Object -FilePath $reportPath -Append
        $diffLines = @()
        foreach ($key in $metrics.Keys) {
            if ($prev.Metrics.PSObject.Properties.Name -contains $key) {
                $prevVal = [double]$prev.Metrics.$key
                $curVal  = [double]$metrics[$key]
                $delta = [math]::Round($curVal - $prevVal, 1)
                if ([math]::Abs($delta) -gt 0) {
                    $dir = if ($delta -gt 0) { "higher" } else { "lower" }
                    $diffLines += "$key : $curVal (was $prevVal) -> $([math]::Abs($delta)) $dir"
                }
            }
        }
        if ($diffLines.Count -gt 0) {
            $diffLines | ForEach-Object { "- $_" | Tee-Object -FilePath $reportPath -Append }
        } else {
            "No measurable change since last run." | Tee-Object -FilePath $reportPath -Append
        }
    } catch {
        "(Could not read previous baseline - it may be from an older script version.)" | Tee-Object -FilePath $reportPath -Append
    }
} else {
    "No previous baseline found - this run will become the baseline for next time." | Tee-Object -FilePath $reportPath -Append
}
@{ Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm"); Metrics = $metrics } | ConvertTo-Json | Set-Content -Path $baselinePath -Encoding utf8

Section "DONE"
"Full report saved to: $reportPath" | Tee-Object -FilePath $reportPath -Append
Write-Host "`nReport saved to: $reportPath" -ForegroundColor Green
if ($problems.Count -gt 0) {
    Write-Host "`n$($problems.Count) issue(s) found - see 'Plain-Language Summary & Diagnosis' section in the report." -ForegroundColor Yellow
} else {
    Write-Host "`nNo major issues found - see 'Plain-Language Summary & Diagnosis' section in the report." -ForegroundColor Green
}
