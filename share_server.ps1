param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8765,

    [ValidatePattern('^(\+|(?:\d{1,3}\.){3}\d{1,3})$')]
    [string]$BindAddress = '+',

    [ValidateRange(0.01, 100000)]
    [double]$MaxGB = 10,

    [string]$StoragePath = '',

    [switch]$DebugMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($StoragePath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:HOUSE_SHARE_STORAGE)) {
        $StoragePath = $env:HOUSE_SHARE_STORAGE
        Remove-Item Env:\HOUSE_SHARE_STORAGE
    }
    else {
        $StoragePath = Join-Path $PSScriptRoot 'SharedFiles'
    }
}
$script:StoragePath = [System.IO.Path]::GetFullPath($StoragePath)
$script:ThemeImagePath = Join-Path $PSScriptRoot 'assets\susya-theme.jpg'
$script:QuotaBytes = [int64]($MaxGB * 1GB)
$script:LogPath = Join-Path $PSScriptRoot 'share-debug.log'
$script:AccessPassword = $null
$script:BindAddress = $BindAddress
$script:DeviceActivity = [hashtable]::Synchronized(@{})
$script:DeviceLock = New-Object object
$script:QuotaLock = New-Object object
$script:ReservedBytes = [hashtable]::Synchronized(@{ Bytes = [int64]0 })
$script:NameLock = New-Object object
$script:ReservedNames = [hashtable]::Synchronized(@{})
$script:LogLock = New-Object object

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    [System.Threading.Monitor]::Enter($script:LogLock)
    try {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        Write-Host $line
    }
    finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
    }
}

function Send-Bytes {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Body
    )

    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Body.Length
    try {
        if ($Body.Length -gt 0) {
            $Context.Response.OutputStream.Write($Body, 0, $Body.Length)
        }
    }
    finally {
        $Context.Response.Close()
    }
}

function Send-Json {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [object]$Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 5 -Compress
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-Bytes -Context $Context -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body $body
}

function Get-UsedBytes {
    [int64]$total = 0
    $pendingDirectories = New-Object 'System.Collections.Generic.Stack[string]'
    $pendingDirectories.Push($script:StoragePath)
    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Pop()
        foreach ($entry in Get-ChildItem -LiteralPath $directory -Force) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($entry.PSIsContainer) {
                $pendingDirectories.Push($entry.FullName)
            }
            elseif ($entry.Name -notlike '.upload-*.tmp') {
                $total += $entry.Length
            }
        }
    }
    return $total
}

function Get-SafeFileName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in @('.', '..')) {
        return $null
    }
    if ($Name.IndexOfAny([char[]]@('/', '\')) -ge 0 -or $Name -match '[\x00-\x1F]' -or $Name -match '[. ]$') {
        return $null
    }
    if ([System.IO.Path]::GetFileName($Name) -cne $Name) {
        return $null
    }
    foreach ($character in [System.IO.Path]::GetInvalidFileNameChars()) {
        if ($Name.Contains([string]$character)) {
            return $null
        }
    }
    return $Name
}

function Get-SafeRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    if ($Path.StartsWith('/') -or $Path.StartsWith('\') -or $Path -match '^[A-Za-z]:' -or $Path -match '[\x00-\x1F]') {
        return $null
    }

    $segments = $Path.Replace('\', '/').Split('/')
    if ($segments.Count -eq 0) { return $null }
    foreach ($segment in $segments) {
        if ($null -eq (Get-SafeFileName -Name $segment)) { return $null }
    }
    return ($segments -join '/')
}

function ConvertFrom-QueryComponent {
    param([string]$Value)

    if ($Value -match '%(?![0-9A-Fa-f]{2})') {
        throw 'Некорректное URL-кодирование параметра запроса.'
    }
    return [Uri]::UnescapeDataString($Value.Replace('+', ' '))
}

function Get-QueryParameter {
    param(
        [System.Net.HttpListenerRequest]$Request,
        [string]$Name
    )

    $query = $Request.Url.Query
    if ([string]::IsNullOrEmpty($query) -or $query -eq '?') { return $null }
    foreach ($pair in $query.Substring(1).Split('&')) {
        $separator = $pair.IndexOf('=')
        $encodedName = if ($separator -ge 0) { $pair.Substring(0, $separator) } else { $pair }
        if ((ConvertFrom-QueryComponent -Value $encodedName) -cne $Name) { continue }
        $encodedValue = if ($separator -ge 0) { $pair.Substring($separator + 1) } else { '' }
        return ConvertFrom-QueryComponent -Value $encodedValue
    }
    return $null
}

function Resolve-StoragePath {
    param(
        [string]$RelativePath,
        [switch]$AllowRoot
    )

    $safePath = Get-SafeRelativePath -Path $RelativePath
    if ($null -eq $safePath -or ($safePath.Length -eq 0 -and -not $AllowRoot)) {
        throw 'Недопустимый путь к файлу или папке.'
    }
    if ($safePath.Length -eq 0) { return $script:StoragePath }

    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $script:StoragePath ($safePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    $rootPrefix = $script:StoragePath.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Путь выходит за пределы папки хранилища.'
    }

    $currentPath = $script:StoragePath
    foreach ($segment in $safePath.Split('/')) {
        $currentPath = Join-Path $currentPath $segment
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Доступ к символическим ссылкам внутри хранилища запрещён.'
            }
        }
    }
    return $fullPath
}

function Ensure-StorageDirectory {
    param([string]$RelativePath)

    $safePath = Get-SafeRelativePath -Path $RelativePath
    if ($null -eq $safePath) { throw 'Недопустимый путь к папке.' }
    if ($safePath.Length -eq 0) { return $script:StoragePath }

    $currentPath = $script:StoragePath
    foreach ($segment in $safePath.Split('/')) {
        $currentPath = Join-Path $currentPath $segment
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            if (-not $item.PSIsContainer) { throw 'Часть пути уже занята файлом.' }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Доступ к символическим ссылкам внутри хранилища запрещён.'
            }
        }
        else {
            New-Item -ItemType Directory -Path $currentPath -ErrorAction Stop | Out-Null
        }
    }
    return $currentPath
}

function Get-PreviewContentType {
    param([string]$Name)

    switch ([System.IO.Path]::GetExtension($Name).ToLowerInvariant()) {
        { $_ -in @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp') } {
            if ($_ -in @('.jpg', '.jpeg')) { return 'image/jpeg' }
            if ($_ -eq '.png') { return 'image/png' }
            if ($_ -eq '.gif') { return 'image/gif' }
            if ($_ -eq '.webp') { return 'image/webp' }
            return 'image/bmp'
        }
        { $_ -in @('.mp4', '.m4v') } { return 'video/mp4' }
        '.webm' { return 'video/webm' }
        '.ogv' { return 'video/ogg' }
        default { return $null }
    }
}

function Get-UniqueFileName {
    param([string]$RelativePath)

    [System.Threading.Monitor]::Enter($script:NameLock)
    try {
        $separator = $RelativePath.LastIndexOf('/')
        $directory = if ($separator -ge 0) { $RelativePath.Substring(0, $separator + 1) } else { '' }
        $name = if ($separator -ge 0) { $RelativePath.Substring($separator + 1) } else { $RelativePath }
        $candidate = $name
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $extension = [System.IO.Path]::GetExtension($name)
        for ([int]$index = 0; $index -le 100000; $index++) {
            if ($index -gt 0) {
                $candidate = '{0} ({1}){2}' -f $baseName, $index, $extension
            }
            $candidatePath = $directory + $candidate
            $targetPath = Resolve-StoragePath -RelativePath $candidatePath
            if (-not (Test-Path -LiteralPath $targetPath) -and -not $script:ReservedNames.ContainsKey($candidatePath)) {
                $script:ReservedNames[$candidatePath] = $true
                return $candidatePath
            }
        }
        throw 'Не удалось подобрать свободное имя файла.'
    }
    finally {
        [System.Threading.Monitor]::Exit($script:NameLock)
    }
}

function Release-ReservedFileName {
    param([string]$RelativePath)

    [System.Threading.Monitor]::Enter($script:NameLock)
    try {
        $script:ReservedNames.Remove($RelativePath)
    }
    finally {
        [System.Threading.Monitor]::Exit($script:NameLock)
    }
}

