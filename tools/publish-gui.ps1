# photo-frame publisher - a small window for publishing updates without typing git commands.
# Start it with "Publish.cmd" (double-click). Requires Git; uses Windows PowerShell and WinForms only.
param(
    [switch]$NoGui,          # load the functions only (used for testing)
    [string]$TestSnapshot    # open, save a picture of the window to this path, close (used for testing)
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Utf8 = New-Object System.Text.UTF8Encoding($false)   # UTF-8 without BOM

$Repo = Split-Path -Parent $PSScriptRoot
$Docs = Join-Path $Repo 'docs'
$IndexPath = Join-Path $Docs 'index.html'
$VersionPath = Join-Path $Docs 'version.json'
$BetaDir = Join-Path $Docs 'beta'
$BetaIndex = Join-Path $BetaDir 'index.html'
$BetaVersion = Join-Path $BetaDir 'version.json'
$GradlePath = Join-Path $Repo 'android\app\build.gradle'
$ApkFolder = Join-Path (Split-Path -Parent $Repo) 'apk'

$script:LogBox = $null

# Who commits are credited to: 'bot' = photo-frame push-o-matic (a made-up name, no GitHub account), 'me' = your Git name.
$BotName = 'photo-frame push-o-matic'
$BotMail = 'push-o-matic@photo-frame.local'
$PrefsPath = Join-Path $env:APPDATA 'photo-frame-publisher.json'
$script:CommitAs = 'bot'
try { if (Test-Path $PrefsPath) { $p = Get-Content $PrefsPath -Raw | ConvertFrom-Json; if ($p.commitAs -in @('bot', 'me')) { $script:CommitAs = $p.commitAs } } } catch { }
function Save-Prefs { try { @{ commitAs = $script:CommitAs } | ConvertTo-Json | Set-Content -Path $PrefsPath -Encoding ascii } catch { } }
function Log([string]$text) {
    if ($script:LogBox) {
        $script:LogBox.AppendText(($text -replace "`r?`n", "`r`n") + "`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    } else { Write-Host $text }
}

# ---------------------------------------------------------------- git helpers
function Invoke-Git([string[]]$GitArgs) {
    Log ('> git ' + ($GitArgs -join ' '))
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    # git writes normal progress to stderr; turn those records into plain text lines
    $out = & git -C $Repo @GitArgs 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } } | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    $clean = ($out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch 'LF will be replaced by CRLF' }) -join "`n"
    if ($clean.Trim()) { Log $clean.TrimEnd() }
    return $code
}
function Get-GitText([string[]]$GitArgs) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & git -C $Repo @GitArgs 2>$null | Out-String
    $ErrorActionPreference = $old
    return $out.Trim()
}
function Get-Identity {
    if ($script:CommitAs -eq 'bot') { return @("user.name=$BotName", "user.email=$BotMail") }
    $name = Get-GitText @('config', 'user.name')
    $mail = Get-GitText @('config', 'user.email')
    $owner = (Get-SiteInfo).Owner
    if (-not $name) { $name = $owner }
    if (-not $mail) { $mail = "$owner@users.noreply.github.com" }
    return @("user.name=$name", "user.email=$mail")
}
function Get-SiteInfo {
    $url = Get-GitText @('remote', 'get-url', 'origin')
    if ($url -match 'github\.com[:/]([^/]+)/([^/.]+)') {
        return [pscustomobject]@{ Owner = $Matches[1]; Name = $Matches[2]; Site = "https://$($Matches[1]).github.io/$($Matches[2])/"; GitHub = "https://github.com/$($Matches[1])/$($Matches[2])" }
    }
    return [pscustomobject]@{ Owner = 'unknown'; Name = 'photo-frame'; Site = ''; GitHub = '' }
}
function Commit-And-Push([string[]]$Paths, [string]$Message) {
    if ($Paths) { if ((Invoke-Git (@('add', '--') + $Paths)) -ne 0) { throw 'git add failed' } }
    else { if ((Invoke-Git @('add', '-A')) -ne 0) { throw 'git add failed' } }
    $staged = Get-GitText @('diff', '--cached', '--name-only')
    if (-not $staged) { Log 'Nothing to commit - no changes.'; return $false }
    $id = Get-Identity
    if ((Invoke-Git @('-c', $id[0], '-c', $id[1], 'commit', '-m', $Message)) -ne 0) { throw 'git commit failed' }
    Log ("Committed as: " + $id[0].Substring(10))
    Log 'Pushing to GitHub...'
    if ((Invoke-Git @('push')) -ne 0) { throw 'git push failed - check your internet connection or GitHub login' }
    Log 'Pushed.'
    return $true
}

