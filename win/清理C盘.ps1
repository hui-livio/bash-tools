#Requires -Version 5.1
<#
================================================================================
  C 盘磁盘清理工具（安全版）  v1.1
================================================================================
  作用：安全清理 C 盘中的临时文件、缓存文件、过期日志、回收站等，释放磁盘空间。

  安全原则（请先读一遍）：
    1. 只清理「系统缓存 / 临时文件 / 过期日志」，绝不触碰 桌面、文档、下载、
       图片、视频 等个人文件；
    2. 默认先「预览扫描」—— 只统计文件数量和大小，不删除；你确认后才真正删除；
    3. 每一项清理都在菜单里明确列出，不会偷偷删任何东西；
    4. 正在被占用 / 锁定的文件会自动跳过，不会强行破坏系统运行；
    5. 全部使用文件级删除，失败的项目单独统计并报告。

  运行方式：
    powershell -NoProfile -ExecutionPolicy Bypass -File ".\清理C盘.ps1"
    或直接双击同目录下的「一键运行(管理员).bat」

  可选参数：
    -Auto           一键安全清理（跳过菜单，仍需确认）
    -Items 1,2,7    指定要清理的项目编号，逗号分隔
    -Days 7         只清理 7 天前的「过期」文件（默认 0 = 不限时间）
    -Yes            跳过最终确认（危险，谨慎使用）
    -NoLog          不生成日志文件
================================================================================
#>

[CmdletBinding()]
param(
    [switch]$Auto,
    [int[]]$Items = @(),
    [int]$Days = 0,
    [switch]$Yes,
    [switch]$NoLog
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ══════════════════════════ 全局状态 ══════════════════════════
$script:LogLines   = New-Object System.Collections.Generic.List[string]
$script:LogPath    = $null
$script:IsAdmin    = $false
$script:StartFree  = 0.0
$script:StartTotal = 0.0
$script:DaysFilter = $Days

$SafeSet = @(1, 2, 3, 4, 8, 10)   # 一键安全清理的项目编号

# ══════════════════════════ 基础工具函数 ══════════════════════════

function Write-Log {
    param(
        [string]$Message = '',
        [string]$Color = 'Gray',
        [switch]$NoNewline
    )
    if ($NoNewline) { Write-Host $Message -ForegroundColor $Color -NoNewline }
    else            { Write-Host $Message -ForegroundColor $Color }
    $script:LogLines.Add($Message)
}

function Write-Rule {
    param([string]$Char = '─', [int]$Width = 76, [string]$Color = 'DarkGray')
    Write-Log ('  ' + ($Char * $Width)) $Color
}

# 中英文混排时的显示宽度（中日韩字符按 2 个字符宽度计算）
function Get-StrWidth {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int][char]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 }
        else { $w += 1 }
    }
    return $w
}

function Format-Pad {
    param([string]$Text, [int]$Width)
    $w = Get-StrWidth $Text
    if ($w -ge $Width) { return $Text }
    return $Text + (' ' * ($Width - $w))
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-CFreeSpace {
    try {
        $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        return @{ Free = [double]$d.FreeSpace; Total = [double]$d.Size }
    } catch {
        $d = Get-PSDrive -Name C -ErrorAction SilentlyContinue
        return @{ Free = [double]$d.Free; Total = [double]($d.Free + $d.Used) }
    }
}

function Get-PathStat {
    param([string]$Path)
    $size = 0.0; $count = 0
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            $size += [double]$f.Length
            $count++
        }
    } catch { }
    return [pscustomobject]@{ Size = $size; Count = $count }
}

function Test-Filter {
    param([string]$Name, [string[]]$Filter)
    if (-not $Filter -or $Filter.Count -eq 0) { return $true }
    foreach ($f in $Filter) { if ($Name -like $f) { return $true } }
    return $false
}

# ══════════════════════════ 清理项定义 ══════════════════════════

