<#
.SYNOPSIS
    Checks HTTPS / SSL connectivity, TLS versions, and certificate health for a given endpoint.

.DESCRIPTION
    sslCheck.ps1 performs a layered SSL/TLS inspection of an HTTPS endpoint:

        [Stage 1] DNS Resolution
            Resolves the hostname to IP addresses.
            Exits early if resolution fails — handles both private and public endpoints.

        [Stage 2] TCP Reachability
            Attempts a TCP connection on the target port.
            Runs a fast Traceroute on failure to identify where traffic is dropped.

        [Stage 3] TLS Handshake & Certificate Inspection
            Only runs when TCP is confirmed. Negotiates TLS, inspects the certificate,
            extracts SANs, builds the chain, and classifies the CA type.

        [Stage 4 — Optional] Legacy TLS Audit
            Safe isolated probes to detect which TLS versions the endpoint accepts.
            Enabled with -AuditLegacyTls. Does not affect the primary connection.

        [Warnings]
            All advisory items (expiry, deprecated TLS, chain issues) are collected
            during execution and printed together at the end in one place.

    No HTTP content is downloaded. This is a read-only security and connectivity check.

.PARAMETER Uri
    The HTTPS endpoint to test. https:// prefix is optional.

.PARAMETER Port
    TCP port to connect to. Default: 443.

.PARAMETER TimeoutMs
    Connection timeout in milliseconds. Default: 5000.

.PARAMETER TraceRouteHops
    Maximum hops for Traceroute when TCP fails. Default: 15.
    Keeping this low ensures the trace completes in a few seconds.

.PARAMETER AuditLegacyTls
    Probe which TLS versions (1.0-1.3) the endpoint accepts. Non-destructive.

.PARAMETER SkipTraceroute
    Suppress the automatic Traceroute on TCP failure.

.EXAMPLE
    .\sslCheck.ps1 -Uri https://example.com
    .\sslCheck.ps1 -Uri https://example.com -AuditLegacyTls
    .\sslCheck.ps1 -Uri https://internal-api.corp.local -TimeoutMs 10000
    .\sslCheck.ps1 -Uri https://example.com -Port 8443 -SkipTraceroute

.NOTES
    Author      : Hashim Hilal
    Script Name : sslCheck.ps1
    Version     : 2.1

    - Negotiated TLS reflects the actual protocol used by the OS/client.
    - In TLS-intercepted networks (e.g. Zscaler), results reflect the client-to-proxy leg.
    - Traceroute uses Test-NetConnection -TraceRoute (ICMP, Windows 8+ / PS 4.0+).
#>

param (
    [Parameter(Mandatory)]
    [string]$Uri,

    [int]$Port           = 443,
    [int]$TimeoutMs      = 5000,
    [int]$TraceRouteHops = 15,

    [switch]$AuditLegacyTls,
    [switch]$SkipTraceroute
)

#region ── Helpers ───────────────────────────────────────────────────────────────

# Warnings and failures are collected during all stages and printed once at the end
$script:WarningLog = [System.Collections.Generic.List[string]]::new()
$script:FailLog    = [System.Collections.Generic.List[string]]::new()
function Add-Warning { param([string]$msg) $script:WarningLog.Add($msg) }
function Add-Failure { param([string]$msg) $script:FailLog.Add($msg) }

function Write-Section {
    param([string]$Title)
    $line = "-" * 62
    Write-Host ""
    Write-Host $line       -ForegroundColor DarkGray
    Write-Host "  $Title"  -ForegroundColor Cyan
    Write-Host $line       -ForegroundColor DarkGray
}

