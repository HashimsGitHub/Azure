<#
.SYNOPSIS
    Checks HTTPS / SSL connectivity, TLS versions, and certificate health for a given endpoint.

.DESCRIPTION
    sslCheck.ps1 performs a layered SSL/TLS inspection of an HTTPS endpoint:

        [Stage 1] DNS Resolution
            Resolves the hostname to IP addresses.
            Exits early if resolution fails - handles both private and public endpoints.

        [Stage 2] TCP Reachability
            Attempts a TCP connection on the target port.
            Runs a fast Traceroute on failure to identify where traffic is dropped.

        [Stage 3a] TLS Handshake & Certificate Inspection
            Connects with certificate bypass to inspect the cert regardless of trust.
            Reports TLS version, cipher, certificate details, SANs grouped by domain.
            Includes Certificate Transparency log verification for public certs.

        [Stage 3b] Real-World Trust Validation
            Connects WITHOUT bypass using the Windows certificate store - exactly
            as Invoke-WebRequest, browsers, and applications do.
            A failure here means real clients will reject the endpoint.

        [Stage 3c] HTTP Response
            Sends a real HTTP GET using Invoke-WebRequest and reports status code,
            response time, and all response headers. Only runs if Stage 3b passes.
            4xx/5xx responses are shown in full and queued as warnings.

        [Stage 4 - Optional] Legacy TLS Audit
            Safe isolated probes to detect which TLS versions the endpoint accepts.
            Enabled with -AuditLegacyTls. Does not affect the primary connection.

        [Connection Summary]
            Shown when all stages pass. Reports source IP, source hostname,
            destination IP, and destination hostname for the completed connection.

        [ICMP Ping]
            Sends 4 ICMP echo requests to the target. Always runs if TCP succeeded.
            Reports packet loss, round-trip times, and TTL. Purely informational -
            ICMP filtering does not affect HTTPS connectivity results.

        [Warnings]
            All advisory items and hard failures are collected during execution
            and printed together at the end in one place.

    No HTTP content is downloaded. This is a read-only security and connectivity check.
    All stages include graceful error handling - unexpected failures are caught,
    reported cleanly, and logged to the Warnings section without crashing the script.

.PARAMETER Uri
    The HTTPS endpoint to test. https:// prefix is optional.

.PARAMETER Port
    TCP port to connect to. Default: 443.

.PARAMETER TimeoutMs
    Connection timeout in milliseconds. Default: 5000.

.PARAMETER TraceRouteHops
    Maximum hops for Traceroute when TCP fails. Default: 15.

.PARAMETER AuditLegacyTls
    Probe which TLS versions (1.0-1.3) the endpoint accepts. Non-destructive.

.PARAMETER SkipTraceroute
    Suppress the automatic Traceroute on TCP failure.

.PARAMETER RetryCount
    Number of retry attempts for TCP connections. Default: 0.

.PARAMETER RetryDelayMs
    Delay between retry attempts in milliseconds. Default: 1000.

.EXAMPLE
    .\sslCheck.ps1 -Uri https://example.com
    .\sslCheck.ps1 -Uri https://example.com -AuditLegacyTls
    .\sslCheck.ps1 -Uri https://internal-api.corp.local -TimeoutMs 10000
    .\sslCheck.ps1 -Uri https://example.com -Port 8443 -SkipTraceroute
    .\sslCheck.ps1 -Uri https://flaky.example.com -RetryCount 2 -RetryDelayMs 2000

.NOTES
    Author      : Hashim Hilal
    Script Name : sslCheck.ps1
    Version     : 2.8

    - Stage 3a uses certificate bypass for inspection purposes only.
    - Stage 3b uses real Windows trust validation - matches Invoke-WebRequest behaviour.
    - In TLS-intercepted networks (e.g. Zscaler), results reflect the client-to-proxy leg.
    - Traceroute uses Test-NetConnection -TraceRoute (ICMP, Windows 8+ / PS 4.0+).
    - TLS 1.3 probing requires Windows 10 1903+ or Windows Server 2022.
#>

param (
    [Parameter(Mandatory)]
    [string]$Uri,

    [int]$Port           = 443,
    [int]$TimeoutMs      = 5000,
    [int]$TraceRouteHops = 15,
    [int]$RetryCount     = 0,
    [int]$RetryDelayMs   = 1000,

    [switch]$AuditLegacyTls,
    [switch]$SkipTraceroute
)

#region -- Initialization --------------------------------------------------------

$script:WarningLog = [System.Collections.Generic.List[string]]::new()
$script:FailLog    = [System.Collections.Generic.List[string]]::new()
$scriptStartTime   = Get-Date