function New-CleanItem {
    param(
        [int]$Id,
        [string]$Name,
        [string]$Note = '',
        [switch]$NeedAdmin,
        [string]$Kind = 'Files',
        [scriptblock]$Resolve,
        [string[]]$Filter = @('*'),
        [switch]$NoRecurse,
        [scriptblock]$PreAction,
        [scriptblock]$PostAction,
        [string]$ConfirmText = ''
    )
    [pscustomobject]@{
        Id          = $Id
        Name        = $Name
        Note        = $Note
        NeedAdmin   = [bool]$NeedAdmin
        Kind        = $Kind
        Resolve     = $Resolve
        Filter      = $Filter
        Recurse     = (-not $NoRecurse)
        PreAction   = $PreAction
        PostAction  = $PostAction
        ConfirmText = $ConfirmText
    }
}

$CleanItems = @(
    (New-CleanItem -Id 1 -Name '用户临时文件' -Note '当前用户 Temp 目录：安装残留、程序缓存' -Resolve {
        @($env:TEMP, $env:TMP, (Join-Path $env:LOCALAPPDATA 'Temp'))
    }),

    (New-CleanItem -Id 2 -Name '系统临时文件' -Note 'Windows\Temp：系统级临时文件' -NeedAdmin -Resolve {
        @((Join-Path $env:SystemRoot 'Temp'))
    }),

    (New-CleanItem -Id 3 -Name '浏览器缓存' -Note 'Edge / Chrome 网页缓存（建议先关闭浏览器）' -Resolve {
        $edge   = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default'
        $chrome = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default'
        @(
            (Join-Path $edge   'Cache'),
            (Join-Path $edge   'Code Cache'),
            (Join-Path $edge   'GPUCache'),
            (Join-Path $edge   'Service Worker\CacheStorage'),
            (Join-Path $chrome 'Cache'),
            (Join-Path $chrome 'Code Cache'),
            (Join-Path $chrome 'GPUCache'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache')
        )
    }),

    (New-CleanItem -Id 4 -Name '缩略图/图标缓存' -Note '清理后缩略图会重建，不影响原文件' -Filter @('*.db') -Resolve {
        @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Caches')
        )
    }),

    (New-CleanItem -Id 5 -Name 'Windows 更新缓存' -Note '已下载的更新安装包，会自动重新下载' -NeedAdmin -Resolve {
        @((Join-Path $env:SystemRoot 'SoftwareDistribution\Download'))
    } -PreAction {
        $stopped = New-Object System.Collections.Generic.List[string]
        foreach ($s in @('wuauserv', 'bits', 'dosvc')) {
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
                $stopped.Add($s)
            }
        }
        Start-Sleep -Milliseconds 500
        return $stopped.ToArray()
    } -PostAction {
        foreach ($s in @('wuauserv', 'bits', 'dosvc')) {
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -ne 'Disabled' -and $svc.Status -ne 'Running') {
                Start-Service -Name $s -ErrorAction SilentlyContinue
            }
        }
    }),

    (New-CleanItem -Id 6 -Name '传递优化缓存' -Note 'Windows 更新 P2P 分发缓存' -NeedAdmin -Kind 'DO'),

    (New-CleanItem -Id 7 -Name '回收站' -Note '清空回收站：删除后无法找回！' -Kind 'RecycleBin'),

    (New-CleanItem -Id 8 -Name '系统日志与转储' -Note 'CBS/DISM 日志、内存转储、崩溃报告' -NeedAdmin -Resolve {
        @(
            (Join-Path $env:SystemRoot 'Logs\CBS'),
            (Join-Path $env:SystemRoot 'Logs\DISM'),
            (Join-Path $env:SystemRoot 'Logs\WindowsUpdate'),
            (Join-Path $env:SystemRoot 'Minidump'),
            (Join-Path $env:SystemRoot 'MEMORY.DMP'),
            (Join-Path $env:LOCALAPPDATA 'CrashDumps')
        )
    }),

    (New-CleanItem -Id 9 -Name '预读取文件' -Note 'Prefetch：删除后首次启动略慢，会重建' -NeedAdmin -Filter @('*.pf') -NoRecurse -Resolve {
        @((Join-Path $env:SystemRoot 'Prefetch'))
    }),

    (New-CleanItem -Id 10 -Name '开发工具缓存' -Note 'pip/npm/yarn/NuGet/Go 缓存，下次构建会重新下载' -Resolve {
        @(
            (Join-Path $env:LOCALAPPDATA 'pip\Cache'),
            (Join-Path $env:LOCALAPPDATA 'pip\cache'),
            (Join-Path $env:LOCALAPPDATA 'npm-cache'),
            (Join-Path $env:APPDATA      'npm-cache'),
            (Join-Path $env:LOCALAPPDATA 'Yarn\Cache'),
            (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache'),
            (Join-Path $env:USERPROFILE  '.nuget\packages'),
            (Join-Path $env:LOCALAPPDATA 'go-build')
        )
    }),

    (New-CleanItem -Id 11 -Name '组件存储清理' -Note 'DISM 清理 WinSxS 旧组件，耗时可能 5~20 分钟' -NeedAdmin -Kind 'Dism'),

    (New-CleanItem -Id 12 -Name '旧版 Windows 安装' -Note 'C:\Windows.old：升级前的旧系统（体积很大）' -NeedAdmin -Kind 'WinOld' `
        -ConfirmText 'Windows.old 删除后无法回退到旧版本 Windows，且过程可能持续数分钟。')
)

# ══════════════════════════ 扫描 / 计划 ══════════════════════════

function Get-FilesToClean {
    param([object]$Item, [int]$Days)

    $targets = New-Object System.Collections.Generic.List[object]
    if (-not $Item.Resolve) { return $targets }

    $paths = @(& $Item.Resolve) | Where-Object { $_ } | Select-Object -Unique

    foreach ($p in $paths) {
        foreach ($it in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
            if ($it.PSIsContainer) {
                if ($Item.Recurse) {
                    $files = @(Get-ChildItem -LiteralPath $it.FullName -File -Recurse -Force -ErrorAction SilentlyContinue)
                } else {
                    $files = @(Get-ChildItem -LiteralPath $it.FullName -File -Force -ErrorAction SilentlyContinue)
                }
                foreach ($f in $files) {
                    if (Test-Filter -Name $f.Name -Filter $Item.Filter) { $targets.Add($f) }
                }
            } else {
                if (Test-Filter -Name $it.Name -Filter $Item.Filter) { $targets.Add($it) }
            }
        }
    }

    if ($Days -gt 0) {
        $cutoff = (Get-Date).AddDays(-$Days)
        $targets = @($targets | Where-Object { $_.LastWriteTime -lt $cutoff })
    }
    return $targets
}

function New-Plan {
    param([object]$Item, [int]$Days)

    $plan = [pscustomobject]@{
        Item      = $Item
        Files     = @()
        Size      = [double]0
        Count     = 0
        Runnable  = $true
        Reason    = ''
        ExtraNote = ''
    }

    switch ($Item.Kind) {

        'Dism' {
            $plan.ExtraNote = '无法预估大小，通常可释放数百 MB ~ 数 GB'
            return $plan
        }

        'WinOld' {
            $wo = Join-Path $env:SystemDrive 'Windows.old'
            if (-not (Test-Path -LiteralPath $wo)) {
                $plan.Runnable = $false
                $plan.Reason   = '未发现 C:\Windows.old，无需清理'
                return $plan
            }
            $st = Get-PathStat -Path $wo
            $plan.Size      = $st.Size
            $plan.Count     = $st.Count
            $plan.ExtraNote = '需二次输入 YES 确认'
            return $plan
        }

        'RecycleBin' {
            $st = Get-PathStat -Path ($env:SystemDrive + '$Recycle.Bin')
            $plan.Size  = $st.Size
            $plan.Count = $st.Count
            if ($st.Count -eq 0) { $plan.ExtraNote = '（可能为空，或需管理员权限才能统计）' }
            return $plan
        }

        'DO' {
            if (-not (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
                $plan.Runnable = $false
                $plan.Reason   = '当前系统不支持该命令，已跳过'
                return $plan
            }
            $plan.ExtraNote = '由系统托管，无法预估大小'
            return $plan
        }
    }

    $files = @(Get-FilesToClean -Item $Item -Days $Days)
    $sum   = 0.0
    foreach ($f in $files) { $sum += [double]$f.Length }

    $plan.Files = $files
    $plan.Count = $files.Count
    $plan.Size  = $sum
    if ($files.Count -eq 0) { $plan.ExtraNote = '没有可清理的文件' }
    return $plan
}

# ══════════════════════════ 执行清理 ══════════════════════════

function Remove-EmptyDirs {
    param([string]$Path)
    $dirs = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
              Sort-Object { $_.FullName.Length } -Descending)
    foreach ($d in $dirs) {
        $children = @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            Remove-Item -LiteralPath $d.FullName -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-FileClean {
    param([object]$Plan)

    $it = $Plan.Item
    $stopped = @()
    if ($it.PreAction) {
        try { $stopped = @(& $it.PreAction) } catch { }
        if ($stopped.Count -gt 0) { Write-Log ('    已暂停服务：' + ($stopped -join ', ')) DarkGray }
    }

    $deleted = 0; $failed = 0; $freed = 0.0
    $total   = @($Plan.Files).Count
    $shown   = 0

    foreach ($f in @($Plan.Files)) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -Recurse -ErrorAction Stop
            $deleted++
            $freed += [double]$f.Length
        } catch {
            $failed++
        }
        $shown++
        if ($total -gt 3000 -and ($shown % 1000 -eq 0)) {
            Write-Host ("`r    正在删除… {0}/{1} 个文件" -f $shown, $total) -ForegroundColor DarkGray -NoNewline
        }
    }
    if ($total -gt 3000) { Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline }

    # 清理残留的空目录（原目录本身保留）
    if ($it.Resolve) {
        foreach ($p in (@(& $it.Resolve) | Where-Object { $_ } | Select-Object -Unique)) {
            foreach ($d in @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue)) {
                if ($d.PSIsContainer) { Remove-EmptyDirs -Path $d.FullName }
            }
        }
    }

    if ($it.PostAction) { try { & $it.PostAction | Out-Null } catch { } }

    return [pscustomobject]@{ Ok = $true; Freed = $freed; Deleted = $deleted; Failed = $failed; Msg = '' }
}