# ---------------------------------------------------------------- file helpers
function Read-Text($path) { return [IO.File]::ReadAllText($path, $Utf8) }
function Write-Text($path, $text) { [IO.File]::WriteAllText($path, $text, $Utf8) }
function Get-Versions {
    $j = (Read-Text $VersionPath) | ConvertFrom-Json
    return $j
}
function Set-VersionJson([string]$Web, [string]$Apk) {
    $j = Get-Versions
    if ($Web) { $j.web = $Web }
    if ($Apk) { $j.apk = $Apk }
    $text = "{`n  `"web`": `"$($j.web)`",`n  `"apk`": `"$($j.apk)`",`n  `"apkUrl`": `"$($j.apkUrl)`"`n}`n"
    Write-Text $VersionPath $text
}
function Get-AppVersion {
    $g = Read-Text $GradlePath
    if ($g -match 'versionName "([^"]+)"') { return $Matches[1] }
    return '?'
}
function Suggest-WebVersion([string]$FilePath) {
    $name = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ($name -match 'v(\d+)\.(\d+)') { return "$($Matches[1]).$($Matches[2])" }
    if ($name -match 'v(\d+)') { return "$($Matches[1]).0" }
    $cur = (Get-Versions).web
    if ($cur -match '^(\d+)\.(\d+)$') { return "$($Matches[1]).$([int]$Matches[2] + 1)" }
    return $cur
}
function Bump-Patch([string]$v) {
    if ($v -match '^(\d+)\.(\d+)\.(\d+)$') { return "$($Matches[1]).$($Matches[2]).$([int]$Matches[3] + 1)" }
    return $v
}

function Get-BetaVersion { if (Test-Path $BetaVersion) { return ((Read-Text $BetaVersion) | ConvertFrom-Json).web } return '' }
# Writes docs/beta/ (the page, its version.json and copies of the files the page needs)
function Write-Beta([string]$Html, [string]$Version) {
    if (-not (Test-Path $BetaDir)) { New-Item -ItemType Directory -Path $BetaDir | Out-Null }
    Write-Text $BetaIndex $Html
    $j = Get-Versions
    Write-Text $BetaVersion "{`n  `"web`": `"$Version`",`n  `"apk`": `"$($j.apk)`",`n  `"apkUrl`": `"$($j.apkUrl)`"`n}`n"
    foreach ($f in @('sw.js', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'icon-maskable-512.png')) {
        $src = Join-Path $Docs $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $BetaDir $f) -Force }
    }
}

# Prepares docs/index.html + docs/version.json (or docs/beta/) from a frame file. Returns a short summary.
function Prepare-Frame([string]$Source, [string]$Version, [bool]$Beta = $false) {
    if (-not (Test-Path $Source)) { throw "File not found: $Source" }
    if ($Version -notmatch '^\d+(\.\d+)*$') { throw "The version should look like 41.0 or 41.1" }
    $html = Read-Text $Source
    if ($html -notmatch "window\.WEB_VERSION = '[^']*';") {
        throw "This file has no 'window.WEB_VERSION' line, so it is older than v40 and not app-aware. Publishing it would break the Android app's features."
    }
    $html = [regex]::Replace($html, "window\.WEB_VERSION = '[^']*';", "window.WEB_VERSION = '$Version';", 1)
    if ($html -notmatch 'rel="manifest"') {
        $links = "`n<link rel=`"manifest`" href=`"manifest.webmanifest`">`n<link rel=`"icon`" href=`"icon-192.png`">`n<link rel=`"apple-touch-icon`" href=`"icon-192.png`">"
        $html = [regex]::Replace($html, '(<title>[^<]*</title>)', ('$1' + $links), 1)
    }
    if ($Beta) {
        Write-Beta $html $Version
        return "docs/beta/ updated from $([IO.Path]::GetFileName($Source)), beta version $Version"
    }
    Write-Text $IndexPath $html
    Set-VersionJson -Web $Version
    return "docs/index.html updated from $([IO.Path]::GetFileName($Source)), web version $Version"
}

