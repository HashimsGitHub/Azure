<#
.SYNOPSIS
    Checks HTTPS / SSL connectivity, TLS versions, and certificate health for a given endpoint.

.DESCRIPTION
    sslCheck.ps1 performs a non-intrusive SSL/TLS inspection of an HTTPS endpoint.
    It validates connectivity, negotiates a real TLS handshake, inspects the
    SSL certificate, and optionally audits supported TLS protocol versions.

    The script works in standard networks as well as environments using TLS
    interception proxies (e.g. Zscaler). When run behind such proxies, the TLS
    details reflect the client-to-proxy connection.

    No HTTP content is downloaded. This is a read-only security and connectivity check.

.PARAMETER Uri
    The HTTPS endpoint to test.
    Can be a fully-qualified domain name, hostname, or IP address.

.PARAMETER Port
    The TCP port to connect to.
    Default is 443.

.PARAMETER TimeoutMs
    Connection timeout in milliseconds.
    Default is 5000 ms (5 seconds).

.PARAMETER AuditLegacyTls
    Enables audit mode to detect which TLS versions the endpoint (or proxy)
    accepts, including legacy TLS 1.0 and TLS 1.1.

    This mode performs isolated, safe TLS probes and does not affect the primary
    connectivity check.

.OUTPUTS
    PSCustomObject containing:
      - Negotiated TLS version
      - Supported TLS versions (if audit enabled)
      - Certificate subject, issuer, expiry, and SANs
      - Legacy TLS detection flag
      - Connection timing

.EXAMPLE
    Basic connectivity and certificate check:

        .\sslCheck.ps1 -Uri https://example.com

.EXAMPLE
    Connectivity check with legacy TLS audit:

        .\sslCheck.ps1 -Uri https://example.com -AuditLegacyTls

.EXAMPLE
    Test a custom port with longer timeout:

        .\sslCheck.ps1 -Uri https://example.com -Port 8443 -TimeoutMs 10000

.NOTES
    Author: Hashim Hilal
    Script Name: sslCheck.ps1

    IMPORTANT:
    - Negotiated TLS reflects the actual protocol used by the client.
    - Supported TLS reflects which protocols the endpoint or proxy accepts.
    - When running behind TLS interception (e.g. Zscaler), TLS results
      represent the client-to-proxy connection, not the destination server.

#>

param (
    [Parameter(Mandatory)]
    [string]$Uri,

    [int]$Port = 443,
    [int]$TimeoutMs = 5000,

    [switch]$AuditLegacyTls
)


# TLS support test (safe / isolated)

function Test-TlsSupport {
    param (
        [string]$TargetHost,
        [int]$Port,
        [string]$Protocol,
        [int]$TimeoutMs
    )

    $tcp = $null
    $ssl = $null

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout    = $TimeoutMs
        $tcp.Connect($TargetHost, $Port)

        $ssl = New-Object System.Net.Security.SslStream(
            $tcp.GetStream(),
            $false,
            ({ $true })
        )

        # Convert TLS protocol string → enum
        $enumProtocol = [System.Security.Authentication.SslProtocols]::$Protocol

        $ssl.AuthenticateAsClient($TargetHost, $null, $enumProtocol, $false)

        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Dispose() }
    }
}


# Main SSL inspection