function Add-Warning { param([string]$msg) $script:WarningLog.Add($msg) }
function Add-Failure { param([string]$msg) $script:FailLog.Add($msg) }

function Write-Section {
    param([string]$Title)
    $line = "-" * 62
    Write-Host ""
    Write-Host $line      -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $line      -ForegroundColor DarkGray
}

function Write-Status {
    param([string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host ("  {0,-26} {1}" -f "${Label}:", $Value) -ForegroundColor $Color
}

function Write-Pass { param([string]$msg) Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail { param([string]$msg) Write-Host "  [FAIL] $msg" -ForegroundColor Red   }
function Write-Info { param([string]$msg) Write-Host "  [INFO] $msg" -ForegroundColor Gray  }
function Write-Note { param([string]$msg) Write-Host "  [NOTE] $msg" -ForegroundColor Cyan  }

function Write-GracefulExit {
    param([string]$Stage, [string]$Reason)
    Write-Section "Unexpected Error"
    Write-Fail "Unexpected error in $Stage"
    Write-Info "Reason : $Reason"
    Write-Info "The script has exited cleanly. No further stages were run."
    Write-Host ""
}

# Cipher suite name mapping for better readability
$script:CipherNameMap = @{
    "Aes256"    = "AES-256-GCM"
    "Aes128"    = "AES-128-GCM"
    "Aes"       = "AES (variant)"
    "Des"       = "DES (insecure)"
    "Rc2"       = "RC2 (insecure)"
    "Rc4"       = "RC4 (insecure)"
    "TripleDes" = "3DES (legacy)"
    "None"      = "None (unencrypted)"
}

#endregion

#region -- Stage 1 - DNS Resolution ----------------------------------------------

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
        # DNS resolution with explicit timeout
        $dnsTask = [System.Net.Dns]::GetHostAddressesAsync($Hostname)
        if (-not $dnsTask.Wait(3000)) {
            throw "DNS resolution timed out after 3 seconds"
        }

        $ips = $dnsTask.Result | ForEach-Object { $_.ToString() }
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

#region -- Stage 2 - TCP Reachability --------------------------------------------

function Test-TCPReachability {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs,
        [int]$TraceRouteHops,
        [bool]$SkipTraceroute,
        [int]$RetryCount,
        [int]$RetryDelayMs
    )

    Write-Section "Stage 2 - TCP Reachability  ($TargetHost : $Port)"

    $attempts = 1 + $RetryCount

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-Info "Retry attempt $attempt of $attempts (waiting $RetryDelayMs ms)..."
            Start-Sleep -Milliseconds $RetryDelayMs
        }

        $tcp = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $sw  = [System.Diagnostics.Stopwatch]::StartNew()
            $ok  = $tcp.ConnectAsync($TargetHost, $Port).Wait($TimeoutMs)
            $sw.Stop()

            if ($ok -and $tcp.Connected) {
                Write-Pass "TCP connection established"
                Write-Status "Connection time" "$($sw.ElapsedMilliseconds) ms" "Green"
                if ($attempt -gt 1) {
                    Write-Info "Connection succeeded on attempt $attempt"
                }
                return $true
            }

            Write-Fail "TCP connection timed out after $TimeoutMs ms (attempt $attempt of $attempts)"
        }
        catch {
            Write-Fail "TCP connection FAILED: $($_.Exception.Message) (attempt $attempt of $attempts)"
            if ($attempt -eq $attempts) {
                Write-Info "Causes : firewall blocking port $Port | service not running | routing issue"
            }
        }
        finally {
            if ($tcp) { $tcp.Dispose() }
        }
    }

    Invoke-Traceroute -TargetHost $TargetHost -MaxHops $TraceRouteHops -Skip $SkipTraceroute
    return $false
}

#endregion

#region -- Traceroute ------------------------------------------------------------

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

#region -- TLS Audit Probe -------------------------------------------------------

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
        if ($ssl) { try { $ssl.Dispose() } catch {} }
        if ($tcp) { try { $tcp.Dispose() } catch {} }
    }
}

#endregion

#region -- Stage 3b - Real-World Trust Validation --------------------------------