function Test-Authorized {
    param([System.Net.HttpListenerRequest]$Request)

    $header = $Request.Headers['Authorization']
    if ([string]::IsNullOrWhiteSpace($header) -or -not $header.StartsWith('Basic ', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    try {
        $encoded = $header.Substring(6).Trim()
        $credential = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        $separator = $credential.IndexOf(':')
        if ($separator -lt 0) {
            return $false
        }
        $providedPassword = $credential.Substring($separator + 1)
        return [string]::Equals($providedPassword, $script:AccessPassword, [System.StringComparison]::Ordinal)
    }
    catch {
        return $false
    }
}

function Get-Page {
    $html = @'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Общее хранилище</title>
  <style>
    :root{color-scheme:light;--page:#f5f7fb;--page-glow:#e9efff;--ink:#17243a;--muted:#758198;--blue:#4668e8;--primary:#4668e8;--primary-hover:#3557d5;--line:#e8edf5;--surface:#fff;--card-border:#edf0f5;--shadow:#26385d0a;--brand-bg:#e6ecff;--upload-bg:#f9faff;--upload-border:#cdd6f0;--upload-hover:#eef2ff;--track:#edf0f6;--subtle:#f1f3f8;--icon-bg:#f0f3ff;--icon-color:#6178de;--download-bg:#eef2ff;--download-ink:#425fd3;--danger-bg:#fff3f4;--danger-ink:#a63a48;--danger-border:#ffe1e4;--error:#b43f4d;--secondary-bg:#fff;--secondary-ink:#33415c;--secondary-border:#e3e8f1;--progress-bg:#fff;--meta-ink:#56627a}
    :root[data-theme=dark]{color-scheme:dark;--page:#0d1422;--page-glow:#1b2944;--ink:#e7edf8;--muted:#9aa8bf;--blue:#91a5ff;--primary:#536fe8;--primary-hover:#647ff0;--line:#26334a;--surface:#151f30;--card-border:#26334a;--shadow:#0005;--brand-bg:#202d49;--upload-bg:#111b2b;--upload-border:#354765;--upload-hover:#1b2940;--track:#26334a;--subtle:#202c40;--icon-bg:#202d49;--icon-color:#a1b3ff;--download-bg:#202d49;--download-ink:#b8c5ff;--danger-bg:#38232d;--danger-ink:#ffabb5;--danger-border:#59313e;--error:#ffadb6;--secondary-bg:#1b283b;--secondary-ink:#e7edf8;--secondary-border:#35445d;--progress-bg:#111b2b;--meta-ink:#c2cde0}
    :root[data-theme=susya]{color-scheme:dark;--page:#101419;--page-glow:#34393d;--ink:#f4f4f3;--muted:#d0d0cc;--blue:#f1d8ae;--primary:#756452;--primary-hover:#8d7861;--line:#ffffff30;--surface:#171a1cdb;--card-border:#ffffff36;--shadow:#0006;--brand-bg:#ffffff20;--upload-bg:#101315bd;--upload-border:#ffffff68;--upload-hover:#343a3e;--track:#ffffff25;--subtle:#ffffff18;--icon-bg:#ffffff1a;--icon-color:#f1d8ae;--download-bg:#ffffff20;--download-ink:#f5dfbd;--danger-bg:#562f34d9;--danger-ink:#ffd4d4;--danger-border:#ffffff30;--error:#ffd0d0;--secondary-bg:#171a1cdb;--secondary-ink:#fff;--secondary-border:#ffffff40;--progress-bg:#101315bd;--meta-ink:#f0efea}
    *{box-sizing:border-box}
    body{margin:0;min-height:100vh;padding:48px 20px;font:15px/1.5 Inter,"Segoe UI",system-ui,sans-serif;color:var(--ink);background:radial-gradient(ellipse at 10% 0%,var(--page-glow) 0,transparent 38%),var(--page);transition:background .2s,color .2s}
    :root[data-theme=susya] body{background:linear-gradient(180deg,#0b0d10a8,#0b0d10bd),url("data:image/jpeg;base64,__SUSYA_THEME_IMAGE__") center 44%/cover fixed}
    :root[data-theme=susya] .card{backdrop-filter:blur(11px)}
    main{max-width:850px;margin:0 auto}
    .top{display:flex;align-items:center;gap:15px;margin-bottom:24px}
    .heading{display:flex;align-items:center;gap:15px;min-width:0;flex:1}
    .brand{display:grid;place-items:center;width:48px;height:48px;border-radius:15px;background:var(--brand-bg);color:var(--blue)}
    .brand svg{width:25px;height:25px}
    h1{font-size:23px;letter-spacing:-.5px;margin:0}
    .subtitle{color:var(--muted);font-size:13px;margin:2px 0 0}
    .theme-toggle{display:inline-flex;align-items:center;gap:8px;flex:none;padding:9px 12px;border:1px solid var(--secondary-border);border-radius:11px;background:var(--secondary-bg);color:var(--secondary-ink);font:600 12px "Segoe UI",system-ui,sans-serif;cursor:pointer;transition:background .2s,border-color .2s}
    .theme-toggle:hover{border-color:var(--blue)}
    .theme-icon{font-size:15px;line-height:1}
    .card{background:var(--surface);border:1px solid var(--card-border);border-radius:19px;padding:24px;box-shadow:0 12px 36px var(--shadow);transition:background .2s,border-color .2s}
    .storage{margin-bottom:18px}
    .storage-heading,.section-heading,.file-row,.upload-actions,.progress-heading{display:flex;align-items:center;justify-content:space-between;gap:16px}
    .eyebrow{font-size:11px;letter-spacing:.08em;text-transform:uppercase;font-weight:700;color:var(--muted)}
    .usage{font-size:13px;font-weight:650}
    .bar{height:9px;background:var(--track);border-radius:9px;overflow:hidden}
    #fill{height:100%;width:0;background:linear-gradient(90deg,#5275f1,#8198ff);border-radius:9px;transition:width .3s}
    .upload{padding:20px;background:var(--upload-bg);border:1px dashed var(--upload-border);border-radius:15px;transition:background .2s,border-color .2s}
    .upload.dragover{background:var(--upload-hover);border-color:#6883ed}
    .drop-title{font-size:14px;font-weight:650;margin:0 0 3px}
    .drop-hint{font-size:12px;color:var(--muted);margin:0 0 15px}
    .upload-actions{justify-content:flex-start;flex-wrap:wrap}
    .file-input{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}
    .destination{display:flex;align-items:center;gap:7px;flex-wrap:wrap;margin:0 0 14px;padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:var(--surface);font-size:12px}
    .destination-label{color:var(--muted)}
    #destinationName{overflow-wrap:anywhere;color:var(--download-ink)}
    .button{display:inline-flex;align-items:center;justify-content:center;min-height:39px;padding:0 16px;border:0;border-radius:10px;font:600 13px "Segoe UI",system-ui,sans-serif;cursor:pointer;transition:background .15s,transform .15s}
    .button:active{transform:translateY(1px)}
    .button:disabled{opacity:.55;cursor:not-allowed}
    .button.primary{color:#fff;background:var(--primary);box-shadow:0 5px 12px #4668e82c}
    .button.primary:hover:not(:disabled){background:var(--primary-hover)}
    .button.secondary{color:var(--secondary-ink);background:var(--secondary-bg);border:1px solid var(--secondary-border)}
    .button.danger{color:var(--danger-ink);background:var(--danger-bg);border:1px solid var(--danger-border)}
    #selection{color:var(--muted);font-size:12px}
    #message{min-height:20px;margin-top:12px;color:var(--muted);font-size:12px}
    #message.error{color:var(--error)}
    .progress-card{display:none;margin-top:17px;padding:15px 16px;border:1px solid var(--card-border);border-radius:12px;background:var(--progress-bg)}
    .batch-heading{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:9px;font-size:12px;font-weight:650}
    #batchPercent{color:var(--blue);font-variant-numeric:tabular-nums}
    #batchEta{margin-top:7px;color:var(--meta-ink);font-size:12px;font-weight:600}
    .progress-track{height:7px;background:var(--track);border-radius:8px;overflow:hidden}
    #batchFill,.file-progress-fill{height:100%;width:0;background:linear-gradient(90deg,#5275f1,#8198ff);border-radius:8px;transition:width .12s}
    .upload-queue{display:grid;gap:10px;margin-top:14px}
    .upload-item{padding:10px 11px;background:var(--upload-bg);border:1px solid var(--line);border-radius:10px}
    .upload-item-heading{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-bottom:7px;font-size:12px}
    .upload-file-name{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--meta-ink)}
    .upload-file-status{flex:none;color:var(--muted);font-size:11px}
    .upload-file-percent{font-weight:700;color:var(--blue);font-variant-numeric:tabular-nums}
    .upload-item-meta{display:flex;justify-content:space-between;gap:8px;margin-top:5px;color:var(--muted);font-size:10px}
    .upload-item.error .upload-file-status{color:var(--error)}
    .files-card{margin-top:18px}
    .section-heading{margin-bottom:12px}
    h2{font-size:16px;margin:0}
    #fileCount{font-size:11px;color:var(--muted);background:var(--subtle);border-radius:20px;padding:4px 9px}
    .breadcrumbs{display:flex;align-items:center;gap:7px;flex-wrap:wrap;margin:0 0 10px;color:var(--muted);font-size:12px}
    .breadcrumb{padding:3px 6px;border:0;border-radius:6px;background:transparent;color:var(--download-ink);font:inherit;cursor:pointer}
    .breadcrumb:hover{background:var(--subtle)}
    .folder-list{margin-bottom:4px}
    .folder-link{display:flex;align-items:center;gap:12px;width:100%;padding:10px 0;border:0;background:transparent;color:var(--ink);text-align:left;font:600 13px "Segoe UI",system-ui,sans-serif;cursor:pointer}
    .folder-link:hover .folder-name{color:var(--blue)}
    .folder-icon{display:grid;place-items:center;flex:none;width:38px;height:38px;border-radius:11px;background:var(--brand-bg);color:var(--blue);font-size:18px}
    .folder-name{flex:1;overflow-wrap:anywhere}
    .folder-arrow{color:var(--muted)}
    ul{padding:0;margin:0;list-style:none}
    li{display:flex;align-items:center;gap:14px;padding:13px 0;border-bottom:1px solid var(--line)}
    li:last-child{border-bottom:0}
    .file-icon{flex:none;display:grid;place-items:center;width:38px;height:38px;border-radius:11px;background:var(--icon-bg);color:var(--icon-color);font-size:17px}
    .media-thumbnail{position:relative;flex:none;display:grid;place-items:center;width:76px;height:58px;padding:0;overflow:hidden;border:1px solid var(--card-border);border-radius:10px;background:var(--icon-bg);color:var(--icon-color);cursor:pointer}
    .media-thumbnail img{display:block;width:100%;height:100%;object-fit:cover}
    .media-thumbnail.video::after{content:'▶';position:absolute;display:grid;place-items:center;width:25px;height:25px;padding-left:2px;border-radius:50%;background:#101827b8;color:#fff;font-size:11px}
    .media-thumbnail.video.has-frame::after{opacity:.9}
    .file-info{flex:1;min-width:0}
    .name{display:block;overflow-wrap:anywhere;font-size:13px;font-weight:600}
    .file-meta{display:block;margin-top:2px;color:var(--muted);font-size:11px}
    .file-actions{display:flex;align-items:center;gap:7px}
    a.download{display:inline-flex;align-items:center;min-height:34px;padding:0 11px;text-decoration:none;border-radius:9px;background:var(--download-bg);color:var(--download-ink);font-size:12px;font-weight:600}
    .button.small{min-height:34px;padding:0 10px;font-size:12px}
    .empty{text-align:center;padding:26px 8px;color:var(--muted);font-size:13px}
    .preview[hidden]{display:none}
    .preview{position:fixed;inset:0;z-index:5;display:grid;place-items:center;padding:20px;background:#07101dcc;backdrop-filter:blur(7px)}
    .preview-content{width:min(100%,1000px);max-height:calc(100vh - 40px);display:flex;flex-direction:column;gap:12px;padding:14px;border:1px solid var(--card-border);border-radius:16px;background:var(--surface);box-shadow:0 24px 80px #0006}
    .preview-heading{display:flex;align-items:center;justify-content:space-between;gap:12px}
    #previewTitle{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:14px}
    #previewImage,#previewVideo{display:block;max-width:100%;max-height:calc(100vh - 120px);margin:0 auto;border-radius:8px;object-fit:contain}
    @media(max-width:600px){.preview{padding:10px}.preview-content{max-height:calc(100vh - 20px);padding:10px}#previewImage,#previewVideo{max-height:calc(100vh - 100px)}}
    @media(max-width:600px){body{padding:25px 13px}.card{padding:17px;border-radius:15px}.top{margin-bottom:17px}.heading{gap:10px}.brand{width:42px;height:42px;flex:none}h1{font-size:20px}.upload-actions{align-items:stretch}.button.primary{flex:1}li{gap:9px}.media-thumbnail{width:60px;height:48px}.file-actions{gap:5px}a.download,.button.small{padding:0 8px}.file-meta{font-size:10px}}
    @media(max-width:420px){.theme-toggle{width:40px;height:40px;padding:0;justify-content:center}.theme-toggle #themeLabel{display:none}}
  </style>
</head>
<body>
<main>
  <header class="top">
    <div class="heading"><div class="brand" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 16V4m0 0L7.5 8.5M12 4l4.5 4.5"/><path d="M5 13v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/></svg></div><div><h1>Общее хранилище</h1><p class="subtitle">Файлы вашей команды — в одном месте</p></div></div>
    <button id="themeToggle" class="theme-toggle" type="button" aria-label="Включить тёмную тему"><span id="themeIcon" class="theme-icon" aria-hidden="true">◐</span><span id="themeLabel">Тёмная тема</span></button>
  </header>
  <section class="card storage">
    <div class="storage-heading"><span class="eyebrow">Место в хранилище</span><span id="usage" class="usage">Загрузка...</span></div>
    <div class="bar" style="margin-top:11px"><div id="fill"></div></div>
  </section>
  <section class="card">
    <div class="destination"><span class="destination-label">Папка назначения:</span><strong id="destinationName">Корень хранилища</strong></div>
    <div id="dropzone" class="upload">
      <p class="drop-title">Загрузите файлы и папки в хранилище</p>
      <p class="drop-hint">Перетащите файлы или папки, выберите их или вставьте фото/видео клавишами Ctrl+V</p>
      <input id="files" class="file-input" type="file" multiple>
      <input id="folderPicker" class="file-input" type="file" webkitdirectory directory multiple>
      <div class="upload-actions">
        <label for="files" class="button secondary">Выбрать файлы</label>
        <label for="folderPicker" class="button secondary">Выбрать папку</label>
        <button id="upload" class="button primary" type="button" disabled>Загрузить</button>
        <span id="selection">Файлы не выбраны</span>
      </div>
    </div>
    <div id="progressCard" class="progress-card" role="status" aria-live="polite">
      <div class="batch-heading"><span>Общий прогресс</span><span id="batchPercent">0%</span></div>
      <div class="progress-track"><div id="batchFill"></div></div>
      <div id="batchEta">До конца загрузки: ждём скорость передачи...</div>
      <div id="uploadQueue" class="upload-queue"></div>
    </div>
    <div id="message" role="status"></div>
  </section>
  <section class="card files-card">
    <div class="section-heading"><h2>Файлы</h2><span id="fileCount">0 файлов</span><button id="selectDestination" class="button secondary small" type="button">Загружать сюда</button></div>
    <nav id="breadcrumbs" class="breadcrumbs" aria-label="Путь к папке"></nav>
    <ul id="foldersList" class="folder-list"></ul>
    <ul id="list"></ul>
  </section>
</main>
<div id="preview" class="preview" hidden role="dialog" aria-modal="true" aria-labelledby="previewTitle">
  <div class="preview-content">
    <div class="preview-heading"><h2 id="previewTitle"></h2><button id="previewClose" class="button secondary small" type="button" aria-label="Закрыть просмотр">Закрыть</button></div>
    <img id="previewImage" hidden alt="">
    <video id="previewVideo" controls playsinline hidden></video>
  </div>
</div>
<script>
const $ = id => document.getElementById(id);
function applyTheme(theme) {
  const themes = ['light', 'dark', 'susya'];
  const nextTheme = themes[(themes.indexOf(theme) + 1) % themes.length];
  const nextLabels = {light:'Светлая тема', dark:'Тёмная тема', susya:'сюся.'};
  const nextIcons = {light:'◐', dark:'☀', susya:'🐆'};
  document.documentElement.dataset.theme = theme;
  $('themeIcon').textContent = nextIcons[nextTheme];
  $('themeLabel').textContent = nextLabels[nextTheme];
  $('themeToggle').setAttribute('aria-label', 'Включить тему «' + nextLabels[nextTheme] + '»');
}
let savedTheme = 'light';
try {
  const storedTheme = localStorage.getItem('share-theme');
  savedTheme = ['light', 'dark', 'susya'].includes(storedTheme) ? storedTheme : 'light';
} catch {}
applyTheme(savedTheme);
$('themeToggle').addEventListener('click', () => {
  const themes = ['light', 'dark', 'susya'];
  savedTheme = themes[(themes.indexOf(savedTheme) + 1) % themes.length];
  applyTheme(savedTheme);
  try { localStorage.setItem('share-theme', savedTheme); } catch {}
});
let currentPath = '';
let uploadPath = '';
let selectedUploads = [];
function appendPath(parent, child) {
  return parent ? parent + '/' + child : child;
}
function showUploadDestination() {
  $('destinationName').textContent = uploadPath || 'Корень хранилища';
  $('selectDestination').disabled = uploadPath === currentPath;
  $('selectDestination').textContent = uploadPath === currentPath ? 'Папка выбрана' : 'Загружать сюда';
}
function formatFileCount(count) {
  const lastTwo = count % 100;
  const last = count % 10;
  const noun = lastTwo >= 11 && lastTwo <= 14 ? 'файлов' : last === 1 ? 'файл' : last >= 2 && last <= 4 ? 'файла' : 'файлов';
  return count + ' ' + noun;
}
function formatBytes(n) {
  if (n < 1024) return n + ' Б';
  const units = ['КБ','МБ','ГБ','ТБ']; let value = n / 1024, i = 0;
  while (value >= 1024 && i < units.length - 1) { value /= 1024; i++; }
  return value.toFixed(1) + ' ' + units[i];
}
async function request(url, options) {
  const response = await fetch(url, options);
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || ('Ошибка HTTP ' + response.status));
  return result;
}
async function refresh() {
  try {
    const data = await request('/api/files?path=' + encodeURIComponent(currentPath));
    $('usage').textContent = 'Занято ' + formatBytes(data.usedBytes) + ' из ' + formatBytes(data.maxBytes);
    $('fill').style.width = Math.min(100, data.usedBytes / data.maxBytes * 100) + '%';
    const breadcrumbs = $('breadcrumbs'); breadcrumbs.replaceChildren();
    const rootButton = document.createElement('button'); rootButton.type = 'button'; rootButton.className = 'breadcrumb'; rootButton.textContent = 'Хранилище';
    rootButton.addEventListener('click', () => navigateTo(''));
    breadcrumbs.append(rootButton);
    let crumbPath = '';
    for (const segment of currentPath ? currentPath.split('/') : []) {
      const separator = document.createElement('span'); separator.textContent = '›'; separator.setAttribute('aria-hidden', 'true');
      breadcrumbs.append(separator);
      crumbPath = appendPath(crumbPath, segment);
      const path = crumbPath;
      const crumb = document.createElement('button'); crumb.type = 'button'; crumb.className = 'breadcrumb'; crumb.textContent = segment;
      crumb.addEventListener('click', () => navigateTo(path));
      breadcrumbs.append(crumb);
    }
    const folders = $('foldersList'); folders.replaceChildren();
    for (const folder of data.folders) {
      const item = document.createElement('li');
      const button = document.createElement('button'); button.className = 'folder-link'; button.type = 'button';
      const icon = document.createElement('span'); icon.className = 'folder-icon'; icon.setAttribute('aria-hidden', 'true'); icon.textContent = '📁';
      const name = document.createElement('span'); name.className = 'folder-name'; name.textContent = folder.name;
      const arrow = document.createElement('span'); arrow.className = 'folder-arrow'; arrow.setAttribute('aria-hidden', 'true'); arrow.textContent = '›';
      button.append(icon, name, arrow);
      button.addEventListener('click', () => navigateTo(folder.path));
      item.append(button); folders.append(item);
    }
    const list = $('list'); list.replaceChildren();
    $('fileCount').textContent = formatFileCount(data.files.length);
    if (!data.files.length && !data.folders.length) {
      const empty = document.createElement('li'); empty.className = 'empty';
      empty.textContent = currentPath ? 'Эта папка пока пуста.' : 'Здесь пока пусто — загрузите первый файл или папку.';
      list.append(empty);
      return;
    }
    for (const file of data.files) {
      file.path = appendPath(currentPath, file.name);
      const item = document.createElement('li');
      let icon;
      if (file.previewType) {
        icon = document.createElement('button');
        icon.className = 'media-thumbnail' + (file.previewType.startsWith('video/') ? ' video' : '');
        icon.type = 'button';
        icon.title = 'Открыть просмотр: ' + file.name;
        icon.setAttribute('aria-label', 'Просмотреть ' + file.name);
        icon.addEventListener('click', () => openPreview(file));
        if (file.previewType.startsWith('image/')) {
          const thumbnail = document.createElement('img');
          thumbnail.src = '/view?name=' + encodeURIComponent(file.path);
          thumbnail.alt = '';
          thumbnail.loading = 'lazy';
          icon.append(thumbnail);
        } else {
          loadVideoThumbnail(file, icon);
        }
      } else {
        icon = document.createElement('span');
        icon.className = 'file-icon';
        icon.setAttribute('aria-hidden', 'true');
        icon.textContent = '↗';
      }
      const info = document.createElement('span'); info.className = 'file-info';
      const name = document.createElement('span'); name.className = 'name'; name.textContent = file.name;
      const meta = document.createElement('span'); meta.className = 'file-meta'; meta.textContent = formatBytes(file.size) + ' · ' + file.modified;
      info.append(name, meta);
      const download = document.createElement('a');
      download.href = '/download?name=' + encodeURIComponent(file.path);
      download.className = 'download';
      download.textContent = 'Скачать';
      const actions = document.createElement('span'); actions.className = 'file-actions';
      if (file.previewType) {
        const preview = document.createElement('button'); preview.className = 'button secondary small'; preview.textContent = 'Просмотр'; preview.type = 'button';
        preview.addEventListener('click', () => openPreview(file));
        actions.append(preview);
      }
      const remove = document.createElement('button'); remove.className = 'button danger small'; remove.textContent = 'Удалить'; remove.type = 'button';
      remove.addEventListener('click', async () => {
        if (!confirm('Удалить файл «' + file.name + '»?')) return;
        try { await request('/api/files?name=' + encodeURIComponent(file.path), {method:'DELETE'}); showMessage('Файл удалён.'); await refresh(); }
        catch (error) { showMessage(error.message, true); }
      });
      actions.append(download, remove);
      item.append(icon, info, actions); list.append(item);
    }
  } catch (error) { showMessage(error.message, true); }
}
function navigateTo(path) {
  currentPath = path;
  showUploadDestination();
  refresh();
}
function showMessage(text, isError) {
  $('message').textContent = text;
  $('message').classList.toggle('error', Boolean(isError));
}
function openPreview(file) {
  const url = '/view?name=' + encodeURIComponent(file.path || appendPath(currentPath, file.name));
  $('previewTitle').textContent = file.name;
  $('previewImage').hidden = !file.previewType.startsWith('image/');
  $('previewVideo').hidden = !file.previewType.startsWith('video/');
  if (!$('previewImage').hidden) $('previewImage').src = url;
  if (!$('previewVideo').hidden) {
    $('previewVideo').src = url;
    $('previewVideo').load();
  }
  $('preview').hidden = false;
  $('previewClose').focus();
}
const videoThumbnailObserver = 'IntersectionObserver' in window ? new IntersectionObserver(entries => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    videoThumbnailObserver.unobserve(entry.target);
    loadVideoThumbnailNow(entry.target.videoFile, entry.target);
  }
}, {rootMargin:'120px'}) : null;
function loadVideoThumbnail(file, button) {
  if (videoThumbnailObserver) {
    button.videoFile = file;
    videoThumbnailObserver.observe(button);
    return;
  }
  loadVideoThumbnailNow(file, button);
}
function loadVideoThumbnailNow(file, button) {
  const video = document.createElement('video');
  video.preload = 'metadata';
  video.muted = true;
  video.playsInline = true;
  video.addEventListener('loadedmetadata', () => {
    if (!Number.isFinite(video.duration) || video.duration <= 0) return;
    video.currentTime = Math.min(1, video.duration / 2);
  }, {once:true});
  video.addEventListener('seeked', () => {
    try {
      const canvas = document.createElement('canvas');
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
      const thumbnail = document.createElement('img');
      thumbnail.alt = '';
      thumbnail.src = canvas.toDataURL('image/jpeg', 0.75);
      button.replaceChildren(thumbnail);
      button.classList.add('has-frame');
    } catch {
      button.title = 'Откройте просмотр, чтобы воспроизвести видео';
    } finally {
      video.pause();
      video.removeAttribute('src');
      video.load();
    }
  }, {once:true});
  video.addEventListener('error', () => {
    video.removeAttribute('src');
    video.load();
  }, {once:true});
  video.src = '/view?name=' + encodeURIComponent(file.path || appendPath(currentPath, file.name));
}
function closePreview() {
  $('previewVideo').pause();
  $('previewVideo').removeAttribute('src');
  $('previewVideo').load();
  $('previewImage').removeAttribute('src');
  $('preview').hidden = true;
}
$('previewClose').addEventListener('click', closePreview);
$('preview').addEventListener('click', event => { if (event.target === $('preview')) closePreview(); });
document.addEventListener('keydown', event => { if (event.key === 'Escape' && !$('preview').hidden) closePreview(); });
function uploadFile(file, relativePath, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('PUT', '/api/upload?name=' + encodeURIComponent(relativePath));
    xhr.upload.addEventListener('progress', event => {
      if (event.lengthComputable) onProgress(event.loaded, event.total);
    });
    xhr.addEventListener('load', () => {
      let result = {};
      try { result = JSON.parse(xhr.responseText); } catch {}
      if (xhr.status >= 200 && xhr.status < 300) resolve(result);
      else reject(new Error(result.error || ('Ошибка HTTP ' + xhr.status)));
    });
    xhr.addEventListener('error', () => reject(new Error('Не удалось передать файл. Проверьте подключение.')));
    xhr.addEventListener('abort', () => reject(new Error('Загрузка прервана.')));
    xhr.send(file);
  });
}
function updateUploadProgress(row, percent, detail, status) {
  const value = Math.max(0, Math.min(100, Math.floor(percent)));
  row.querySelector('.file-progress-fill').style.width = value + '%';
  row.querySelector('.upload-file-percent').textContent = value + '%';
  row.querySelector('.upload-item-meta').firstElementChild.textContent = detail;
  row.querySelector('.upload-file-status').textContent = status;
}
function formatEta(seconds) {
  const total = Math.max(0, Math.ceil(seconds));
  if (total < 60) return '≈ ' + total + ' сек.';
  if (total < 3600) {
    const minutes = Math.floor(total / 60);
    const remainingSeconds = total % 60;
    return '≈ ' + minutes + ' мин' + (remainingSeconds ? ' ' + remainingSeconds + ' сек.' : '');
  }
  const hours = Math.floor(total / 3600);
  const minutes = Math.ceil((total % 3600) / 60);
  return '≈ ' + hours + ' ч' + (minutes ? ' ' + minutes + ' мин' : '');
}
function estimateFileEta(fileSize, loaded, startedAt) {
  const remaining = Math.max(0, fileSize - loaded);
  if (remaining === 0) return 'Осталось: почти готово';
  const elapsed = (Date.now() - startedAt) / 1000;
  if (elapsed < 0.25 || loaded <= 0) return 'Расчёт времени...';
  const rate = loaded / elapsed;
  if (rate <= 0) return 'Расчёт времени...';
  return 'Осталось ' + formatEta(remaining / rate);
}
function updateBatchEta(states, startedAt) {
  if (states.every(state => state.done)) {
    $('batchEta').textContent = states.some(state => state.failed) ? 'Файлы с ошибками можно выбрать и отправить повторно.' : 'Загрузка завершена.';
    return;
  }
  const activeStates = states.filter(state => !state.failed);
  const totalBytes = activeStates.reduce((sum, state) => sum + state.file.size, 0);
  const loadedBytes = activeStates.reduce((sum, state) => sum + Math.min(state.loaded, state.file.size), 0);
  const remaining = Math.max(0, totalBytes - loadedBytes);
  const elapsed = (Date.now() - startedAt) / 1000;
  const rate = loadedBytes / elapsed;
  if (remaining === 0) {
    $('batchEta').textContent = 'Завершаем передачу...';
  } else if (elapsed < 0.25 || loadedBytes <= 0 || rate <= 0) {
    $('batchEta').textContent = 'Оцениваем оставшееся время...';
  } else {
    $('batchEta').textContent = 'До конца загрузки: ' + formatEta(remaining / rate);
  }
}
function createUploadRow(file, relativePath) {
  const row = document.createElement('div'); row.className = 'upload-item';
  const heading = document.createElement('div'); heading.className = 'upload-item-heading';
  const name = document.createElement('span'); name.className = 'upload-file-name'; name.textContent = relativePath || file.name;
  const right = document.createElement('span'); right.style.display = 'flex'; right.style.alignItems = 'center'; right.style.gap = '9px';
  const status = document.createElement('span'); status.className = 'upload-file-status'; status.textContent = 'В очереди';
  const percent = document.createElement('span'); percent.className = 'upload-file-percent'; percent.textContent = '0%';
  right.append(status, percent); heading.append(name, right);
  const track = document.createElement('div'); track.className = 'progress-track';
  const fill = document.createElement('div'); fill.className = 'file-progress-fill'; track.append(fill);
  const meta = document.createElement('div'); meta.className = 'upload-item-meta';
  const detail = document.createElement('span'); detail.textContent = formatBytes(file.size);
  const eta = document.createElement('span'); eta.textContent = 'В очереди';
  meta.append(detail, eta); row.append(heading, track, meta);
  return row;
}
function updateSelection() {
  const totalBytes = selectedUploads.reduce((sum, upload) => sum + upload.file.size, 0);
  $('upload').disabled = selectedUploads.length === 0;
  $('selection').textContent = selectedUploads.length ? formatFileCount(selectedUploads.length) + ' · ' + formatBytes(totalBytes) : 'Файлы не выбраны';
  showMessage('', false);
}
function addSelectedFiles(uploads) {
  selectedUploads.push(...uploads);
  updateSelection();
  return uploads.length;
}
$('files').addEventListener('change', () => {
  addSelectedFiles(Array.from($('files').files, file => ({file, relativePath:file.name})));
  $('files').value = '';
});
$('folderPicker').addEventListener('change', () => {
  const uploads = Array.from($('folderPicker').files, file => ({
    file,
    relativePath:file.webkitRelativePath || file.name
  }));
  addSelectedFiles(uploads);
  $('folderPicker').value = '';
  if (!uploads.length) showMessage('В выбранной папке нет файлов для передачи.', true);
});
function readDirectoryEntries(reader) {
  return new Promise((resolve, reject) => reader.readEntries(resolve, reject));
}
async function collectDroppedEntry(entry, parentPath, uploads) {
  if (entry.isFile) {
    const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
    uploads.push({file, relativePath:appendPath(parentPath, entry.name)});
    return;
  }
  if (!entry.isDirectory) return;
  const directoryPath = appendPath(parentPath, entry.name);
  const reader = entry.createReader();
  while (true) {
    const entries = await readDirectoryEntries(reader);
    if (!entries.length) break;
    for (const child of entries) await collectDroppedEntry(child, directoryPath, uploads);
  }
}
$('dropzone').addEventListener('dragover', event => { event.preventDefault(); $('dropzone').classList.add('dragover'); });
$('dropzone').addEventListener('dragleave', event => {
  if (!$('dropzone').contains(event.relatedTarget)) $('dropzone').classList.remove('dragover');
});
$('dropzone').addEventListener('drop', event => {
  event.preventDefault(); $('dropzone').classList.remove('dragover');
  (async () => {
    try {
      const uploads = [];
      const items = Array.from(event.dataTransfer.items || []);
      if (items.some(item => typeof item.webkitGetAsEntry === 'function' && item.webkitGetAsEntry())) {
        for (const item of items) {
          const entry = typeof item.webkitGetAsEntry === 'function' ? item.webkitGetAsEntry() : null;
          if (entry) await collectDroppedEntry(entry, '', uploads);
        }
      } else {
        uploads.push(...Array.from(event.dataTransfer.files || [], file => ({file, relativePath:file.name})));
      }
      if (!uploads.length) {
        showMessage('Не удалось получить файлы из перетащенной папки.', true);
        return;
      }
      addSelectedFiles(uploads);
    } catch (error) {
      showMessage('Не удалось прочитать папку: ' + error.message, true);
    }
  })();
});
document.addEventListener('paste', event => {
  const clipboard = event.clipboardData;
  if (!clipboard) return;
  const pasted = [];
  if (clipboard.items) {
    for (const item of clipboard.items) {
      if (item.kind === 'file') {
        const file = item.getAsFile();
        if (file) pasted.push(file);
      }
    }
  }
  if (!pasted.length && clipboard.files) pasted.push(...Array.from(clipboard.files));
  if (!pasted.length) return;
  const media = pasted.filter(file => file.type.startsWith('image/') || file.type.startsWith('video/') ||
    /\.(png|jpe?g|gif|webp|bmp|mp4|m4v|webm|ogv)$/i.test(file.name));
  if (!media.length) {
    event.preventDefault();
    showMessage('Из буфера можно вставить фото или видео.', true);
    return;
  }
  event.preventDefault();
  try {
    const named = media.map((file, index) => {
      if (file.name) return file;
      const extension = file.type === 'image/jpeg' ? 'jpg' : file.type.split('/')[1] || 'bin';
      return new File([file], (file.type.startsWith('video/') ? 'video-' : 'image-') + Date.now() + '-' + index + '.' + extension, {type:file.type, lastModified:Date.now()});
    });
    const added = addSelectedFiles(named.map(file => ({file, relativePath:file.name})));
    showMessage('Добавлено из буфера: ' + added + ' фото/видео. Нажмите «Загрузить».', false);
  } catch {
    showMessage('Не удалось вставить файлы из буфера. Попробуйте выбрать их кнопкой.', true);
  }
});
$('upload').addEventListener('click', async () => {
  const uploads = selectedUploads.map(upload => ({
    file:upload.file,
    relativePath:upload.relativePath,
    targetPath:appendPath(uploadPath, upload.relativePath)
  }));
  if (!uploads.length) return;
  $('upload').disabled = true;
  $('progressCard').style.display = 'block';
  $('uploadQueue').replaceChildren();
  showMessage('', false);
  const batchSize = uploads.reduce((sum, upload) => sum + upload.file.size, 0);
  const states = uploads.map(upload => ({...upload, loaded:0, failed:false, done:false, startedAt:0, row:createUploadRow(upload.file, upload.targetPath)}));
  for (const state of states) $('uploadQueue').append(state.row);
  const batchStartedAt = Date.now();
  updateBatchEta(states, batchStartedAt);
  const etaTimer = setInterval(() => updateBatchEta(states, batchStartedAt), 1000);
  let nextIndex = 0;
  const workers = Array.from({length:Math.min(4, uploads.length)}, async () => {
    while (true) {
      const index = nextIndex++;
      if (index >= uploads.length) return;
      const upload = uploads[index];
      const file = upload.file;
      const state = states[index];
      state.startedAt = Date.now();
      state.lastUiUpdate = 0;
      updateUploadProgress(state.row, 0, upload.targetPath, 'Загрузка');
      state.row.querySelector('.upload-item-meta').lastElementChild.textContent = 'Расчёт времени...';
      try {
        const result = await uploadFile(file, upload.targetPath, (loaded, total) => {
          state.loaded = Math.min(file.size, loaded);
          const now = Date.now();
          if (now - state.lastUiUpdate < 100 && loaded < total) return;
          state.lastUiUpdate = now;
          updateUploadProgress(state.row, total ? loaded / total * 100 : 0, formatBytes(loaded) + ' из ' + formatBytes(total), 'Загрузка');
          state.row.querySelector('.upload-item-meta').lastElementChild.textContent = estimateFileEta(file.size, state.loaded, state.startedAt);
          const overall = Math.round(states.reduce((sum, current) => sum + current.loaded, 0) / Math.max(batchSize, 1) * 100);
          $('batchPercent').textContent = overall + '%';
          $('batchFill').style.width = overall + '%';
          updateBatchEta(states, batchStartedAt);
        });
        state.loaded = file.size;
        state.done = true;
        const actualName = result.uploaded || upload.targetPath;
        const renamed = actualName !== upload.targetPath;
        updateUploadProgress(state.row, 100, renamed ? 'Сохранён как «' + actualName + '»' : 'Загружен · ' + formatBytes(file.size), 'Готово');
        state.row.querySelector('.upload-item-meta').lastElementChild.textContent = 'Готово';
      } catch (error) {
        state.failed = true;
        state.done = true;
        state.row.classList.add('error');
        updateUploadProgress(state.row, state.loaded / Math.max(file.size, 1) * 100, error.message, 'Ошибка');
        state.row.querySelector('.upload-item-meta').lastElementChild.textContent = 'Не загружен';
      } finally {
        const overall = Math.round(states.reduce((sum, current) => sum + (current.failed ? 0 : current.loaded), 0) / Math.max(batchSize, 1) * 100);
        $('batchPercent').textContent = overall + '%';
        $('batchFill').style.width = overall + '%';
        updateBatchEta(states, batchStartedAt);
      }
    }
  });
  await Promise.all(workers);
  clearInterval(etaTimer);
  updateBatchEta(states, batchStartedAt);
  const failed = states.filter(state => state.failed).length;
  if (failed === 0) {
    selectedUploads = [];
    $('folderPicker').value = '';
    updateSelection();
    currentPath = uploadPath;
    showUploadDestination();
    showMessage('Все файлы загружены в «' + (uploadPath || 'корень хранилища') + '».', false);
  } else {
    selectedUploads = states.filter(state => state.failed).map(({file, relativePath}) => ({file, relativePath}));
    updateSelection();
    currentPath = uploadPath;
    showUploadDestination();
    showMessage(failed + ' файл(ов) не загрузилось. Проверьте строки с ошибками и повторите загрузку.', true);
  }
  await refresh();
  $('upload').disabled = selectedUploads.length === 0;
});
$('selectDestination').addEventListener('click', () => {
  uploadPath = currentPath;
  showUploadDestination();
  showMessage('Место загрузки выбрано: ' + (uploadPath || 'корень хранилища') + '.', false);
});
showUploadDestination();
refresh();
</script>
</body>
</html>
'@
    $imagePath = $script:ThemeImagePath
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
        throw 'Не найден фон третьей темы: ' + $imagePath
    }
    $imageBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($imagePath))
    $html = $html.Replace('__SUSYA_THEME_IMAGE__', $imageBase64)
    return [System.Text.Encoding]::UTF8.GetBytes($html)
}

function Handle-Request {
    param([System.Net.HttpListenerContext]$Context)

    $request = $Context.Request
    $response = $Context.Response
    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod
    if ($DebugMode) {
        Write-Log 'DEBUG' ('{0} {1} from {2}' -f $method, $request.Url.PathAndQuery, $request.RemoteEndPoint)
    }

    if (-not (Test-Authorized -Request $request)) {
        $response.AddHeader('WWW-Authenticate', 'Basic realm="Shared files", charset="UTF-8"')
        Send-Bytes -Context $Context -StatusCode 401 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Нужен пароль.'))
        Write-Log 'INFO' ('401 {0} {1}' -f $method, $path)
        return
    }

    $clientAddress = $request.RemoteEndPoint.Address.ToString()
    if (-not [System.Net.IPAddress]::IsLoopback($request.RemoteEndPoint.Address) -and $clientAddress -ne $script:BindAddress) {
        [System.Threading.Monitor]::Enter($script:DeviceLock)
        try {
            $script:DeviceActivity[$clientAddress] = Get-Date
        }
        finally {
            [System.Threading.Monitor]::Exit($script:DeviceLock)
        }
    }

    if ($method -eq 'GET' -and $path -eq '/') {
        Send-Bytes -Context $Context -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-Page)
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/files') {
        $relativeDirectory = Get-SafeRelativePath -Path (Get-QueryParameter -Request $request -Name 'path')
        if ($null -eq $relativeDirectory) {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Недопустимый путь к папке.' }
            return
        }
        try {
            $directoryPath = Resolve-StoragePath -RelativePath $relativeDirectory -AllowRoot
        }
        catch {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = $_.Exception.Message }
            return
        }
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            Send-Json -Context $Context -StatusCode 404 -Value @{ error = 'Папка не найдена.' }
            return
        }
        $folders = @(
            Get-ChildItem -LiteralPath $directoryPath -Directory -Force |
                Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 } |
                Sort-Object Name |
                ForEach-Object {
                    @{
                        name = $_.Name
                        path = if ($relativeDirectory) { $relativeDirectory + '/' + $_.Name } else { $_.Name }
                        modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    }
                }
        )
        $files = @(
            Get-ChildItem -LiteralPath $directoryPath -File -Force |
                Where-Object { $_.Name -notlike '.upload-*.tmp' -and ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 } |
                Sort-Object Name |
                ForEach-Object {
                    @{
                        name = $_.Name
                        size = [int64]$_.Length
                        modified = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                        previewType = Get-PreviewContentType -Name $_.Name
                    }
                }
        )
        Send-Json -Context $Context -StatusCode 200 -Value @{
            path = $relativeDirectory
            folders = $folders
            files = $files
            usedBytes = (Get-UsedBytes)
            maxBytes = $script:QuotaBytes
        }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/api/devices') {
        $cutoff = (Get-Date).AddMinutes(-10)
        [System.Threading.Monitor]::Enter($script:DeviceLock)
        try {
            foreach ($address in @($script:DeviceActivity.Keys)) {
                if ($script:DeviceActivity[$address] -lt $cutoff) {
                    $script:DeviceActivity.Remove($address)
                }
            }
            $devices = @(
                foreach ($address in $script:DeviceActivity.Keys) {
                    @{
                        address = $address
                        lastSeen = $script:DeviceActivity[$address].ToString('HH:mm:ss')
                        online = $script:DeviceActivity[$address] -ge (Get-Date).AddMinutes(-2)
                    }
                }
            )
        }
        finally {
            [System.Threading.Monitor]::Exit($script:DeviceLock)
        }
        Send-Json -Context $Context -StatusCode 200 -Value @{ devices = $devices }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/download') {
        $relativePath = Get-SafeRelativePath -Path (Get-QueryParameter -Request $request -Name 'name')
        if ($null -eq $relativePath -or $relativePath.Length -eq 0) {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Недопустимое имя файла.' }
            return
        }
        $filePath = Resolve-StoragePath -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            Send-Json -Context $Context -StatusCode 404 -Value @{ error = 'Файл не найден.' }
            return
        }
        $name = [System.IO.Path]::GetFileName($filePath)
        $response.StatusCode = 200
        $response.ContentType = 'application/octet-stream'
        $response.ContentLength64 = (Get-Item -LiteralPath $filePath).Length
        $response.AddHeader('Content-Disposition', "attachment; filename*=UTF-8''$([Uri]::EscapeDataString($name))")
        $inputStream = [System.IO.FileStream]::new(
            $filePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite,
            1048576,
            [System.IO.FileOptions]::SequentialScan
        )
        try {
            $inputStream.CopyTo($response.OutputStream, 1048576)
        }
        finally {
            $inputStream.Dispose()
            $response.Close()
        }
        return
    }

    if ($method -eq 'GET' -and $path -eq '/view') {
        $relativePath = Get-SafeRelativePath -Path (Get-QueryParameter -Request $request -Name 'name')
        if ($null -eq $relativePath -or $relativePath.Length -eq 0) {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Недопустимое имя файла.' }
            return
        }
        $filePath = Resolve-StoragePath -RelativePath $relativePath
        $name = [System.IO.Path]::GetFileName($filePath)
        $contentType = Get-PreviewContentType -Name $name
        if ($null -eq $contentType) {
            Send-Json -Context $Context -StatusCode 415 -Value @{ error = 'Просмотр доступен для изображений и видео поддерживаемых форматов.' }
            return
        }
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            Send-Json -Context $Context -StatusCode 404 -Value @{ error = 'Файл не найден.' }
            return
        }

        $length = [int64](Get-Item -LiteralPath $filePath).Length
        [int64]$rangeStart = 0
        [int64]$rangeEnd = $length - 1
        $partial = $false
        $rangeHeader = $request.Headers['Range']
        if (-not [string]::IsNullOrWhiteSpace($rangeHeader)) {
            $rangeMatch = [regex]::Match($rangeHeader, '^bytes=(\d*)-(\d*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $invalidRange = -not $rangeMatch.Success -or ($rangeMatch.Groups[1].Length -eq 0 -and $rangeMatch.Groups[2].Length -eq 0)
            if (-not $invalidRange) {
                try {
                    if ($rangeMatch.Groups[1].Length -eq 0) {
                        [int64]$suffixLength = $rangeMatch.Groups[2].Value
                        if ($suffixLength -le 0 -or $length -eq 0) {
                            $invalidRange = $true
                        }
                        else {
                            $rangeStart = [Math]::Max([int64]0, $length - $suffixLength)
                            $rangeEnd = $length - 1
                        }
                    }
                    else {
                        [int64]$rangeStart = $rangeMatch.Groups[1].Value
                        if ($rangeMatch.Groups[2].Length -gt 0) {
                            [int64]$rangeEnd = $rangeMatch.Groups[2].Value
                        }
                        else {
                            $rangeEnd = $length - 1
                        }
                        if ($rangeStart -ge $length -or $rangeEnd -lt $rangeStart) {
                            $invalidRange = $true
                        }
                        else {
                            $rangeEnd = [Math]::Min($rangeEnd, $length - 1)
                        }
                    }
                }
                catch {
                    $invalidRange = $true
                }
            }
            if ($invalidRange) {
                $response.AddHeader('Content-Range', "bytes */$length")
                Send-Bytes -Context $Context -StatusCode 416 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Запрошенный диапазон недоступен.'))
                return
            }
            $partial = $true
        }

        $response.StatusCode = if ($partial) { 206 } else { 200 }
        $response.ContentType = $contentType
        $response.AddHeader('Accept-Ranges', 'bytes')
        $response.AddHeader('X-Content-Type-Options', 'nosniff')
        $response.AddHeader('Cache-Control', 'private, no-store')
        $response.AddHeader('Content-Disposition', "inline; filename*=UTF-8''$([Uri]::EscapeDataString($name))")
        if ($partial) {
            $response.ContentLength64 = $rangeEnd - $rangeStart + 1
            $response.AddHeader('Content-Range', "bytes $rangeStart-$rangeEnd/$length")
        }
        else {
            $response.ContentLength64 = $length
        }

        $inputStream = [System.IO.FileStream]::new(
            $filePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite,
            1048576,
            [System.IO.FileOptions]::SequentialScan
        )
        try {
            if ($partial) { $inputStream.Position = $rangeStart }
            [int64]$remainingBytes = if ($partial) { $rangeEnd - $rangeStart + 1 } else { $length }
            $buffer = New-Object byte[] 1048576
            while ($remainingBytes -gt 0) {
                $count = [int][Math]::Min([int64]$buffer.Length, $remainingBytes)
                $read = $inputStream.Read($buffer, 0, $count)
                if ($read -le 0) { break }
                $response.OutputStream.Write($buffer, 0, $read)
                $remainingBytes -= $read
            }
        }
        finally {
            $inputStream.Dispose()
            $response.Close()
        }
        return
    }

    if ($method -eq 'PUT' -and $path -eq '/api/upload') {
        $requestedPath = Get-SafeRelativePath -Path (Get-QueryParameter -Request $request -Name 'name')
        if ($null -eq $requestedPath -or $requestedPath.Length -eq 0) {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Недопустимое имя файла.' }
            return
        }
        $separator = $requestedPath.LastIndexOf('/')
        $requestedDirectory = if ($separator -ge 0) { $requestedPath.Substring(0, $separator) } else { '' }
        $requestedName = if ($separator -ge 0) { $requestedPath.Substring($separator + 1) } else { $requestedPath }
        try {
            if ($requestedDirectory) { $null = Ensure-StorageDirectory -RelativePath $requestedDirectory }
        }
        catch {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = $_.Exception.Message }
            return
        }
        $name = Get-UniqueFileName -RelativePath $requestedPath
        $targetPath = Resolve-StoragePath -RelativePath $name
        [int64]$expectedLength = $request.ContentLength64
        [int64]$reservedForUpload = 0
        $quotaExceeded = $false
        [System.Threading.Monitor]::Enter($script:QuotaLock)
        try {
            $remaining = $script:QuotaBytes - (Get-UsedBytes) - [int64]$script:ReservedBytes['Bytes']
            if ($remaining -le 0 -or ($expectedLength -ge 0 -and $expectedLength -gt $remaining)) {
                $quotaExceeded = $true
            }
            elseif ($expectedLength -ge 0) {
                $reservedForUpload = $expectedLength
                $script:ReservedBytes['Bytes'] = [int64]$script:ReservedBytes['Bytes'] + $expectedLength
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($script:QuotaLock)
        }
        if ($quotaExceeded) {
            Release-ReservedFileName -RelativePath $name
            Send-Json -Context $Context -StatusCode 413 -Value @{ error = 'Не хватает места в хранилище.' }
            return
        }

        $targetDirectory = [System.IO.Path]::GetDirectoryName($targetPath)
        $temporaryPath = Join-Path $targetDirectory ('.upload-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $inputStream = $request.InputStream
        $fileStream = $null
        [int64]$received = 0
        try {
            try {
                $fileStream = [System.IO.FileStream]::new(
                    $temporaryPath,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None,
                    1048576,
                    [System.IO.FileOptions]::SequentialScan
                )
                $buffer = New-Object byte[] 1048576
                while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($expectedLength -lt 0) {
                        [System.Threading.Monitor]::Enter($script:QuotaLock)
                        try {
                            $remaining = $script:QuotaBytes - (Get-UsedBytes) - [int64]$script:ReservedBytes['Bytes']
                            if ($read -gt $remaining) {
                                throw [System.InvalidOperationException]::new('QUOTA_EXCEEDED')
                            }
                            $script:ReservedBytes['Bytes'] = [int64]$script:ReservedBytes['Bytes'] + $read
                            $reservedForUpload += $read
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($script:QuotaLock)
                        }
                    }
                    if ($expectedLength -ge 0 -and $received + $read -gt $expectedLength) {
                        throw [System.InvalidOperationException]::new('INVALID_CONTENT_LENGTH')
                    }
                    $fileStream.Write($buffer, 0, $read)
                    $received += $read
                }
                if ($expectedLength -ge 0 -and $received -ne $expectedLength) {
                    throw [System.IO.EndOfStreamException]::new('Загрузка завершилась до передачи всего файла.')
                }
                $fileStream.Dispose()
                $fileStream = $null
                [System.Threading.Monitor]::Enter($script:QuotaLock)
                try {
                    [System.IO.File]::Move($temporaryPath, $targetPath)
                    $script:ReservedBytes['Bytes'] = [int64]$script:ReservedBytes['Bytes'] - $reservedForUpload
                    $reservedForUpload = 0
                }
                finally {
                    [System.Threading.Monitor]::Exit($script:QuotaLock)
                }
            }
            catch {
                if ($null -ne $fileStream) { $fileStream.Dispose() }
                if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
                if ($_.Exception.Message -eq 'QUOTA_EXCEEDED') {
                    Send-Json -Context $Context -StatusCode 413 -Value @{ error = 'Файл превышает оставшееся место в хранилище.' }
                    Write-Log 'WARN' ('Upload rejected by quota: {0}' -f $name)
                    return
                }
                throw
            }
        }
        finally {
            [System.Threading.Monitor]::Enter($script:QuotaLock)
            try {
                $script:ReservedBytes['Bytes'] = [int64]$script:ReservedBytes['Bytes'] - $reservedForUpload
            }
            finally {
                [System.Threading.Monitor]::Exit($script:QuotaLock)
            }
            Release-ReservedFileName -RelativePath $name
        }
        Send-Json -Context $Context -StatusCode 201 -Value @{ uploaded = $name; requestedName = $requestedPath; renamed = $name -cne $requestedPath; size = $received }
        Write-Log 'INFO' ('Uploaded {0} ({1} bytes)' -f $name, $received)
        return
    }

    if ($method -eq 'DELETE' -and $path -eq '/api/files') {
        $name = Get-SafeRelativePath -Path (Get-QueryParameter -Request $request -Name 'name')
        if ($null -eq $name -or $name.Length -eq 0) {
            Send-Json -Context $Context -StatusCode 400 -Value @{ error = 'Недопустимое имя файла.' }
            return
        }
        $filePath = Resolve-StoragePath -RelativePath $name
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            Send-Json -Context $Context -StatusCode 404 -Value @{ error = 'Файл не найден.' }
            return
        }
        Remove-Item -LiteralPath $filePath -Force
        Send-Json -Context $Context -StatusCode 200 -Value @{ deleted = $name }
        Write-Log 'INFO' ('Deleted {0}' -f $name)
        return
    }

    Send-Json -Context $Context -StatusCode 404 -Value @{ error = 'Страница не найдена.' }
}

