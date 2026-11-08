"""Build a one-click Windows installer: a .bat with the addon zip embedded.

Usage:  python tools/make_installer.py [output.bat]
The .bat finds the WoW Forever folder (common paths, Battle.net registry, or a folder picker),
replaces Interface\\AddOns\\Duel and tells the player to restart WoW.
"""
import base64
import io
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BAT_HEAD = r"""@echo off
title Duel Ladder installer
set "DUEL_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = Get-Content -LiteralPath $env:DUEL_SELF -Raw; $m = '::' + 'PS::'; Invoke-Expression ($t.Substring($t.IndexOf($m) + $m.Length).Split([string[]]@('::' + 'DATA::'), 'None')[0])"
if not defined DUEL_NOPAUSE pause
exit /b
"""

PS = r"""
$ErrorActionPreference = 'Stop'
function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
Say ''
Say '  DUEL LADDER - ranked duels for WoW Forever' 'Yellow'
Say '  ==========================================' 'Yellow'
Say ''
try {
    $text = Get-Content -LiteralPath $env:DUEL_SELF -Raw
    $marker = '::' + 'DATA::'
    $b64 = $text.Substring($text.LastIndexOf($marker) + $marker.Length).Trim()
    $bytes = [Convert]::FromBase64String($b64)

    # Find WoW Forever (the folder that holds Wow.exe and Interface).
    $wow = $env:DUEL_TARGET
    if (-not $wow) {
        $cands = New-Object System.Collections.Generic.List[string]
        foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
                         'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft') {
            try {
                $p = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
                if ($p) { $cands.Add((Join-Path (Split-Path ($p.TrimEnd('\')) -Parent) '_forever_')) }
            } catch {}
        }
        foreach ($d in Get-PSDrive -PSProvider FileSystem) {
            foreach ($sub in 'Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft',
                             'World of Warcraft', 'Games\World of Warcraft', 'Battle.net\World of Warcraft',
                             'Blizzard\World of Warcraft', 'Games\Blizzard\World of Warcraft') {
                $cands.Add((Join-Path $d.Root (Join-Path $sub '_forever_')))
            }
        }
        foreach ($c in $cands) {
            if ((Test-Path -LiteralPath (Join-Path $c 'Wow.exe')) -or (Test-Path -LiteralPath (Join-Path $c 'Interface'))) { $wow = $c; break }
        }
    }
    if (-not $wow) {
        Say 'Could not find WoW Forever automatically.' 'Yellow'
        Say 'Pick your "_forever_" folder (inside your World of Warcraft folder).' 'Yellow'
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select the _forever_ folder inside World of Warcraft'
        if ($dlg.ShowDialog() -ne 'OK') { throw 'No folder selected.' }
        $wow = $dlg.SelectedPath
        if ((Split-Path $wow -Leaf) -ieq 'World of Warcraft' -and (Test-Path (Join-Path $wow '_forever_'))) { $wow = Join-Path $wow '_forever_' }
    }
    Say ("WoW Forever: " + $wow)
    $addons = Join-Path $wow 'Interface\AddOns'
    New-Item -ItemType Directory -Force -Path $addons | Out-Null

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('DuelLadder_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'Duel.zip'
    [IO.File]::WriteAllBytes($zip, $bytes)
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $dest = Join-Path $addons 'Duel'
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $tmp 'Duel') -Destination $dest -Recurse -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath (Join-Path $dest 'Duel.toc'))) { throw 'Copy failed.' }

    Say ''
    Say ('Installed Duel Ladder VERSION to ' + $dest) 'Green'
    Say ''
    if (Get-Process -Name 'Wow' -ErrorAction SilentlyContinue) {
        Say 'WoW is running: EXIT WoW COMPLETELY and start it again (a /reload is not enough the first time).' 'Yellow'
    } else {
        Say 'Start WoW Forever. At character select, check "Duel Ladder" is ticked under AddOns.'
    }
    Say 'In game: /ladder to open it, /ladder help for commands.'
} catch {
    Say ''
    Say ('Install failed: ' + $_.Exception.Message) 'Red'
    Say 'If it says access denied, right-click the installer and choose "Run as administrator".' 'Yellow'
}
Say ''
"""


def main():
    version = "?"
    for line in open(os.path.join(ROOT, "Duel", "Duel.toc"), encoding="utf-8"):
        if line.startswith("## Version:"):
            version = line.split(":", 1)[1].strip()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(os.path.join(ROOT, "Duel")):
            for f in files:
                full = os.path.join(folder, f)
                z.write(full, os.path.relpath(full, ROOT))
    b64 = base64.b64encode(buf.getvalue()).decode("ascii")
    lines = [b64[i:i + 120] for i in range(0, len(b64), 120)]
    body = BAT_HEAD + "::PS::" + PS.replace("VERSION", version) + "::DATA::\n" + "\n".join(lines) + "\n"
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "dist", "Install Duel Ladder.bat")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="ascii", newline="\r\n") as fh:
        fh.write(body)
    print("wrote", out, len(body), "bytes, version", version)


if __name__ == "__main__":
    main()