function Test-RealWorldTrust {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs)

    Write-Section "Stage 3b - Real-World Trust Validation"
    Write-Info "Connecting using Windows certificate store (no bypass)..."

    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.ConnectAsync($TargetHost, $Port).Wait($TimeoutMs) | Out-Null

        $ssl = New-Object System.Net.Security.SslStream(
            $tcp.GetStream(),
            $false
        )
        $ssl.AuthenticateAsClient($TargetHost)

        Write-Pass "Real-world trust validation PASSED"
        Write-Info "Invoke-WebRequest and applications will trust this endpoint"
        return $true
    }
    catch {
        $errMsg = $_.Exception.Message
        $reason = if ($_.Exception.InnerException) {
            $_.Exception.InnerException.Message
        } else { $errMsg }

        Write-Fail "Real-world trust validation FAILED"
        Write-Status "Reason" $reason "Red"
        Write-Status "Impact" "Invoke-WebRequest, browsers and applications will reject this endpoint" "Yellow"
        Write-Status "Fix"    "Import the issuing CA into the Trusted Root / Intermediate certificate store" "Yellow"
        Add-Failure "Real-world trust validation failed: $reason"
        return $false
    }
    finally {
        if ($ssl) { try { $ssl.Dispose() } catch {} }
        if ($tcp) { try { $tcp.Dispose() } catch {} }
    }
}

#endregion

#region -- Stage 3a - TLS Handshake & Certificate Inspection ---------------------