if (-not (Test-Path -LiteralPath $script:StoragePath -PathType Container)) {
    New-Item -ItemType Directory -Path $script:StoragePath -Force | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($env:HOUSE_SHARE_PASSWORD)) {
    $script:AccessPassword = $env:HOUSE_SHARE_PASSWORD
    Remove-Item Env:\HOUSE_SHARE_PASSWORD
}
else {
    do {
        $securePassword = Read-Host -Prompt 'Придумайте пароль для друзей' -AsSecureString
    } while ($securePassword.Length -eq 0)
    $passwordPointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $script:AccessPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
}

$listener = New-Object System.Net.HttpListener
$prefixAddress = if ($BindAddress -eq '+') { '+' } else { $BindAddress }
$prefix = 'http://{0}:{1}/' -f $prefixAddress, $Port
$listener.Prefixes.Add($prefix)

$serverTokens = $null
$serverParseErrors = $null
$serverAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$serverTokens, [ref]$serverParseErrors)
if ($serverParseErrors.Count -gt 0) {
    throw 'Не удалось подготовить обработчик запросов сервера.'
}
$functionSource = ($serverAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
$workerScript = @'
param(
    $Context,
    $StoragePath,
    $QuotaBytes,
    $LogPath,
    $ThemeImagePath,
    $AccessPassword,
    $BindAddress,
    $DebugModeValue,
    $DeviceActivity,
    $DeviceLock,
    $QuotaLock,
    $ReservedBytes,
    $NameLock,
    $ReservedNames,
    $LogLock
)
$script:StoragePath = $StoragePath
$script:QuotaBytes = $QuotaBytes
$script:LogPath = $LogPath
$script:ThemeImagePath = $ThemeImagePath
$script:AccessPassword = $AccessPassword
$script:BindAddress = $BindAddress
$script:DeviceActivity = $DeviceActivity
$script:DeviceLock = $DeviceLock
$script:QuotaLock = $QuotaLock
$script:ReservedBytes = $ReservedBytes
$script:NameLock = $NameLock
$script:ReservedNames = $ReservedNames
$script:LogLock = $LogLock
$ErrorActionPreference = 'Stop'
$DebugMode = $DebugModeValue
'@ + [Environment]::NewLine + $functionSource + [Environment]::NewLine + @'
try {
    Handle-Request -Context $Context
}
catch {
    Write-Log 'ERROR' ('{0} {1}: {2}' -f $Context.Request.HttpMethod, $Context.Request.Url.PathAndQuery, $_.Exception.Message)
    try {
        Send-Json -Context $Context -StatusCode 500 -Value @{ error = 'Внутренняя ошибка сервера. Подробности записаны в журнал.' }
    }
    catch {
        $Context.Response.Close()
    }
}
'@
$runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 8)
$pendingRequests = New-Object 'System.Collections.Generic.List[object]'