function Invoke-Dism {
    Write-Log '    正在执行 DISM 组件清理，请耐心等待（可能数分钟）…' DarkGray
    $p = Start-Process -FilePath 'dism.exe' `
         -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup' `
         -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -eq 0) {
        return [pscustomobject]@{ Ok = $true; Freed = 0.0; Deleted = 0; Failed = 0; Msg = 'DISM 组件清理完成（释放量请对比前后可用空间）' }
    }
    return [pscustomobject]@{ Ok = $false; Freed = 0.0; Deleted = 0; Failed = 0; Msg = ('DISM 返回代码 ' + $p.ExitCode) }
}

function Invoke-RecycleBin {
    try {
        if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath ($env:SystemDrive + '$Recycle.Bin') -Recurse -Force -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{ Ok = $true; Freed = 0.0; Deleted = 0; Failed = 0; Msg = '回收站已清空' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Freed = 0.0; Deleted = 0; Failed = 0; Msg = '回收站清空失败' }
    }
}

function Invoke-DeliveryOptimization {
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Freed = 0.0; Deleted = 0; Failed = 0; Msg = '传递优化缓存已清理' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Freed = 0.0; Deleted = 0; Failed = 0; Msg = '传递优化缓存清理失败' }
    }
}

function Invoke-WindowsOld {
    param([object]$Plan)

    $wo = Join-Path $env:SystemDrive 'Windows.old'
    Write-Log '    正在接管 C:\Windows.old 的所有权（数据量大时较慢）…' DarkGray
    & takeown.exe /f $wo /r /d y  *> $null
    & icacls.exe  $wo /grant '*S-1-5-32-544:F' /t /c /q *> $null

    Write-Log '    正在删除…' DarkGray
    Remove-Item -LiteralPath $wo -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $wo) {
        $left = Get-PathStat -Path $wo
        return [pscustomobject]@{ Ok = $false; Freed = ($Plan.Size - $left.Size); Deleted = 0; Failed = 0;
                                  Msg = ('未完全删除，剩余 ' + (Format-Size $left.Size) + '（部分文件被占用，可重启后重试）') }
    }
    return [pscustomobject]@{ Ok = $true; Freed = $Plan.Size; Deleted = 0; Failed = 0; Msg = 'Windows.old 已删除' }
}