function Get-SSLCertificateInfo {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs,
        [switch]$AuditLegacyTls
    )

    $tcpClient = $null; $sslStream = $null

    try {
        Write-Section "Stage 3a - TLS Handshake & Certificate Inspection"
        Write-Info "Connecting with certificate bypass for inspection..."

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
        Write-Status "Negotiated TLS"  $tlsVersion $tlsColor

        # Map cipher to readable name
        $cipherAlgo = $sslStream.CipherAlgorithm.ToString()
        $cipherName = if ($script:CipherNameMap.ContainsKey($cipherAlgo)) {
            $script:CipherNameMap[$cipherAlgo]
        } else {
            $cipherAlgo.ToUpper()
        }
        Write-Status "Cipher"         "$cipherName  ($($sslStream.CipherStrength)-bit)"
        Write-Status "Hash"           $sslStream.HashAlgorithm.ToString().ToUpper()
        Write-Status "Handshake time" "$($sw.ElapsedMilliseconds) ms"
        Write-Status "SNI Sent"       $TargetHost "Green"

        # HTTP version detection
        try {
            $httpVersion = if ($sslStream.NegotiatedApplicationProtocol) {
                $sslStream.NegotiatedApplicationProtocol.ToString()
            } else { "HTTP/1.1 (likely)" }
            Write-Status "HTTP Version" $httpVersion "White"
        }
        catch {
            Write-Status "HTTP Version" "HTTP/1.1 (assumed)" "DarkGray"
        }

        if ($rawProto -in "Tls","Tls11") {
            Add-Warning "Negotiated TLS is $tlsVersion which is deprecated. Upgrade the server to TLS 1.2 or 1.3."
        }

        # -- Certificate Details -----------------------------------------------
        Write-Section "Certificate Details"

        $daysRemaining = ($cert.NotAfter - (Get-Date)).Days

        $expiryColor = if    ($daysRemaining -lt 0)  { "Red"    }
                       elseif ($daysRemaining -lt 30) { "Red"    }
                       elseif ($daysRemaining -lt 90) { "Yellow" }
                       else                           { "Green"  }

        $expiryLabel = if    ($daysRemaining -lt 0)  { "EXPIRED  ($([math]::Abs($daysRemaining)) days ago)" }
                       elseif ($daysRemaining -lt 30) { "$daysRemaining days  (expires soon)"               }
                       else                           { "$daysRemaining days"                                }

        # SANs
        $sanExt  = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
        $sanList = if ($sanExt) {
            $sanExt.Format($true) -split "`r?`n" |
                Where-Object { $_ -match '\S' } |
                ForEach-Object { ($_ -replace '^DNS Name=|^IP Address=', '').Trim() } |
                Where-Object { $_ -ne '' }
        } else { @() }

        $sanGroups = $sanList | Group-Object {
            $e     = $_ -replace '^\*\.', ''
            $parts = $e -split '\.'
            if ($parts.Count -ge 2) { ($parts[-2..-1]) -join '.' } else { $e }
        } | Sort-Object Name

        $sans = if ($sanList.Count -gt 0) { $sanList -join "; " } else { "None" }

        # Chain validation
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode    = "NoCheck"
        $chain.ChainPolicy.VerificationFlags = "IgnoreWrongUsage"
        $chainValid = $chain.Build($cert)

        # Collect chain validation errors
        $chainErrors = @()
        if ($chain.ChainStatus.Length -gt 0) {
            foreach ($status in $chain.ChainStatus) {
                if ($status.Status -ne 'NoError') {
                    $chainErrors += $status.StatusInformation
                }
            }
        }

        $rootCA = if ($chain.ChainElements.Count -gt 0) {
            $rootCert = $chain.ChainElements[-1].Certificate
            if ($null -eq $rootCert) {
                "Unknown"
            } elseif ([string]::IsNullOrWhiteSpace($rootCert.Subject)) {
                $thumb = if ($rootCert.Thumbprint) { $rootCert.Thumbprint.ToLower() } else { "unavailable" }
                "Thumbprint: $thumb  (subject not available)"
            } else {
                $rootCert.Subject
            }
        } else { "Unknown" }

        # CA classification
        $certType = if ($cert.Subject -eq $cert.Issuer) {
            "Self-Signed"
        } elseif ($rootCA -match '(?i)DIGICERT|GLOBALSIGN|SECTIGO|ENTRUST|LET.?S ENCRYPT|GODADDY|VERISIGN|GEOTRUST|AMAZON|MICROSOFT|ZSCALER') {
            "Publicly Trusted CA"
        } else {
            "Private / Internal CA"
        }

        $certTypeNote = switch ($certType) {
            "Self-Signed"           { "Self-signed certificate. Expected for internal and test endpoints."          }
            "Publicly Trusted CA"   { "Issued by a globally trusted CA, or a TLS inspection proxy (e.g. Zscaler)." }
            "Private / Internal CA" { "Issued by an internal CA. Normal in enterprise environments."                }
        }

        $chainLabel = if ($chainValid) { "Yes" } else { "No  (expected for self-signed / private CA certs)" }
        $chainColor = if ($chainValid) { "Green" } else { "Gray" }

        $rootCADisplay = if ([string]::IsNullOrWhiteSpace($rootCA) -or $rootCA -eq "Unknown") {
            "Not available"
        } else { $rootCA }

        Write-Status "Subject"        $cert.Subject
        Write-Status "Issuer"         $cert.Issuer
        Write-Status "Thumbprint"     $cert.Thumbprint.ToLower()
        Write-Status "Serial"         $cert.SerialNumber.ToLower()
        Write-Status "Valid From"     $cert.NotBefore.ToString("yyyy-MM-dd HH:mm")
        Write-Status "Valid To"       $cert.NotAfter.ToString("yyyy-MM-dd HH:mm")   $expiryColor
        Write-Status "Days Remaining" $expiryLabel                                  $expiryColor
        Write-Status "Certificate"    $certType
        Write-Status "Chain Valid"    $chainLabel                                   $chainColor
        Write-Status "Root CA"        $rootCADisplay                                "White"
        Write-Note   $certTypeNote

        # Certificate Transparency check for public certs
        if ($certType -eq "Publicly Trusted CA") {
            $sctExtension = $cert.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.11129.2.4.2" }
            if ($sctExtension) {
                Write-Status "CT Logs" "Present (SCTs found)" "Green"
            } else {
                Write-Status "CT Logs" "Not found" "Yellow"
                Add-Warning "No Certificate Transparency SCTs found. Browsers may flag this certificate."
            }
        }

        # Chain validation errors
        if ($chainErrors.Count -gt 0) {
            Write-Info "Chain validation details:"
            foreach ($error in $chainErrors) {
                Write-Info "  - $error"
            }
        }

        # SANs grouped display
        if ($sanList.Count -eq 0) {
            Write-Status "SANs" "None" "White"
        } else {
            Write-Host ("  {0,-26} {1} entries across {2} domain(s)" -f "SANs:", $sanList.Count, $sanGroups.Count) -ForegroundColor White
            foreach ($grp in $sanGroups) {
                $entries = $grp.Group -join "  |  "
                Write-Host ("    {0,-28} {1}" -f "$($grp.Name):", $entries) -ForegroundColor DarkCyan
            }
        }

        # Expiry warnings
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

        # -- Stage 4 - Legacy TLS Audit ----------------------------------------
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
                    Write-Info "Update to Windows 10 1903+ or Windows Server 2022 for TLS 1.3 probing"
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
            Host              = $TargetHost
            Port              = $Port
            HandshakeMs       = $sw.ElapsedMilliseconds
            NegotiatedTLS     = $tlsVersion
            CipherAlgorithm   = $cipherName
            CipherStrength    = $sslStream.CipherStrength
            HashAlgorithm     = $sslStream.HashAlgorithm.ToString().ToUpper()
            Subject           = $cert.Subject
            Issuer            = $cert.Issuer
            NotBefore         = $cert.NotBefore
            NotAfter          = $cert.NotAfter
            DaysRemaining     = $daysRemaining
            SANs              = $sans
            CertificateType   = $certType
            ChainValid        = $chainValid
            RootCA            = $rootCA
            SupportedTLS      = $supportedTls
            LegacyTLSEnabled  = $legacyTlsEnabled
            ChainErrors       = $chainErrors
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Fail "TLS inspection failed: $errMsg"
        Add-Failure "TLS handshake failed: $errMsg"
        return $null
    }
    finally {
        if ($sslStream) { try { $sslStream.Dispose() } catch {} }
        if ($tcpClient) { try { $tcpClient.Dispose() } catch {} }
    }
}