# Copies the beta frame to everyone
function Promote-Beta {
    if (-not (Test-Path $BetaIndex)) { throw 'There is no beta version to promote yet.' }
    $v = Get-BetaVersion
    Copy-Item $BetaIndex $IndexPath -Force
    Set-VersionJson -Web $v
    return $v
}

function Wait-Live([string]$Version, [int]$Seconds = 150, [bool]$Beta = $false) {
    $site = (Get-SiteInfo).Site
    if ($Beta -and $site) { $site = $site + 'beta/' }
    if (-not $site) { return }
    Log "Waiting for the website to show version $Version (usually under a minute)..."
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri ($site + 'version.json?nc=' + [guid]::NewGuid()) -TimeoutSec 15
            $j = $r.Content | ConvertFrom-Json
            if ($j.web -eq $Version) { Log "LIVE: $site now serves version $Version. The tablet picks it up at its next quiet moment (or reopen the app)."; return }
        } catch { }
        for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Milliseconds 500; [System.Windows.Forms.Application]::DoEvents() }
    }
    Log 'Not live yet - GitHub can take a few minutes sometimes. Use "Check live version" later.'
}

if ($NoGui) { return }

# ================================================================ window
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$site = Get-SiteInfo
$form = New-Object System.Windows.Forms.Form
$form.Text = 'photo-frame publisher'
$form.Size = New-Object System.Drawing.Size(860, 720)
$form.MinimumSize = New-Object System.Drawing.Size(760, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$iconPath = Join-Path $Docs 'icon-192.png'
if (Test-Path $iconPath) { try { $bmp = [System.Drawing.Bitmap]::FromFile($iconPath); $form.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon()) } catch { } }

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 12)
$tabs.Size = New-Object System.Drawing.Size(820, 340)
$tabs.Anchor = 'Top,Left'
$form.Controls.Add($tabs)

function New-Label($parent, $text, $x, $y, $w = 160) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, ($y + 4)); $l.Size = New-Object System.Drawing.Size($w, 24); $parent.Controls.Add($l); return $l
}
function New-Box($parent, $x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox; $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, 26); $t.Anchor = 'Top,Left'; $parent.Controls.Add($t); return $t
}
function New-Button($parent, $text, $x, $y, $w = 200, $h = 34) {
    $b = New-Object System.Windows.Forms.Button; $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h); $parent.Controls.Add($b); return $b
}
function Busy([bool]$on) { $form.UseWaitCursor = $on; $tabs.Enabled = -not $on; [System.Windows.Forms.Application]::DoEvents() }
function Fail($e) { Log ('ERROR: ' + $e.Exception.Message); [System.Windows.Forms.MessageBox]::Show($e.Exception.Message, 'photo-frame publisher', 'OK', 'Error') | Out-Null }

# ---------------- tab 0: guide (plain steps for the usual jobs)
$t0 = New-Object System.Windows.Forms.TabPage; $t0.Text = 'Guide'; $tabs.TabPages.Add($t0)
$guide = New-Object System.Windows.Forms.RichTextBox
$guide.ReadOnly = $true; $guide.BorderStyle = 'None'; $guide.BackColor = [System.Drawing.Color]::White
$guide.Location = New-Object System.Drawing.Point(12, 8); $guide.Size = New-Object System.Drawing.Size(786, 292)
$guide.ScrollBars = 'Vertical'; $guide.DetectUrls = $false; $guide.TabStop = $false
$t0.Controls.Add($guide)
$gBold = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$gText = New-Object System.Drawing.Font('Segoe UI', 10)
function Add-Guide([string]$Text, [bool]$Heading = $false) {
    $guide.SelectionStart = $guide.TextLength
    $guide.SelectionFont = if ($Heading) { $gBold } else { $gText }
    $guide.SelectionColor = if ($Heading) { [System.Drawing.Color]::FromArgb(30, 60, 130) } else { [System.Drawing.Color]::Black }
    $guide.AppendText($(if ($Heading -and $guide.TextLength) { "`n" } else { '' }) + $Text + "`n")
}
Add-Guide 'WHICH TAB DO I NEED?' $true
Add-Guide '- You have a new photo-frame(vNN).html  ->  Frame update'
Add-Guide '- You (or Claude) changed the README or other files  ->  Other changes'
Add-Guide '- The Android app itself changed (the android folder; Claude will tell you)  ->  App release'
Add-Guide 'Not sure? Open "Other changes": it lists every file that changed.'