function Invoke-Plan {
    param([object]$Plan)

    $it = $Plan.Item
    Write-Log ''
    Write-Log ('  ▶ ' + $it.Name) Cyan

    if ($it.ConfirmText) {
        Write-Log ('    [!] ' + $it.ConfirmText) Yellow
        $ans = Read-Host '    确认继续请输入 YES（其他任意内容跳过此项）'
        if ($ans -notmatch '^(yes|YES|Yes)$') {
            Write-Log '    已跳过。' DarkYellow
            return [pscustomobject]@{ Ok = $true; Skipped = $true; Freed = 0.0; Deleted = 0; Failed = 0; Msg = '' }
        }
    }

    switch ($it.Kind) {
        'Dism'       { $r = Invoke-Dism; break }
        'RecycleBin' { $r = Invoke-RecycleBin; break }
        'DO'         { $r = Invoke-DeliveryOptimization; break }
        'WinOld'     { $r = Invoke-WindowsOld -Plan $Plan; break }
        default      { $r = Invoke-FileClean -Plan $Plan }
    }

    $r | Add-Member -NotePropertyName Skipped -NotePropertyValue $false -Force

    if ($r.Ok) {
        if ($r.Deleted -gt 0) {
            Write-Log ('    [√] 删除 ' + $r.Deleted + ' 个文件，释放 ' + (Format-Size $r.Freed)) Green
        } else {
            Write-Log ('    [√] ' + $r.Msg) Green
        }
        if ($r.Failed -gt 0) { Write-Log ('    [!] ' + $r.Failed + ' 个文件被占用，已自动跳过') DarkYellow }
    } else {
        Write-Log ('    [×] ' + $r.Msg) Red
    }
    return $r
}