#endregion

#region -- Stage 3c - HTTP Response ----------------------------------------------

function Invoke-HTTPResponse {
    param([string]$TargetUri, [int]$TimeoutMs)

    Write-Section "Stage 3c - HTTP Response"
    Write-Info "Sending HTTP GET request using real Windows trust chain..."

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $response = Invoke-WebRequest `
            -Uri         $TargetUri `
            -Method      GET `
            -TimeoutSec  ([math]::Ceiling($TimeoutMs / 1000)) `
            -ErrorAction Stop

        $sw.Stop()

        $statusCode  = [int]$response.StatusCode
        $statusDesc  = $response.StatusDescription
        $statusColor = if    ($statusCode -lt 300) { "Green"  }
                       elseif ($statusCode -lt 400) { "Cyan"   }
                       elseif ($statusCode -lt 500) { "Yellow" }
                       else                         { "Red"    }

        Write-Pass "HTTP request succeeded"
        Write-Host ""

        Write-Status "StatusCode"        "$statusCode"                    $statusColor
        Write-Status "StatusDescription" $statusDesc                      $statusColor
        Write-Status "Response time"     "$($sw.ElapsedMilliseconds) ms"  "White"

        # Headers
        Write-Host ""
        Write-Host ("  {0,-26}" -f "Headers:") -ForegroundColor White
        foreach ($key in $response.Headers.Keys) {
            Write-Host ("    {0,-30} {1}" -f "${key}:", $response.Headers[$key]) -ForegroundColor DarkCyan
        }

        # Images
        $imageCount = if ($response.Images) { $response.Images.Count } else { 0 }
        Write-Host ""
        Write-Host ("  {0,-26}" -f "Images:") -ForegroundColor White
        if ($imageCount -gt 0) {
            foreach ($img in $response.Images) {
                Write-Host ("    {0}" -f $img.src) -ForegroundColor DarkCyan
            }
        } else { Write-Host "    {}" -ForegroundColor DarkCyan }

        # Input Fields
        $fieldCount = if ($response.InputFields) { $response.InputFields.Count } else { 0 }
        Write-Host ""
        Write-Host ("  {0,-26}" -f "InputFields:") -ForegroundColor White
        if ($fieldCount -gt 0) {
            foreach ($field in $response.InputFields) {
                Write-Host ("    {0,-20} {1}" -f $field.name, $field.value) -ForegroundColor DarkCyan
            }
        } else { Write-Host "    {}" -ForegroundColor DarkCyan }

        # Links
        $linkCount = if ($response.Links) { $response.Links.Count } else { 0 }
        Write-Host ""
        Write-Host ("  {0,-26}" -f "Links:") -ForegroundColor White
        if ($linkCount -gt 0) {
            foreach ($link in $response.Links) {
                Write-Host ("    {0}" -f $link.href) -ForegroundColor DarkCyan
            }
        } else { Write-Host "    {}" -ForegroundColor DarkCyan }

        # Raw Content preview
        $rawPreview = if ($response.RawContent) {
            $response.RawContent.Substring(0, [math]::Min(200, $response.RawContent.Length))
        } else { "" }
        Write-Host ""
        Write-Host ("  {0,-26}" -f "RawContent (preview):") -ForegroundColor White
        Write-Host ("    $rawPreview") -ForegroundColor DarkCyan

        # Content body preview
        $contentPreview = if ($response.Content) {
            $response.Content.Substring(0, [math]::Min(200, $response.Content.Length))
        } else { "" }
        Write-Host ""
        Write-Host ("  {0,-26}" -f "Content (preview):") -ForegroundColor White
        Write-Host ("    $contentPreview") -ForegroundColor DarkCyan

        # Size & relation links
        $bodyBytes = if ($response.RawContentLength -gt 0) {
            $response.RawContentLength
        } elseif ($response.Content) {
            [System.Text.Encoding]::UTF8.GetByteCount($response.Content)
        } else { 0 }

        Write-Host ""
        Write-Status "RawContentLength" "$bodyBytes bytes" "White"
        Write-Status "RelationLink"     $(if ($response.RelationLink.Count -gt 0) { ($response.RelationLink.Keys -join ", ") } else { "{}" }) "White"

        if ($statusCode -ge 400) {
            Add-Warning "HTTP $statusCode $statusDesc returned by the endpoint."
        }

        return [PSCustomObject]@{
            StatusCode        = $statusCode
            StatusDescription = $statusDesc
            ResponseMs        = $sw.ElapsedMilliseconds
            Headers           = $response.Headers
            Images            = $response.Images
            InputFields       = $response.InputFields
            Links             = $response.Links
            RawContentLength  = $bodyBytes
            RelationLink      = $response.RelationLink
        }
    }
    catch [System.Net.WebException] {
        $sw.Stop()
        $webEx    = $_.Exception
        $httpResp = $webEx.Response -as [System.Net.HttpWebResponse]

        if ($httpResp) {
            $statusCode  = [int]$httpResp.StatusCode
            $statusDesc  = $httpResp.StatusDescription
            $statusColor = if ($statusCode -lt 500) { "Yellow" } else { "Red" }

            Write-Host ""
            Write-Status "Status"        "$statusCode $statusDesc"          $statusColor
            Write-Status "Response time" "$($sw.ElapsedMilliseconds) ms"    "White"
            Write-Host ""
            Write-Host ("  {0,-26}" -f "Response Headers:") -ForegroundColor White
            foreach ($key in $httpResp.Headers.AllKeys) {
                Write-Host ("    {0,-30} {1}" -f "${key}:", $httpResp.Headers[$key]) -ForegroundColor DarkCyan
            }

            Add-Warning "HTTP $statusCode $statusDesc returned by the endpoint."
            return [PSCustomObject]@{
                StatusCode = $statusCode
                StatusDesc = $statusDesc
                ResponseMs = $sw.ElapsedMilliseconds
                Headers    = $httpResp.Headers
                BodyBytes  = 0
            }
        }
        else {
            $errMsg = $webEx.Message
            $inner  = if ($webEx.InnerException) { $webEx.InnerException.Message } else { $null }
            Write-Fail "HTTP request FAILED: $errMsg"
            if ($inner) { Write-Info "Detail: $inner" }
            Add-Failure "HTTP request failed: $errMsg"
            return $null
        }
    }
    catch {
        $sw.Stop()
        $errMsg = $_.Exception.Message
        Write-Fail "HTTP request FAILED: $errMsg"
        Add-Failure "HTTP request failed: $errMsg"
        return $null
    }
}