try {
    $listener.Start()
    $runspacePool.Open()
    Write-Log 'INFO' ('Хранилище запущено: {0} ; папка: {1} ; лимит: {2} ГБ' -f $prefix, $script:StoragePath, $MaxGB)
    Write-Log 'INFO' ('Журнал отладки: {0}' -f $script:LogPath)
    Write-Log 'INFO' 'Для остановки нажмите Ctrl+C. Одновременно обрабатывается до восьми запросов.'
    while ($listener.IsListening) {
        $context = $null
        try {
            $context = $listener.GetContext()
        }
        catch [System.Net.HttpListenerException] {
            if ($listener.IsListening) {
                Write-Log 'ERROR' $_.Exception.Message
            }
            continue
        }

        for ($index = $pendingRequests.Count - 1; $index -ge 0; $index--) {
            $pending = $pendingRequests[$index]
            if ($pending.Handle.IsCompleted) {
                try {
                    $null = $pending.PowerShell.EndInvoke($pending.Handle)
                    foreach ($streamError in $pending.PowerShell.Streams.Error) {
                        Write-Log 'ERROR' ('Request worker: {0}' -f $streamError.Exception.Message)
                    }
                }
                catch {
                    Write-Log 'ERROR' ('Request worker: {0}' -f $_.Exception.Message)
                }
                finally {
                    $pending.PowerShell.Dispose()
                    $pendingRequests.RemoveAt($index)
                }
            }
        }

        $worker = [System.Management.Automation.PowerShell]::Create()
        try {
            $worker.RunspacePool = $runspacePool
            $null = $worker.AddScript($workerScript).
                AddArgument($context).
                AddArgument($script:StoragePath).
                AddArgument($script:QuotaBytes).
                AddArgument($script:LogPath).
                AddArgument($script:ThemeImagePath).
                AddArgument($script:AccessPassword).
                AddArgument($script:BindAddress).
                AddArgument([bool]$DebugMode).
                AddArgument($script:DeviceActivity).
                AddArgument($script:DeviceLock).
                AddArgument($script:QuotaLock).
                AddArgument($script:ReservedBytes).
                AddArgument($script:NameLock).
                AddArgument($script:ReservedNames).
                AddArgument($script:LogLock)
            $handle = $worker.BeginInvoke()
            $pendingRequests.Add([pscustomobject]@{ PowerShell = $worker; Handle = $handle })
        }
        catch {
            $worker.Dispose()
            Write-Log 'ERROR' ('Could not queue request: {0}' -f $_.Exception.Message)
            try {
                Send-Json -Context $context -StatusCode 500 -Value @{ error = 'Не удалось обработать запрос.' }
            }
            catch {
                $context.Response.Close()
            }
        }
    }
}
catch [System.Net.HttpListenerException] {
    if ($_.Exception.NativeErrorCode -eq 5) {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $command = 'netsh http add urlacl url={0} user="{1}"' -f $prefix, $user
        $message = 'Windows не разрешил запуск HttpListener. Откройте PowerShell от имени администратора и один раз выполните: ' + $command
        Write-Log 'ERROR' $message
        throw $message
    }
    Write-Log 'ERROR' $_.Exception.Message
    throw
}
catch [System.UnauthorizedAccessException] {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $command = 'netsh http add urlacl url={0} user="{1}"' -f $prefix, $user
    $message = 'Нет разрешения HttpListener. Откройте PowerShell от имени администратора и один раз выполните: ' + $command
    Write-Log 'ERROR' $message
    throw $message
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    foreach ($pending in $pendingRequests) {
        try {
            $pending.PowerShell.Stop()
        }
        catch {
            Write-Log 'WARN' ('Could not stop request worker: {0}' -f $_.Exception.Message)
        }
        $pending.PowerShell.Dispose()
    }
    if ($runspacePool.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
        $runspacePool.Close()
    }
    $runspacePool.Dispose()
    Write-Log 'INFO' 'Сервер остановлен.'
}