# ══════════════════════════ 界面 ══════════════════════════

function Show-Banner {
    $sp = Get-CFreeSpace
    $script:StartFree  = $sp.Free
    $script:StartTotal = $sp.Total

    Write-Log ''
    Write-Log ('  ' + ('═' * 76)) Cyan
    Write-Log '    C 盘磁盘清理工具  v1.1' Cyan
    Write-Log ('  ' + ('═' * 76)) Cyan
    Write-Log ('    当前 C 盘：可用 ' + (Format-Size $script:StartFree) + '  /  共 ' + (Format-Size $script:StartTotal) +
               '  （已用 ' + (Format-Size ($script:StartTotal - $script:StartFree)) + '）') White
    if ($script:IsAdmin) {
        Write-Log '    运行权限：管理员（可清理全部项目）' Green
    } else {
        Write-Log '    运行权限：普通用户（标有「需管理员」的项目将被跳过）' Yellow
    }
    if ($script:DaysFilter -gt 0) {
        Write-Log ('    时间筛选：仅清理 ' + $script:DaysFilter + ' 天前的过期文件') White
    } else {
        Write-Log '    时间筛选：不限时间' White
    }
}

function Show-Menu {
    Write-Log ''
    Write-Rule
    Write-Log '    请选择要清理的项目（可多选）' White
    Write-Rule
    Write-Log ('    ' + (Format-Pad '编号' 6) + (Format-Pad '项目' 22) + '说明') DarkGray
    foreach ($it in $CleanItems) {
        $tag  = ''
        if ($it.NeedAdmin -and -not $script:IsAdmin) { $tag = '  [需管理员]' }
        $line = '    ' + (Format-Pad ('[' + [string]$it.Id + ']') 6) + (Format-Pad $it.Name 22) + $it.Note + $tag
        if ($tag) { Write-Log $line DarkGray } else { Write-Log $line Gray }
    }
    Write-Rule
    Write-Log ('    [A] 一键安全清理（推荐：' + ($SafeSet -join ',') + '）') Green
    Write-Log ('    [D] 设置时间筛选（当前：' + $(if ($script:DaysFilter -gt 0) { '仅 ' + $script:DaysFilter + ' 天前' } else { '不限' }) + '）') Cyan
    Write-Log '    [Q] 退出' DarkGray
    Write-Log ''
}