Add-Guide 'PUBLISHING A NEW FRAME VERSION (the usual job)' $true
Add-Guide '1. Frame update tab -> Browse... -> pick the new photo-frame(vNN).html. The version fills itself in (v43 -> 43.0, v43.1 -> 43.1).'
Add-Guide '2. "Publish to": Beta. Press "Publish frame update" and wait until the log says LIVE.'
Add-Guide '3. Check it on your tablet (it gets beta updates). It reloads by itself at a quiet moment, or close and reopen the app.'
Add-Guide '4. Looks good? Press "Promote beta to everyone". Done.'
Add-Guide 'A tiny fix or in a hurry? Choose "Everyone" in step 2 and skip steps 3 and 4.'

Add-Guide 'VERSION NUMBERS' $true
Add-Guide 'Only bug fixes -> add .1 (43.1, 43.2 ...). Bigger changes -> next number (44.0). The same as your file names.'

Add-Guide 'OTHER CHANGES (README, this publisher, ...)' $true
Add-Guide '1. Edited the README on github.com? Press "Get latest from GitHub" first.'
Add-Guide '2. Other changes tab -> "Refresh list" to see what changed.'
Add-Guide '3. Write a short description -> "Commit & push all".'

Add-Guide 'RELEASING A NEW APP VERSION (rare)' $true
Add-Guide 'Only when the Android app itself changed. The website frame does not need this.'
Add-Guide '1. App release tab: the next version is suggested (1.3.0 -> 1.3.1).'
Add-Guide '2. Release notes in your usual style, for example:'
Add-Guide '      **Fixed**'
Add-Guide '      - A bug where ...'
Add-Guide '      **Added**'
Add-Guide '      - ...'
Add-Guide '3. "Release app update". This also sends any other changed files. GitHub builds the APK in about 3 minutes, then tablets show "App update available".'
Add-Guide '4. "Download latest APK to PC" if you want your own copy.'

Add-Guide 'THE BUTTONS AT THE BOTTOM' $true
Add-Guide '- Open website: the frame in your browser.   - Open GitHub: the repository.'
Add-Guide '- Check live version: what the website serves right now.'
Add-Guide '- Get latest from GitHub: brings in changes made somewhere else (for example README edits on github.com).'
Add-Guide '- Commit as: the name shown on GitHub for your changes (photo-frame push-o-matic, or you).'

Add-Guide 'IF SOMETHING GOES WRONG' $true
Add-Guide '- "Nothing to commit": nothing changed since the last publish.'
Add-Guide '- "git push failed": press "Get latest from GitHub", then try again. Still failing? Check the internet connection.'
Add-Guide '- "Not live yet": GitHub is slow sometimes. Press "Check live version" a few minutes later.'
Add-Guide '- A new version breaks the tablet: publish the previous photo-frame(vNN).html again to Everyone, with a higher number (for example 43.2).'
Add-Guide '- Stuck? The black box below logs every step. Copy it and send it to Claude.'
$guide.SelectionStart = 0; $guide.ScrollToCaret()