function Write-Status {
    param([string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("  {0,-26} {1}" -f "${Label}:", $Value) -ForegroundColor $Color
}

function Write-Pass { param([string]$msg) Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail { param([string]$msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red   }
function Write-Info { param([string]$msg) Write-Host "  [INFO] $msg" -ForegroundColor Gray  }
function Write-Note { param([string]$msg) Write-Host "  [NOTE] $msg" -ForegroundColor Cyan  }

#endregion

#region ── Stage 1 - DNS Resolution ─────────────────────────────────────────────

function Resolve-TargetHost {
    param([string]$Hostname)

    Write-Section "Stage 1 - DNS Resolution"

    $ipParsed = $null
    if ([System.Net.IPAddress]::TryParse($Hostname, [ref]$ipParsed)) {
        Write-Pass "Input is a raw IP address - DNS lookup skipped"
        Write-Status "IP Address" $Hostname "Green"
        return [PSCustomObject]@{ Success=$true; Hostname=$Hostname; ResolvedIPs=@($Hostname); ErrorMessage=$null }
    }

    try {
        $ips = [System.Net.Dns]::GetHostAddresses($Hostname) | ForEach-Object { $_.ToString() }
        Write-Pass "DNS resolution succeeded"
        Write-Status "Hostname"     $Hostname
        Write-Status "Resolved IPs" ($ips -join ", ") "Green"
        return [PSCustomObject]@{ Success=$true; Hostname=$Hostname; ResolvedIPs=$ips; ErrorMessage=$null }
    }
    catch {
        $err = $_.Exception.Message
        Write-Fail "DNS resolution FAILED for '$Hostname'"
        Write-Info "Error  : $err"
        Write-Info "Causes : hostname misspelled | private zone not visible from this network | DNS not configured for this zone"
        return [PSCustomObject]@{ Success=$false; Hostname=$Hostname; ResolvedIPs=@(); ErrorMessage=$err }
    }
}

#endregion

#region ── Stage 2 - TCP Reachability ───────────────────────────────────────────

function Test-TCPReachability {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs, [int]$TraceRouteHops, [bool]$SkipTraceroute)

    Write-Section "Stage 2 - TCP Reachability  ($TargetHost : $Port)"

    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $ok  = $tcp.ConnectAsync($TargetHost, $Port).Wait($TimeoutMs)
        $sw.Stop()

        if ($ok -and $tcp.Connected) {
            Write-Pass "TCP connection established"
            Write-Status "Connection time" "$($sw.ElapsedMilliseconds) ms" "Green"
            return $true
        }

        Write-Fail "TCP connection timed out after $TimeoutMs ms"
    }
    catch {
        Write-Fail "TCP connection FAILED: $($_.Exception.Message)"
        Write-Info "Causes : firewall blocking port $Port | service not running | routing issue"
    }
    finally {
        if ($tcp) { $tcp.Dispose() }
    }

    Invoke-Traceroute -TargetHost $TargetHost -MaxHops $TraceRouteHops -Skip $SkipTraceroute
    return $false
}

#endregion

#region ── Traceroute ────────────────────────────────────────────────────────────

function Invoke-Traceroute {
    param([string]$TargetHost, [int]$MaxHops, [bool]$Skip)

    if ($Skip) { Write-Info "Traceroute skipped (-SkipTraceroute)"; return }

    Write-Section "Traceroute  ->  $TargetHost  (max $MaxHops hops)"
    Write-Info "Running..."

    try {
        $trace = Test-NetConnection -ComputerName $TargetHost `
                     -TraceRoute -Hops $MaxHops `
                     -InformationLevel Quiet `
                     -WarningAction SilentlyContinue

        $n = 1
        foreach ($hop in $trace.TraceRoute) {
            $display = if ([string]::IsNullOrEmpty($hop) -or $hop -eq "0.0.0.0") {
                "* * *  (no response)"
            } else { $hop }
            Write-Host ("    {0,3}   {1}" -f $n, $display) -ForegroundColor DarkCyan
            $n++
        }

        if ($trace.PingSucceeded) {
            Write-Info "Host responds to ICMP - destination is up, port may be filtered by firewall"
        } else {
            Write-Info "Host did not respond to ICMP ping"
        }
    }
    catch {
        Write-Info "Traceroute unavailable: $($_.Exception.Message)"
        Write-Info "Run manually:  tracert $TargetHost"
    }
}

#endregion

#region ── TLS Audit Probe ───────────────────────────────────────────────────────

function Test-TlsSupport {
    param([string]$TargetHost, [int]$Port, [string]$Protocol, [int]$TimeoutMs)

    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout    = $TimeoutMs
        $tcp.Connect($TargetHost, $Port)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($TargetHost, $null,
            [System.Security.Authentication.SslProtocols]::$Protocol, $false)
        return $true
    }
    catch { return $false }
    finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Dispose() }
    }
}

#endregion

#region ── Stage 3 - TLS Handshake & Certificate Inspection ─────────────────────

function Get-SSLCertificateInfo {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs, [switch]$AuditLegacyTls)

    $tcpClient = $null; $sslStream = $null

    try {
        # ── TLS Handshake ─────────────────────────────────────────────────────
        Write-Section "Stage 3 - TLS Handshake"

        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcpClient.ConnectAsync($TargetHost, $Port).Wait($TimeoutMs) | Out-Null
        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, { $true })
        $sslStream.AuthenticateAsClient($TargetHost)
        $sw.Stop()

        if (-not $sslStream.RemoteCertificate) { throw "Server presented no certificate" }

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
            $sslStream.RemoteCertificate

        $rawProto   = $sslStream.SslProtocol.ToString()
        $tlsVersion = switch ($rawProto) {
            "Tls"   { "TLS 1.0" }
            "Tls11" { "TLS 1.1" }
            "Tls12" { "TLS 1.2" }
            "Tls13" { "TLS 1.3" }
            default { $rawProto.ToUpper() }
        }
        $tlsColor = switch ($rawProto) {
            { $_ -in "Tls","Tls11" } { "Red"    }
            "Tls12"                  { "Yellow" }
            "Tls13"                  { "Green"  }
            default                  { "White"  }
        }

        Write-Pass "TLS handshake succeeded"
        Write-Status "Negotiated TLS"  $tlsVersion                                                    $tlsColor
        Write-Status "Cipher"          "$($sslStream.CipherAlgorithm.ToString().ToUpper())  ($($sslStream.CipherStrength)-bit)"
        Write-Status "Hash"            $sslStream.HashAlgorithm.ToString().ToUpper()
        Write-Status "Handshake time"  "$($sw.ElapsedMilliseconds) ms"

        if ($rawProto -in "Tls","Tls11") {
            Add-Warning "Negotiated TLS is $tlsVersion which is deprecated. Upgrade the server to TLS 1.2 or 1.3."
        }

        # ── Certificate Details ───────────────────────────────────────────────
        Write-Section "Certificate Details"

        $daysRemaining = ($cert.NotAfter - (Get-Date)).Days

        $expiryColor = if    ($daysRemaining -lt 0)  { "Red"    }
                       elseif ($daysRemaining -lt 30) { "Red"    }
                       elseif ($daysRemaining -lt 90) { "Yellow" }
                       else                           { "Green"  }

        $expiryLabel = if    ($daysRemaining -lt 0)  { "EXPIRED  ($([math]::Abs($daysRemaining)) days ago)" }
                       elseif ($daysRemaining -lt 30) { "$daysRemaining days  (expires soon)"               }
                       else                           { "$daysRemaining days"                                }

        # SANs — parse into a flat list, then group by root domain for display
        $sanExt  = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
        $sanList = if ($sanExt) {
            $sanExt.Format($true) -split "`r?`n" |
                Where-Object { $_ -match '\S' } |
                ForEach-Object { ($_ -replace '^DNS Name=|^IP Address=', '').Trim() } |
                Where-Object { $_ -ne '' }
        } else { @() }

        # Group by root domain (last two labels); wildcards and IPs handled gracefully
        $sanGroups = $sanList | Group-Object {
            $e     = $_ -replace '^\*\.', ''
            $parts = $e -split '\.'
            if ($parts.Count -ge 2) { ($parts[-2..-1]) -join '.' } else { $e }
        } | Sort-Object Name

        # Flat string kept for the return object
        $sans = if ($sanList.Count -gt 0) { $sanList -join "; " } else { "None" }

        # Certificate chain
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode    = "NoCheck"
        $chain.ChainPolicy.VerificationFlags = "IgnoreWrongUsage"
        $chainValid = $chain.Build($cert)
        $rootCA = if ($chain.ChainElements.Count -gt 0) {
            $chain.ChainElements[-1].Certificate.Subject
        } else { "Unknown" }

        # CA type — informational classification only
        $certType = if ($cert.Subject -eq $cert.Issuer) {
            "Self-Signed"
        } elseif ($rootCA -match '(?i)DIGICERT|GLOBALSIGN|SECTIGO|ENTRUST|LET.?S ENCRYPT|GODADDY|VERISIGN|GEOTRUST|AMAZON|MICROSOFT|ZSCALER') {
            "Publicly Trusted CA"
        } else {
            "Private / Internal CA"
        }

        # Neutral, context-aware note for each cert type
        $certTypeNote = switch ($certType) {
            "Self-Signed"           { "Self-signed certificate. Normal for internal services, dev, and test endpoints." }
            "Publicly Trusted CA"   { "Issued by a globally trusted CA, or a TLS inspection proxy (e.g. Zscaler)."     }
            "Private / Internal CA" { "Issued by an internal CA. Normal in enterprise environments."                   }
        }

        $chainLabel = if ($chainValid) { "Yes" } else { "No  (expected for self-signed / private CA certs)" }
        $chainColor = if ($chainValid) { "Green" } else { "Gray" }

        Write-Status "Subject"        $cert.Subject
        Write-Status "Issuer"         $cert.Issuer
        Write-Status "Valid From"     $cert.NotBefore.ToString("yyyy-MM-dd HH:mm")
        Write-Status "Valid To"       $cert.NotAfter.ToString("yyyy-MM-dd HH:mm")   $expiryColor
        Write-Status "Days Remaining" $expiryLabel                                  $expiryColor
        Write-Status "Certificate"    $certType
        Write-Status "Chain Valid"    $chainLabel                                   $chainColor
        Write-Status "Root CA"        $rootCA                                       "White"
        # SANs grouped display
        if ($sanList.Count -eq 0) {
            Write-Status "SANs" "None" "White"
        } else {
            Write-Host ("  {0,-26} {1} entries across {2} domain(s)" -f "SANs:", $sanList.Count, $sanGroups.Count) -ForegroundColor White
            foreach ($grp in $sanGroups) {
                $entries = $grp.Group -join "  |  "
                Write-Host ("    {0,-22} {1}" -f "$($grp.Name):", $entries) -ForegroundColor DarkCyan
            }
        }
        Write-Note   $certTypeNote

        # Queue expiry warnings (printed at end, not here)
        if ($daysRemaining -lt 0) {
            Add-Warning "Certificate EXPIRED $([math]::Abs($daysRemaining)) days ago. HTTPS will fail for clients enforcing cert validation."
        } elseif ($daysRemaining -lt 30) {
            Add-Warning "Certificate expires in $daysRemaining days. Renew immediately to avoid service disruption."
        } elseif ($daysRemaining -lt 90) {
            Add-Warning "Certificate expires in $daysRemaining days. Schedule renewal soon."
        }

        if (-not $chainValid -and $certType -eq "Publicly Trusted CA") {
            Add-Warning "Chain validation failed for a publicly trusted certificate. Investigate intermediate certificates."
        }

        # ── Stage 4 - Legacy TLS Audit ────────────────────────────────────────
        $supportedTls     = @()
        $legacyTlsEnabled = $false

        if ($AuditLegacyTls) {
            Write-Section "Stage 4 - TLS Version Audit  (non-destructive probes)"

            $probes    = @(
                @{ Label="TLS 1.0"; Enum="Tls"   },
                @{ Label="TLS 1.1"; Enum="Tls11" },
                @{ Label="TLS 1.2"; Enum="Tls12" },
                @{ Label="TLS 1.3"; Enum="Tls13" }
            )
            $enumNames = [System.Security.Authentication.SslProtocols].GetEnumNames()

            foreach ($p in $probes) {
                if ($p.Enum -eq "Tls13" -and "Tls13" -notin $enumNames) {
                    Write-Status $p.Label "Not available on this OS" "DarkGray"
                    continue
                }

                $ok = Test-TlsSupport -TargetHost $TargetHost -Port $Port -Protocol $p.Enum -TimeoutMs $TimeoutMs

                if ($ok) {
                    $supportedTls += $p.Label
                    $legacy = $p.Label -in "TLS 1.0","TLS 1.1"
                    $suffix = if ($legacy) { "  <- deprecated" } else { "" }
                    $color  = if ($legacy) { "Yellow" } else { "Green" }
                    Write-Status $p.Label "Accepted$suffix" $color
                    if ($legacy) { Add-Warning "Server accepts $($p.Label) which is deprecated. Disable it on the server." }
                } else {
                    Write-Status $p.Label "Rejected" "DarkGray"
                }
            }

            $legacyTlsEnabled = ($supportedTls -contains "TLS 1.0") -or ($supportedTls -contains "TLS 1.1")
        }

        return [PSCustomObject]@{
            Host             = $TargetHost
            Port             = $Port
            HandshakeMs      = $sw.ElapsedMilliseconds
            NegotiatedTLS    = $tlsVersion
            CipherAlgorithm  = $sslStream.CipherAlgorithm.ToString().ToUpper()
            CipherStrength   = $sslStream.CipherStrength
            HashAlgorithm    = $sslStream.HashAlgorithm.ToString().ToUpper()
            Subject          = $cert.Subject
            Issuer           = $cert.Issuer
            NotBefore        = $cert.NotBefore
            NotAfter         = $cert.NotAfter
            DaysRemaining    = $daysRemaining
            SANs             = $sans
            CertificateType  = $certType
            ChainValid       = $chainValid
            RootCA           = $rootCA
            SupportedTLS     = $supportedTls
            LegacyTLSEnabled = $legacyTlsEnabled
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Fail "TLS inspection failed: $errMsg"
        Add-Failure "TLS handshake failed: $errMsg"
        return $null
    }
    finally {
        if ($sslStream) { $sslStream.Dispose() }
        if ($tcpClient) { $tcpClient.Dispose() }
    }
}

#endregion

#region ── Entry Point ───────────────────────────────────────────────────────────

if ($Uri -notmatch '^https?://') { $Uri = "https://$Uri" }
$parsedUri  = [System.Uri]$Uri
$targetHost = $parsedUri.Host
if ($parsedUri.Port -ne -1) { $Port = $parsedUri.Port }

Write-Host ""
Write-Host "  SSL / TLS Connectivity Check  v2.1" -ForegroundColor Cyan
Write-Host "  Target : $targetHost : $Port"
Write-Host "  Run at : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Stage 1 - DNS
$dns = Resolve-TargetHost -Hostname $targetHost
if (-not $dns.Success) {
    Write-Host ""
    Write-Fail "Halted - DNS resolution failed."
    Write-Host ""
    exit 1
}

# Stage 2 - TCP
$reachable = Test-TCPReachability `
    -TargetHost     $targetHost `
    -Port           $Port `
    -TimeoutMs      $TimeoutMs `
    -TraceRouteHops $TraceRouteHops `
    -SkipTraceroute $SkipTraceroute.IsPresent

if (-not $reachable) {
    Write-Host ""
    Write-Fail "Halted - TCP connection failed."
    Write-Host ""
    exit 2
}

# Stage 3 (+4) - TLS & Certificate
$result = Get-SSLCertificateInfo `
    -TargetHost     $targetHost `
    -Port           $Port `
    -TimeoutMs      $TimeoutMs `
    -AuditLegacyTls:$AuditLegacyTls

# Warnings - all collected items printed once, at the end
Write-Section "Warnings"
if ($script:FailLog.Count -gt 0) {
    foreach ($f in $script:FailLog) {
        Write-Fail $f
    }
}
if ($script:WarningLog.Count -gt 0) {
    $i = 1
    foreach ($w in $script:WarningLog) {
        Write-Host ("  {0,2}. {1}" -f $i, $w) -ForegroundColor Yellow
        $i++
    }
}
if ($script:FailLog.Count -eq 0 -and $script:WarningLog.Count -eq 0) {
    Write-Pass "No warnings - all checks passed cleanly"
}

Write-Host ""

#endregion