function Read-Selection {
    while ($true) {
        Show-Menu
        $raw = Read-Host '    请输入编号（如 1,3,7），或 A / D / Q'
        if ($null -eq $raw) { return $null }
        $raw = $raw.Trim()
        if ($raw -eq '') { continue }

        if ($raw -match '^(q|quit|exit|退出)$') { return $null }

        if ($raw -match '^(a|all|一键)$') { return $SafeSet }

        if ($raw -match '^(d|days|天数)$') {
            $d = Read-Host '    请输入天数（只清理 N 天前的文件，0 = 不限）'
            if ($d -match '^\d+$') {
                $script:DaysFilter = [int]$d
                Write-Log ('    [√] 已设置为：' + $(if ($script:DaysFilter -gt 0) { '仅清理 ' + $script:DaysFilter + ' 天前的文件' } else { '不限时间' })) Green
            } else {
                Write-Log '    [!] 输入无效，未修改。' Yellow
            }
            continue
        }

        $ok  = $true
        $ids = New-Object System.Collections.Generic.List[int]
        foreach ($part in ($raw -split '[,，、;；\s]+')) {
            if ($part -eq '') { continue }
            if ($part -notmatch '^\d+$') { $ok = $false; break }
            $n = [int]$part
            $hit = $CleanItems | Where-Object { $_.Id -eq $n }
            if (-not $hit) { $ok = $false; break }
            if (-not $ids.Contains($n)) { $ids.Add($n) }
        }
        if ($ok -and $ids.Count -gt 0) { return $ids.ToArray() }
        Write-Log '    [!] 输入无效，请重新输入（示例：1,3,7）。' Yellow
    }
}

# ══════════════════════════ 主流程 ══════════════════════════