#endregion

#region -- Connection Summary ----------------------------------------------------

function Write-ConnectionSummary {
    param([string]$TargetHost, [string[]]$DestinationIPs)

    Write-Section "Connection Summary"

    $srcIP = $null
    try {
        # Primary method: UDP socket (no data sent)
        $udp = [System.Net.Sockets.UdpClient]::new()
        $udp.Connect($TargetHost, 443)
        $srcIP = ($udp.Client.LocalEndPoint -as [System.Net.IPEndPoint]).Address.ToString()
        $udp.Dispose()
    }
    catch {
        try {
            # Fallback: first non-loopback IPv4
            $srcIP = (Get-NetIPAddress -AddressFamily IPv4 |
                      Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixOrigin -ne 'WellKnown' } |
                      Select-Object -First 1).IPAddress
        }
        catch {
            $srcIP = "Unable to determine"
        }
    }

    # Source hostname reverse lookup
    $srcHostname = try {
        if ($srcIP -ne "Unable to determine") {
            $h = [System.Net.Dns]::GetHostEntry($srcIP).HostName
            if ($h -and $h -ne $srcIP) { $h } else { "Not available" }
        } else { "Not available" }
    }
    catch { "Not available" }

    # Destination IP and hostname
    $destIP = if ($DestinationIPs -and $DestinationIPs.Count -gt 0) {
        $DestinationIPs[0]
    } else { "Unknown" }

    $destHostname = try {
        $h = [System.Net.Dns]::GetHostEntry($destIP).HostName
        if ($h -and $h -ne $destIP) { $h } else { $TargetHost }
    }
    catch { $TargetHost }

    Write-Pass "All stages completed successfully"
    Write-Host ""
    Write-Host "  Source" -ForegroundColor DarkGray
    Write-Status "  IP Address" $srcIP       "Green"
    Write-Status "  Hostname"   $srcHostname "Green"
    Write-Host ""
    Write-Host "  Destination" -ForegroundColor DarkGray
    Write-Status "  IP Address" $destIP       "Cyan"
    Write-Status "  Hostname"   $destHostname "Cyan"
}

#endregion

#region -- ICMP Ping -------------------------------------------------------------