# ---------------- tab 1: frame update
$t1 = New-Object System.Windows.Forms.TabPage; $t1.Text = 'Frame update'; $tabs.TabPages.Add($t1)
New-Label $t1 'New frame file:' 14 18 | Out-Null
$fileBox = New-Box $t1 180 18 470
$browse = New-Button $t1 'Browse...' 664 16 120 30
New-Label $t1 'Web version:' 14 60 | Out-Null
$verBox = New-Box $t1 180 60 120; $verBox.Anchor = 'Top,Left'
$curWebLbl = New-Label $t1 '' 316 60 460
New-Label $t1 'Description:' 14 102 | Out-Null
$msgBox = New-Box $t1 180 102 604
New-Label $t1 'Publish to:' 14 144 | Out-Null
$chanBox = New-Object System.Windows.Forms.ComboBox; $chanBox.DropDownStyle = 'DropDownList'
$chanBox.Location = New-Object System.Drawing.Point(180, 142); $chanBox.Size = New-Object System.Drawing.Size(420, 28)
[void]$chanBox.Items.Add('Beta - only frames with "Get beta updates" on')
[void]$chanBox.Items.Add('Everyone')
$chanBox.SelectedIndex = 0; $t1.Controls.Add($chanBox)
$hint = New-Label $t1 'Picks your photo-frame(vNN).html, sets the version numbers to match, keeps the app manifest lines, and publishes it. Try new versions on beta first, then press "Promote beta to everyone".' 14 182 770
$hint.Size = New-Object System.Drawing.Size(770, 44); $hint.ForeColor = [System.Drawing.Color]::DimGray
$pubBtn = New-Button $t1 'Publish frame update' 14 232 240 40
$pubBtn.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$promBtn = New-Button $t1 'Promote beta to everyone' 270 232 240 40
$betaLbl = New-Label $t1 '' 526 242 260