function Start-Cleanup {

    # ---- 日志文件 ----
    if (-not $NoLog) {
        $baseDir = $PSScriptRoot
        if (-not $baseDir) { $baseDir = [Environment]::GetFolderPath('Desktop') }
        $script:LogPath = Join-Path $baseDir ('C盘清理日志_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }

    $script:IsAdmin = Test-Admin
    Show-Banner

    # ---- 选择清理项 ----
    if ($Auto) {
        $selected = $SafeSet
        Write-Log ''
        Write-Log ('    [一键安全清理] 已选中项目：' + ($selected -join ', ')) Cyan
    } elseif ($Items.Count -gt 0) {
        $validIds = @($CleanItems | ForEach-Object { $_.Id })
        $selected = @($Items | Where-Object { $validIds -contains $_ })
        if ($selected.Count -eq 0) {
            Write-Log '    [!] 指定的项目编号无效。' Red
            return
        }
    } else {
        $selected = Read-Selection
        if (-not $selected -or $selected.Count -eq 0) {
            Write-Log ''
            Write-Log '    已退出，未做任何修改。' Yellow
            return
        }
    }

    # ---- 预览扫描 ----
    Write-Log ''
    Write-Rule '═'
    Write-Log '    [预览模式] 正在扫描，只统计不删除，请稍候……' Cyan
    Write-Rule '═'

    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($id in $selected) {
        $it = $CleanItems | Where-Object { $_.Id -eq $id }
        if (-not $it) { continue }

        if ($it.NeedAdmin -and -not $script:IsAdmin) {
            Write-Log ('    [跳过] ' + (Format-Pad $it.Name 22) + ' 需要管理员权限') Yellow
            continue
        }
        $plans.Add((New-Plan -Item $it -Days $script:DaysFilter))
    }

    Write-Log ''
    Write-Rule
    Write-Log ('    ' + (Format-Pad '项目' 22) + (Format-Pad '可释放' 12) + '文件数') DarkGray
    Write-Rule

    $totalSize = 0.0; $totalCount = 0; $runnable = 0
    foreach ($p in $plans) {
        if (-not $p.Runnable) {
            Write-Log ('    ' + (Format-Pad $p.Item.Name 22) + $p.Reason) DarkGray
            continue
        }
        $runnable++
        $sizeTxt = Format-Size $p.Size
        $cntTxt  = $(if ($p.Item.Kind -eq 'Files') { ('{0:N0} 个' -f $p.Count) } else { '—' })
        Write-Log ('    ' + (Format-Pad $p.Item.Name 22) + (Format-Pad $sizeTxt 12) + $cntTxt +
                   $(if ($p.ExtraNote) { '   ' + $p.ExtraNote } else { '' })) White
        if ($p.Item.Kind -eq 'Files') { $totalSize += $p.Size; $totalCount += $p.Count }
    }
    Write-Rule
    Write-Log ('    合计可释放：' + (Format-Size $totalSize) + '（' + ('{0:N0}' -f $totalCount) + ' 个文件，系统级项目需执行后对比）') Green
    Write-Log ''
    Write-Log '    提示：正在运行的程序会占用部分缓存文件，被占用的文件会自动跳过。' DarkGray
    Write-Log '    本次清理不会触碰 桌面 / 文档 / 下载 / 图片 / 视频 等个人文件。' DarkGray

    if ($runnable -eq 0) {
        Write-Log ''
        Write-Log '    没有可执行的清理项。' Yellow
        return
    }

    # ---- 确认 ----
    if (-not $Yes) {
        Write-Log ''
        $ans = Read-Host '    确认执行清理？(输入 Y 确认，其他任意键取消)'
        if ($ans -notmatch '^(y|Y|yes|YES|是)$') {
            Write-Log '    已取消，未删除任何文件。' Yellow
            return
        }
    }

    # ---- 执行 ----
    Write-Log ''
    Write-Rule '═'
    Write-Log '    [执行清理]' Cyan
    Write-Rule '═'

    $sumFreed = 0.0; $sumDeleted = 0; $sumFailed = 0; $errCount = 0
    foreach ($p in $plans) {
        if (-not $p.Runnable) { continue }
        $r = Invoke-Plan -Plan $p
        if ($r.Skipped) { continue }
        if ($r.Ok) { $sumFreed += $r.Freed; $sumDeleted += $r.Deleted; $sumFailed += $r.Failed }
        else       { $errCount++ }
    }

    # ---- 报告 ----
    Start-Sleep -Milliseconds 800
    $end = Get-CFreeSpace
    $delta = $end.Free - $script:StartFree

    Write-Log ''
    Write-Rule '═'
    Write-Log '    清理完成' Green
    Write-Rule '═'
    Write-Log ('    已删除文件：' + ('{0:N0}' -f $sumDeleted) + ' 个' + $(if ($sumFailed -gt 0) { '（另有 ' + $sumFailed + ' 个被占用已跳过）' } else { '' })) White
    Write-Log ('    文件清理释放：' + (Format-Size $sumFreed)) White
    Write-Log ('    C 盘可用空间：' + (Format-Size $script:StartFree) + '  →  ' + (Format-Size $end.Free) +
               '   （净增 ' + (Format-Size $(if ($delta -gt 0) { $delta } else { 0 })) + '）') Green
    Write-Rule

    if ($errCount -gt 0) {
        Write-Log ('    [!] 有 ' + $errCount + ' 个项目执行失败，详见上方日志。') Yellow
    }
    if (-not $script:IsAdmin) {
        Write-Log '' 
        Write-Log '    提示：以「管理员身份」重新运行可清理更多项目（系统临时文件、' DarkGray
        Write-Log '          Windows 更新缓存、系统日志、DISM 组件、Windows.old 等）。' DarkGray
    }
    Write-Log ''
    Write-Log '    其他可进一步释放 C 盘空间的手段（需自行确认）：' DarkGray
    Write-Log '      · 关闭休眠删除休眠文件：管理员执行  powercfg /h off （可释放数 GB）' DarkGray
    Write-Log '      · 压缩 WSL 虚拟磁盘：wsl --shutdown 后用 diskpart 的 compact vdisk' DarkGray

    if ($script:LogPath) {
        Write-Log ''
        Write-Log ('    日志已保存：' + $script:LogPath) DarkGray
    }
}

# ══════════════════════════ 入口 ══════════════════════════

try {
    Start-Cleanup
} catch {
    Write-Host ''
    Write-Host ('  程序出现异常：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('  位置：' + $_.InvocationInfo.ScriptLineNumber) -ForegroundColor DarkGray
} finally {
    if (-not $NoLog -and $script:LogPath -and $script:LogLines.Count -gt 0) {
        try { $script:LogLines | Out-File -LiteralPath $script:LogPath -Encoding UTF8 } catch { }
    }
}