function Invoke-ICMPPing {
    param([string]$TargetHost, [string]$TargetIP)

    Write-Section "ICMP Ping  ->  $TargetHost"

    try {
        $pingResults = @()
        $pingSuccess = 0
        $pingFailed  = 0
        $pingTimes   = @()
        $isIPv6      = $TargetIP -match ':'

        # Build 32-byte buffer (ASCII 'A')
        $buffer = New-Object byte[] 32
        for ($b = 0; $b -lt 32; $b++) { $buffer[$b] = 65 }

        Write-Host ""
        Write-Host ("  Pinging {0} [{1}] with 32 bytes of data:" -f $TargetHost, $TargetIP) -ForegroundColor White
        Write-Host ""

        for ($i = 1; $i -le 4; $i++) {
            $p   = New-Object System.Net.NetworkInformation.Ping
            $opt = $null
            if (-not $isIPv6) {
                $opt = New-Object System.Net.NetworkInformation.PingOptions
                $opt.Ttl = 128
                $opt.DontFragment = $true
            }

            try {
                $reply = if ($opt) {
                    $p.Send($TargetIP, 1000, $buffer, $opt)
                } else {
                    $p.Send($TargetIP, 1000, $buffer)
                }

                if ($reply.Status -eq 'Success') {
                    $pingSuccess++
                    $pingTimes += $reply.RoundtripTime
                    $ttl = if ($reply.Options -and $reply.Options.Ttl) { $reply.Options.Ttl } else { 0 }
                    $ttlDisplay = if ($ttl -gt 0) { " TTL=$ttl" } else { "" }
                    Write-Host ("    Reply from {0}: bytes=32 time={1}ms{2}" -f `
                        $reply.Address.ToString(), $reply.RoundtripTime, $ttlDisplay) -ForegroundColor Green
                } else {
                    $pingFailed++
                    $statusLabel = switch ($reply.Status.ToString()) {
                        "TimedOut"                   { "Request timed out" }
                        "DestinationHostUnreachable" { "Destination host unreachable" }
                        "DestinationNetUnreachable"  { "Destination net unreachable" }
                        "TtlExpired"                 { "TTL expired in transit" }
                        default                      { $reply.Status.ToString() }
                    }
                    Write-Host ("    {0}." -f $statusLabel) -ForegroundColor Yellow
                }
            }
            catch {
                $pingFailed++
                Write-Host ("    Request failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
            finally {
                $p.Dispose()
            }

            if ($i -lt 4) { Start-Sleep -Milliseconds 200 }
        }

        # Ping statistics
        $lossPercent = [math]::Round(($pingFailed / 4) * 100)
        $statsColor  = if ($pingFailed -eq 0) { "Green" } elseif ($pingFailed -lt 4) { "Yellow" } else { "Red" }

        Write-Host ""
        Write-Host ("  Ping statistics for {0}:" -f $TargetIP) -ForegroundColor White
        Write-Host ("    Packets: Sent = 4, Received = {0}, Lost = {1} ({2}% loss)" -f `
            $pingSuccess, $pingFailed, $lossPercent) -ForegroundColor $statsColor

        if ($pingTimes.Count -gt 0) {
            $minTime = ($pingTimes | Measure-Object -Minimum).Minimum
            $maxTime = ($pingTimes | Measure-Object -Maximum).Maximum
            $avgTime = [math]::Round(($pingTimes | Measure-Object -Average).Average, 0)
            Write-Host ""
            Write-Host "  Approximate round trip times in milli-seconds:" -ForegroundColor White
            Write-Host ("    Minimum = {0}ms, Maximum = {1}ms, Average = {2}ms" -f `
                $minTime, $maxTime, $avgTime) -ForegroundColor Green
        }

        Write-Host ""
        if ($pingFailed -eq 4) {
            Write-Info "All ICMP packets lost - ping is likely blocked by firewall or host policy"
            Write-Info "This does not affect HTTPS connectivity (TCP and TLS checks above are authoritative)"
        } elseif ($lossPercent -gt 0) {
            Add-Warning "ICMP ping to $TargetIP shows $lossPercent% packet loss. Network may be unstable."
        } else {
            Write-Pass "ICMP ping successful - no packet loss"
        }
    }
    catch {
        Write-Info "ICMP ping unavailable: $($_.Exception.Message)"
        Write-Info "This does not affect HTTPS connectivity results"
    }
}

#endregion

#region -- Entry Point -----------------------------------------------------------

if ($Uri -notmatch '^https?://') { $Uri = "https://$Uri" }

try {
    $parsedUri  = [System.Uri]$Uri
    $targetHost = $parsedUri.Host
    if ($parsedUri.Port -ne -1) { $Port = $parsedUri.Port }
}
catch {
    Write-Host ""
    Write-Host "  [FAIL] Invalid URI: $Uri" -ForegroundColor Red
    Write-Host "  [INFO] Ensure the URI is a valid HTTPS address e.g. https://example.com" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "  SSL / TLS Connectivity Check  v2.8 by Hashim Hilal" -ForegroundColor Cyan
Write-Host "  Target : $targetHost : $Port"
Write-Host "  Run at : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Stage 1 - DNS
$dns = $null
try {
    $dns = Resolve-TargetHost -Hostname $targetHost
}
catch {
    Write-GracefulExit -Stage "Stage 1 (DNS Resolution)" -Reason $_.Exception.Message
    exit 1
}

if (-not $dns.Success) {
    Write-Host ""; Write-Fail "Halted - DNS resolution failed."; Write-Host ""; exit 1
}

# Stage 2 - TCP
$reachable = $false
try {
    $reachable = Test-TCPReachability `
        -TargetHost     $targetHost `
        -Port           $Port `
        -TimeoutMs      $TimeoutMs `
        -TraceRouteHops $TraceRouteHops `
        -SkipTraceroute $SkipTraceroute.IsPresent `
        -RetryCount     $RetryCount `
        -RetryDelayMs   $RetryDelayMs
}
catch {
    Write-GracefulExit -Stage "Stage 2 (TCP Reachability)" -Reason $_.Exception.Message
    exit 2
}

if (-not $reachable) {
    Write-Host ""; Write-Fail "Halted - TCP connection failed."; Write-Host ""; exit 2
}

# Stage 3a - TLS Handshake & Certificate Inspection
$result = $null
try {
    $result = Get-SSLCertificateInfo `
        -TargetHost     $targetHost `
        -Port           $Port `
        -TimeoutMs      $TimeoutMs `
        -AuditLegacyTls:$AuditLegacyTls
}
catch {
    Write-GracefulExit -Stage "Stage 3a (TLS Inspection)" -Reason $_.Exception.Message
    exit 3
}

# Stage 3b - Real-World Trust Validation
$trusted = $false
try {
    $trusted = Test-RealWorldTrust `
        -TargetHost $targetHost `
        -Port       $Port `
        -TimeoutMs  $TimeoutMs
}
catch {
    Write-GracefulExit -Stage "Stage 3b (Trust Validation)" -Reason $_.Exception.Message
    exit 3
}

# Stage 3c - HTTP Response (only if Stage 3b passed)
$httpResult = $null
try {
    if ($trusted) {
        $httpResult = Invoke-HTTPResponse `
            -TargetUri $Uri `
            -TimeoutMs $TimeoutMs
    } else {
        Write-Section "Stage 3c - HTTP Response"
        Write-Info "Skipped - real-world trust validation failed. Fix the certificate trust issue first."
    }
}
catch {
    Write-GracefulExit -Stage "Stage 3c (HTTP Response)" -Reason $_.Exception.Message
}

# Connection Summary - only when all stages passed with no failures
if ($script:FailLog.Count -eq 0 -and $trusted) {
    try {
        Write-ConnectionSummary -TargetHost $targetHost -DestinationIPs $dns.ResolvedIPs
    }
    catch {
        Write-Section "Connection Summary"
        Write-Info "Summary unavailable: $($_.Exception.Message)"
    }
}

# ICMP Ping - separate stage, always runs if TCP succeeded
try {
    $pingDestIP = if ($dns.ResolvedIPs -and $dns.ResolvedIPs.Count -gt 0) {
        $dns.ResolvedIPs[0]
    } else { $targetHost }
    Invoke-ICMPPing -TargetHost $targetHost -TargetIP $pingDestIP
}
catch {
    Write-Section "ICMP Ping"
    Write-Info "Ping stage failed unexpectedly: $($_.Exception.Message)"
}

# Warnings - only shown when there are no failures
if ($script:FailLog.Count -eq 0) {
    Write-Section "Warnings"
    if ($script:WarningLog.Count -gt 0) {
        $i = 1
        foreach ($w in $script:WarningLog) {
            Write-Host ("  {0,2}. {1}" -f $i, $w) -ForegroundColor Yellow
            $i++
        }
    } else {
        Write-Pass "No warnings - all checks passed cleanly"
    }
}

# Total runtime
$totalRuntime = (Get-Date) - $scriptStartTime
Write-Host ""
Write-Host ("  Total runtime: {0:F2} seconds" -f $totalRuntime.TotalSeconds) -ForegroundColor DarkGray
Write-Host ""

#endregion