$browse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Frame files (*.html)|*.html'
    $dlg.InitialDirectory = Split-Path -Parent $Repo
    if ($dlg.ShowDialog() -eq 'OK') {
        $fileBox.Text = $dlg.FileName
        $verBox.Text = Suggest-WebVersion $dlg.FileName
        $msgBox.Text = 'Frame ' + [IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
    }
})
$pubBtn.Add_Click({
    try {
        if (-not $fileBox.Text) { throw 'Choose the new frame file first (Browse...).' }
        $v = $verBox.Text.Trim()
        $beta = $chanBox.SelectedIndex -eq 0
        $cur = if ($beta) { Get-BetaVersion } else { (Get-Versions).web }
        if ($v -eq $cur) {
            $a = [System.Windows.Forms.MessageBox]::Show("The website already has web version $cur.`nPublish anyway with the same number? (The tablet will then only pick it up at its nightly reload.)", 'photo-frame publisher', 'YesNo', 'Question')
            if ($a -ne 'Yes') { return }
        }
        Busy $true
        Log (Prepare-Frame $fileBox.Text $v $beta)
        $msg = if ($msgBox.Text.Trim()) { $msgBox.Text.Trim() } else { "Frame $v" }
        if ($beta) { $msg = "$msg (beta)" }
        $paths = if ($beta) { @('docs/beta') } else { @('docs/index.html', 'docs/version.json') }
        if (Commit-And-Push $paths $msg) { Wait-Live $v 150 $beta }
        Refresh-All
    } catch { Fail $_ } finally { Busy $false }
})
$promBtn.Add_Click({
    try {
        $bv = Get-BetaVersion
        if (-not $bv) { throw 'There is no beta version to promote yet.' }
        $a = [System.Windows.Forms.MessageBox]::Show("Publish beta version $bv to everyone?", 'photo-frame publisher', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        Busy $true
        $v = Promote-Beta
        Log "Beta version $v copied to docs/index.html"
        if (Commit-And-Push @('docs/index.html', 'docs/version.json') "Frame $v for everyone") { Wait-Live $v }
        Refresh-All
    } catch { Fail $_ } finally { Busy $false }
})

# ---------------- tab 2: other changes
$t2 = New-Object System.Windows.Forms.TabPage; $t2.Text = 'Other changes'; $tabs.TabPages.Add($t2)
New-Label $t2 'Changed files in the repository:' 14 12 400 | Out-Null
$changes = New-Object System.Windows.Forms.ListBox
$changes.Location = New-Object System.Drawing.Point(14, 40); $changes.Size = New-Object System.Drawing.Size(770, 130)
$changes.Font = New-Object System.Drawing.Font('Consolas', 10)
$t2.Controls.Add($changes)
New-Label $t2 'Description:' 14 184 | Out-Null
$msg2 = New-Box $t2 180 184 604; $msg2.Text = 'Update README'
$refresh2 = New-Button $t2 'Refresh list' 14 222 160 36
$push2 = New-Button $t2 'Commit && push all' 186 222 220 36
$push2.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

function Refresh-Changes {
    $changes.Items.Clear()
    $s = Get-GitText @('status', '--short')
    if ($s) { $s -split "`r?`n" | ForEach-Object { [void]$changes.Items.Add($_) } } else { [void]$changes.Items.Add('(no changes)') }
}
$refresh2.Add_Click({ Refresh-Changes })
$push2.Add_Click({
    try {
        Refresh-Changes
        if ($changes.Items.Count -eq 1 -and $changes.Items[0] -eq '(no changes)') { Log 'Nothing to push.'; return }
        if (-not $msg2.Text.Trim()) { throw 'Write a short description first.' }
        Busy $true
        Commit-And-Push $null $msg2.Text.Trim() | Out-Null
        Refresh-All
    } catch { Fail $_ } finally { Busy $false }
})

# ---------------- tab 3: app release
$t3 = New-Object System.Windows.Forms.TabPage; $t3.Text = 'App release'; $tabs.TabPages.Add($t3)
$curApp = New-Label $t3 '' 14 14 770
New-Label $t3 'New app version:' 14 52 | Out-Null
$appVer = New-Box $t3 180 52 120; $appVer.Anchor = 'Top,Left'
New-Label $t3 'Description:' 14 94 | Out-Null
$msg3 = New-Box $t3 180 94 604
New-Label $t3 'Release notes:' 14 134 | Out-Null
$notes3 = New-Object System.Windows.Forms.TextBox; $notes3.Multiline = $true; $notes3.ScrollBars = 'Vertical'
$notes3.Location = New-Object System.Drawing.Point(180, 134); $notes3.Size = New-Object System.Drawing.Size(604, 88); $t3.Controls.Add($notes3)
$hint3 = New-Label $t3 'Only needed after changing the Android app itself (android/ folder). GitHub builds the APK in about 3 minutes, shows these notes on the release page, and the tablet offers the update.' 14 228 770
$hint3.Size = New-Object System.Drawing.Size(770, 40); $hint3.ForeColor = [System.Drawing.Color]::DimGray
$rel = New-Button $t3 'Release app update' 14 268 220 40
$rel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$dl = New-Button $t3 'Download latest APK to PC' 246 268 260 40

$rel.Add_Click({
    try {
        $v = $appVer.Text.Trim()
        if ($v -notmatch '^\d+\.\d+\.\d+$') { throw 'The app version should look like 1.0.1' }
        $a = [System.Windows.Forms.MessageBox]::Show("Release app version $v?`nGitHub will build a new APK and the tablet will offer it.", 'photo-frame publisher', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        Busy $true
        $g = Read-Text $GradlePath
        $g = [regex]::Replace($g, 'versionName "[^"]+"', "versionName `"$v`"", 1)
        Write-Text $GradlePath $g
        Set-VersionJson -Apk $v
        $notesPath = Join-Path $Repo 'release-notes.md'
        if ($notes3.Text.Trim()) { Write-Text $notesPath ($notes3.Text.Trim() -replace "`r`n", "`n") }
        elseif (Test-Path $notesPath) { Remove-Item $notesPath }
        $m = if ($msg3.Text.Trim()) { $msg3.Text.Trim() } else { "App $v" }
        if (Commit-And-Push $null $m) {
            Log "App build started on GitHub: $((Get-SiteInfo).GitHub)/actions"
            Log 'When it finishes (about 3 minutes), click "Download latest APK to PC" for your own copy.'
        }
        Refresh-All
    } catch { Fail $_ } finally { Busy $false }
})
$dl.Add_Click({
    try {
        Busy $true
        New-Item -ItemType Directory -Force -Path $ApkFolder | Out-Null
        $target = Join-Path $ApkFolder 'photo-frame.apk'
        $url = (Get-Versions).apkUrl
        Log "Downloading $url ..."
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $target -TimeoutSec 120
        Log ("Saved to $target (" + [math]::Round((Get-Item $target).Length / 1MB, 1) + ' MB)')
    } catch { Fail $_ } finally { Busy $false }
})

# ---------------- bottom: log + shortcuts
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(12, 396); $logBox.Size = New-Object System.Drawing.Size(820, 214)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28); $logBox.ForeColor = [System.Drawing.Color]::FromArgb(220, 230, 240)
$form.Controls.Add($logBox)
$script:LogBox = $logBox

New-Label $form 'Commit as:' 14 358 90 | Out-Null
$asBox = New-Object System.Windows.Forms.ComboBox
$asBox.DropDownStyle = 'DropDownList'; $asBox.Location = New-Object System.Drawing.Point(104, 358); $asBox.Size = New-Object System.Drawing.Size(340, 28)
$meName = Get-GitText @('config', 'user.name'); if (-not $meName) { $meName = (Get-SiteInfo).Owner }
[void]$asBox.Items.Add("$BotName"); [void]$asBox.Items.Add("Me ($meName)")
$asBox.SelectedIndex = if ($script:CommitAs -eq 'me') { 1 } else { 0 }
$asBox.Add_SelectedIndexChanged({ $script:CommitAs = if ($asBox.SelectedIndex -eq 1) { 'me' } else { 'bot' }; Save-Prefs; Log ('Commits will be credited to: ' + $asBox.SelectedItem) })
$form.Controls.Add($asBox)

$open = New-Button $form 'Open website' 12 620 150 34; $open.Anchor = 'Bottom,Left'
$gh = New-Button $form 'Open GitHub' 172 620 150 34; $gh.Anchor = 'Bottom,Left'
$live = New-Button $form 'Check live version' 332 620 180 34; $live.Anchor = 'Bottom,Left'
$pull = New-Button $form 'Get latest from GitHub' 522 620 200 34; $pull.Anchor = 'Bottom,Left'
$open.Add_Click({ if ($site.Site) { Start-Process $site.Site } })
$gh.Add_Click({ if ($site.GitHub) { Start-Process $site.GitHub } })
$live.Add_Click({
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri ($site.Site + 'version.json?nc=' + [guid]::NewGuid()) -TimeoutSec 15
        $j = $r.Content | ConvertFrom-Json
        Log "Website now: web $($j.web), app $($j.apk)   |   your copy: web $((Get-Versions).web), app $(Get-AppVersion)"
    } catch { Fail $_ }
})
$pull.Add_Click({ try { Busy $true; Invoke-Git @('pull', '--ff-only') | Out-Null; Refresh-All } catch { Fail $_ } finally { Busy $false } })

function Refresh-All {
    $v = Get-Versions
    $curWebLbl.Text = "(website currently: $($v.web))"
    $bv = Get-BetaVersion
    $betaLbl.Text = if ($bv) { "Beta currently: $bv" } else { 'No beta version yet' }
    $a = Get-AppVersion
    $curApp.Text = "Current app version: $a   (version.json says $($v.apk))"
    if (-not $appVer.Text) { $appVer.Text = Bump-Patch $a }
    Refresh-Changes
}

$form.Add_Shown({
    Log "Repository: $Repo"
    Log "Website:    $($site.Site)"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Log 'ERROR: Git was not found. Install Git for Windows first.' }
    Refresh-All
    if ($TestSnapshot) {
        $script:tm = New-Object System.Windows.Forms.Timer; $script:tm.Interval = 1500
        $script:tm.Add_Tick({ $script:tm.Stop(); $b = New-Object System.Drawing.Bitmap($form.Width, $form.Height); $gr = [System.Drawing.Graphics]::FromImage($b); $gr.CopyFromScreen($form.Location, [System.Drawing.Point]::Empty, $form.Size); $gr.Dispose(); $b.Save($TestSnapshot); [Console]::Out.WriteLine($logBox.Text); $form.Close() })
        $script:tm.Start()
    }
})
[void]$form.ShowDialog()