function Get-SSLCertificateInfo {
    param (
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs,
        [switch]$AuditLegacyTls
    )

    $tcpClient = $null
    $sslStream = $null

    try {
        
        # TCP connectivity
        
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $task = $tcpClient.ConnectAsync($TargetHost, $Port)
        if (-not $task.Wait($TimeoutMs)) {
            throw "Connection timeout after $TimeoutMs ms"
        }

        $sw.Stop()

        
        # TLS handshake (safe, OS‑negotiated)
        
        $sslStream = New-Object System.Net.Security.SslStream(
            $tcpClient.GetStream(),
            $false,
            ({ $true })  # allow inspection of self‑signed / proxy certs
        )

        $sslStream.AuthenticateAsClient($TargetHost)

        if (-not $sslStream.RemoteCertificate) {
            throw "No SSL certificate presented"
        }

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
            $sslStream.RemoteCertificate

        
        # Negotiated TLS detection
        
        $rawProto = $sslStream.SslProtocol.ToString()

        $tlsVersion = switch ($rawProto) {
            "Tls"   { "TLS1.0" }
            "Tls11" { "TLS1.1" }
            "Tls12" { "TLS1.2" }
            "Tls13" { "TLS1.3" }
            default { $rawProto.ToUpper() }
        }

        
        # Crypto
        
        $cipherName = $sslStream.CipherAlgorithm.ToString().ToUpper()
        $hashName   = $sslStream.HashAlgorithm.ToString().ToUpper()

        
        # SAN extraction
        
        $sanExtension = $cert.Extensions |
            Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }

        $sans = if ($sanExtension) {
            ($sanExtension.Format($true) -split "`r?`n" |
                ForEach-Object { $_ -replace '^DNS Name=|^IP Address=', '' }
            ) -join "; "
        } else { "NONE" }

        
        # Certificate chain
        
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = "NoCheck"
        $chain.ChainPolicy.VerificationFlags = "IgnoreWrongUsage"

        $chainIsValid = $chain.Build($cert)

        $rootCA = if ($chain.ChainElements.Count -gt 0) {
            $chain.ChainElements[-1].Certificate.Subject
        } else { "UNKNOWN" }

        if ($cert.Subject -eq $cert.Issuer) {
            $certificateType = "SELF-SIGNED"
        }
        elseif ($rootCA -match '(?i)DIGICERT|GLOBALSIGN|SECTIGO|ENTRUST|LET.?S ENCRYPT|GODADDY|VERISIGN|GEOTRUST|AMAZON|MICROSOFT|ZSCALER') {
            $certificateType = "PUBLIC / INTERCEPTING CA"
        }
        else {
            $certificateType = "PRIVATE / INTERNAL CA"
        }

        
        # Legacy TLS audit
        
        $supportedTls = @()
        $legacyTlsEnabled = $false

        if ($AuditLegacyTls) {
            if (Test-TlsSupport $TargetHost $Port "Tls"   $TimeoutMs) { $supportedTls += "TLS1.0" }
            if (Test-TlsSupport $TargetHost $Port "Tls11" $TimeoutMs) { $supportedTls += "TLS1.1" }
            if (Test-TlsSupport $TargetHost $Port "Tls12" $TimeoutMs) { $supportedTls += "TLS1.2" }

            if ("Tls13" -in [System.Security.Authentication.SslProtocols].GetEnumNames()) {
                if (Test-TlsSupport $TargetHost $Port "Tls13" $TimeoutMs) {
                    $supportedTls += "TLS1.3"
                }
            }

            $legacyTlsEnabled =
                ($supportedTls -contains "TLS1.0") -or
                ($supportedTls -contains "TLS1.1")
        }

        
        # Expiry calculation
        
        $daysRemaining = ($cert.NotAfter - (Get-Date)).Days

        # EXPIRY WARNING
        if ($daysRemaining -lt 0) {
            Write-Warning "WARNING: Certificate expired $([math]::Abs($daysRemaining)) days ago"
        }
        elseif ($daysRemaining -lt 30) {
            Write-Warning "WARNING: Certificate expires in $daysRemaining days"
        }

        
        # Output
        
        return [PSCustomObject]@{
            Host              = $TargetHost
            Port              = $Port
            ConnectionTimeMs  = $sw.ElapsedMilliseconds

            NegotiatedTLS     = $tlsVersion
            RawSslProtocol    = $rawProto
            SupportedTLS      = $supportedTls
            LegacyTLSEnabled  = $legacyTlsEnabled

            CipherAlgorithm   = $cipherName
            CipherStrength    = $sslStream.CipherStrength
            HashAlgorithm     = $hashName

            Subject           = $cert.Subject
            Issuer            = $cert.Issuer
            NotBefore         = $cert.NotBefore
            NotAfter          = $cert.NotAfter
            DaysRemaining     = $daysRemaining

            SANs              = $sans

            CertificateValid  = $chainIsValid
            CertificateType   = $certificateType
            RootCA            = $rootCA
        }
    }
    finally {
        if ($sslStream) { $sslStream.Dispose() }
        if ($tcpClient) { $tcpClient.Dispose() }
    }
}


# URI normalization & execution

if ($Uri -notmatch '^https?://') {
    $Uri = "https://$Uri"
}

$parsedUri = [System.Uri]$Uri
$targetHost = $parsedUri.Host
if ($parsedUri.Port -ne -1) { $Port = $parsedUri.Port }

$result = Get-SSLCertificateInfo `
    -TargetHost $targetHost `
    -Port $Port `
    -TimeoutMs $TimeoutMs `
    -AuditLegacyTls:$AuditLegacyTls

$result | Format-List *
