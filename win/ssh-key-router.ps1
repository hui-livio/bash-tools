# ============================================================
# ssh-key-router.ps1 - Create SSH keys and configure per-platform routing
#
# Usage:
#   .\ssh-key-router.ps1 add <github|gitlab|gitee>
#   .\ssh-key-router.ps1 add custom [name]
#   .\ssh-key-router.ps1 remove <name>
#   .\ssh-key-router.ps1 list
#
# Each platform gets an independent id_ed25519_<name> key. The remove
# command permanently deletes the selected key pair and managed config block.
# ============================================================

$ErrorActionPreference = 'Stop'
$script:ScriptPath = $PSCommandPath

$script:SshDirectory = if ($env:SSH_KEY_DIR) {
    $env:SSH_KEY_DIR
} else {
    Join-Path $HOME '.ssh'
}
$script:ConfigFile = Join-Path $script:SshDirectory 'config'
$script:KnownHostsFile = Join-Path $script:SshDirectory 'known_hosts'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "[警告] $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "[错误] $Message" -ForegroundColor Red
}

function Show-Usage {
    @'
用法：
  .\ssh-key-router.ps1 add <github|gitlab|gitee>  新建预设平台密钥并配置路由
  .\ssh-key-router.ps1 add custom [名称]           新建自定义平台密钥并配置路由
  .\ssh-key-router.ps1 remove <平台名>             永久删除密钥和路由区块
  .\ssh-key-router.ps1 list                        查看已配置的平台路由

示例：
  .\ssh-key-router.ps1 add github
  .\ssh-key-router.ps1 add custom work
  .\ssh-key-router.ps1 remove work
'@ | Write-Host
}

function Test-PlatformName {
    param([string]$Name)
    return $Name -match '^[a-zA-Z0-9][a-zA-Z0-9_-]*$'
}

function Resolve-Platform {
    param(
        [string]$PlatformType,
        [string]$PlatformName
    )

    $script:Platform = $PlatformName
    switch ($PlatformType) {
        'github' {
            $script:GitHost = 'github.com'
            $script:ConnectHost = 'ssh.github.com'
            $script:Port = 443
            $script:KeyUrl = 'https://github.com/settings/keys'
            $script:Note = 'GitHub 官方，走 ssh.github.com:443 通道（22 端口常被代理环境拦截）'
        }
        'gitlab' {
            $script:GitHost = 'gitlab.com'
            $script:ConnectHost = 'gitlab.com'
            $script:Port = 22
            $script:KeyUrl = 'https://gitlab.com/-/user_settings/ssh_keys'
            $script:Note = 'gitlab.com 公共站；私有部署的 GitLab 请使用 custom 模式'
        }
        'gitee' {
            $script:GitHost = 'gitee.com'
            $script:ConnectHost = 'gitee.com'
            $script:Port = 22
            $script:KeyUrl = 'https://gitee.com/profile/sshkeys'
            $script:Note = 'Gitee（码云）'
        }
        'custom' {
            $script:Note = '自建平台（如私有 GitLab、公司 Git 服务）'
            if ([string]::IsNullOrWhiteSpace($script:Platform)) {
                $script:Platform = Read-Host '请输入平台名称（仅字母、数字、_、-）'
            }
            if (-not (Test-PlatformName $script:Platform)) {
                throw '平台名称无效：仅允许以字母或数字开头，并包含字母、数字、_ 或 -。'
            }
            if ($script:Platform -in @('github', 'gitlab', 'gitee')) {
                throw '自定义平台名称不能使用 github、gitlab 或 gitee。'
            }

            $script:GitHost = Read-Host '请输入仓库地址里的 Host（如 git.company.com）'
            $connectHostInput = Read-Host '实际连接地址 [同上]'
            $portInput = Read-Host 'SSH 端口 [22]'
            if ([string]::IsNullOrWhiteSpace($script:GitHost)) {
                throw 'Host 不能为空，已取消。'
            }
            if ($script:GitHost -match '\s|#') {
                throw 'Host 不能包含空格或 #。'
            }

            $script:ConnectHost = if ([string]::IsNullOrWhiteSpace($connectHostInput)) {
                $script:GitHost
            } else {
                $connectHostInput
            }
            if ($script:ConnectHost -match '\s|#') {
                throw '实际连接地址不能包含空格或 #。'
            }

            if ([string]::IsNullOrWhiteSpace($portInput)) {
                $script:Port = 22
            } else {
                $parsedPort = 0
                if ($portInput -notmatch '^[0-9]{1,5}$' -or
                    -not [int]::TryParse($portInput, [ref]$parsedPort) -or
                    $parsedPort -lt 1 -or $parsedPort -gt 65535) {
                    throw 'SSH 端口无效：请输入 1 到 65535 之间的数字。'
                }
                $script:Port = $parsedPort
            }
            $script:KeyUrl = '请在对应平台网站的 SSH 公钥设置页添加'
        }
        default {
            throw "未知平台：$PlatformType（支持 github / gitlab / gitee / custom）"
        }
    }

    $script:PlatformKey = Join-Path $script:SshDirectory "id_ed25519_$($script:Platform)"
    $commentInput = Read-Host "密钥备注/邮箱（回车默认 $($script:Platform)-$($script:GitHost)）"
    $script:Comment = if ([string]::IsNullOrWhiteSpace($commentInput)) {
        "$($script:Platform)-$($script:GitHost)"
    } else {
        $commentInput
    }
}

function Remove-ConfigBlock {
    param([string]$Tag)

    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) {
        return
    }

    $lines = [System.IO.File]::ReadAllLines($script:ConfigFile)
    $keptLines = New-Object 'System.Collections.Generic.List[string]'
    $skip = $false
    foreach ($line in $lines) {
        $tokens = $line.Trim() -split '\s+'
        if ($tokens.Count -ge 3 -and $tokens[0] -eq '#' -and
            $tokens[1] -eq 'BEGIN' -and $tokens[2] -eq $Tag) {
            $skip = $true
            continue
        }
        if ($skip) {
            if ($tokens.Count -ge 3 -and $tokens[0] -eq '#' -and
                $tokens[1] -eq 'END' -and $tokens[2] -eq $Tag) {
                $skip = $false
            }
            continue
        }
        $keptLines.Add($line)
    }

    $temporaryFile = "$($script:ConfigFile).tmp"
    $content = [string]::Join([Environment]::NewLine, $keptLines.ToArray())
    if ($keptLines.Count -gt 0) {
        $content += [Environment]::NewLine
    }
    [System.IO.File]::WriteAllText($temporaryFile, $content, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporaryFile -Destination $script:ConfigFile -Force
}

function Write-ConfigBlock {
    Remove-ConfigBlock $script:Platform
    if (-not (Test-Path -LiteralPath $script:SshDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:SshDirectory -Force | Out-Null
    }

    $block = @"

# BEGIN $($script:Platform)
# $($script:Platform) 路由（ssh-key-router.ps1 自动生成，$($script:Note)）
Host $($script:GitHost)
    HostName $($script:ConnectHost)
    User git
    Port $($script:Port)
    IdentityFile ~/.ssh/id_ed25519_$($script:Platform)
    IdentitiesOnly yes
# END $($script:Platform)
"@
    $existingConfig = if (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf) {
        [System.IO.File]::ReadAllText($script:ConfigFile)
    } else {
        ''
    }
    $block = $block.TrimStart([char[]]"`r`n")
    $newConfig = $block + [Environment]::NewLine + [Environment]::NewLine + $existingConfig
    [System.IO.File]::WriteAllText($script:ConfigFile, $newConfig, $script:Utf8NoBom)
}

function Invoke-Add {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw '缺少平台名。'
    }

    $platformType = $Arguments[0]
    if ($platformType -eq 'custom') {
        if ($Arguments.Count -gt 2) {
            throw 'custom 最多只能指定一个平台名称。'
        }
        $platformName = if ($Arguments.Count -eq 2) { $Arguments[1] } else { '' }
    } else {
        if ($Arguments.Count -gt 1) {
            throw '预设平台不接受额外参数。'
        }
        $platformName = $platformType
    }

    Resolve-Platform $platformType $platformName
    if (Test-Path -LiteralPath $script:PlatformKey) {
        throw "密钥已存在：$($script:PlatformKey)`n    如需重新生成，请先执行：$($script:ScriptPath) remove $($script:Platform)"
    }

    if (-not (Test-Path -LiteralPath $script:SshDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:SshDirectory -Force | Out-Null
    }

    $sshKeygen = Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue
    if (-not $sshKeygen) {
        $sshKeygen = Get-Command 'ssh-keygen' -ErrorAction SilentlyContinue
    }
    if (-not $sshKeygen) {
        throw '找不到 ssh-keygen，请先安装 Windows OpenSSH Client 并确认其目录已加入 PATH。'
    }

    Write-Info ">> 正在生成密钥（ed25519，无密码短语）：$($script:PlatformKey)"
    & $sshKeygen.Source -t ed25519 -C $script:Comment -f $script:PlatformKey -N '' -q
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $script:PlatformKey -PathType Leaf) -or
        -not (Test-Path -LiteralPath "$($script:PlatformKey).pub" -PathType Leaf)) {
        throw '密钥生成失败。'
    }

    Write-Info ">> 正在写入路由配置：$($script:ConfigFile)"
    Write-ConfigBlock

    Write-Info '>> 正在抓取服务器主机公钥并加入 known_hosts'
    $sshKeyscan = Get-Command 'ssh-keyscan.exe' -ErrorAction SilentlyContinue
    if (-not $sshKeyscan) {
        $sshKeyscan = Get-Command 'ssh-keyscan' -ErrorAction SilentlyContinue
    }
    if ($sshKeyscan) {
        $scanOutput = @(& $sshKeyscan.Source -p $script:Port -t 'ed25519,ecdsa,rsa' $script:ConnectHost 2>$null)
        if ($LASTEXITCODE -eq 0 -and $scanOutput.Count -gt 0) {
            [System.IO.File]::AppendAllLines($script:KnownHostsFile, [string[]]$scanOutput, $script:Utf8NoBom)
            Write-Info '   主机公钥已写入（首次连接不会再询问指纹）。'
        } else {
            Write-WarningMessage 'known_hosts 写入失败（可能是网络不通或权限受限）。'
            Write-Host '    首次连接时会提示确认主机指纹，输入 yes 即可，不影响使用。'
        }
    } else {
        Write-WarningMessage '找不到 ssh-keyscan，跳过 known_hosts 预写入。'
        Write-Host '    首次连接时会提示确认主机指纹，输入 yes 即可，不影响使用。'
    }

    Write-Host ''
    Write-Info '==== 完成！请把下面这行公钥添加到平台网站 ===='
    Write-Host "    添加入口：$($script:KeyUrl)"
    Write-Host '-------------------------------------------'
    Get-Content -LiteralPath "$($script:PlatformKey).pub"
    Write-Host '-------------------------------------------'
    Write-Host '    添加完成后，用下面命令验证（出现欢迎语即成功）：'
    Write-Host "    ssh -T git@$($script:GitHost)"
    Write-Host ''
    Write-WarningMessage "移除此平台会永久删除密钥：$($script:ScriptPath) remove $($script:Platform)"
}

function Invoke-Remove {
    param([string[]]$Arguments)

    if ($Arguments.Count -ne 1) {
        throw '请指定一个平台名。'
    }
    $platform = $Arguments[0]
    if (-not (Test-PlatformName $platform)) {
        throw '平台名称无效：仅允许以字母或数字开头，并包含字母、数字、_ 或 -。'
    }

    $keyFile = Join-Path $script:SshDirectory "id_ed25519_$platform"
    $publicKeyFile = "$keyFile.pub"
    if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf) -and
        -not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) {
        Write-WarningMessage "没有找到 $platform 的密钥或配置，无需移除。"
        return
    }

    if (Test-Path -LiteralPath $keyFile -PathType Leaf) {
        Remove-Item -LiteralPath $keyFile -Force
    }
    if (Test-Path -LiteralPath $publicKeyFile -PathType Leaf) {
        Remove-Item -LiteralPath $publicKeyFile -Force
    }

    Write-Info ">> 已永久删除 $platform 的私钥和公钥（若存在）。"
    Remove-ConfigBlock $platform
    Write-Info ">> 已从 $($script:ConfigFile) 移除 $platform 路由区块。"
    Write-WarningMessage '注意：平台网站上登记的公钥仍然有效，建议到网站上一并删除以保安全。'
}

function Invoke-List {
    if (-not (Test-Path -LiteralPath $script:ConfigFile -PathType Leaf)) {
        Write-Info "还没有 $($script:ConfigFile)，尚未配置任何平台。"
        return
    }

    Write-Host ('{0,-10} {1,-24} {2,-24} {3,-6} {4}' -f '平台', 'Host', '实际地址', '端口', '密钥文件')
    Write-Host ('-' * 100)

    $currentPlatform = '手动'
    $entry = $null
    $identityFiles = New-Object 'System.Collections.Generic.List[string]'
    $writeEntry = {
        if ($null -ne $entry) {
            $identityFile = [string]::Join(', ', $identityFiles.ToArray())
            Write-Host ('{0,-10} {1,-24} {2,-24} {3,-6} {4}' -f
                $entry.Platform, $entry.Host, $entry.HostName, $entry.Port, $identityFile)
        }
    }

    foreach ($line in [System.IO.File]::ReadAllLines($script:ConfigFile)) {
        if ($line -match '^\s*#\s*BEGIN\s+(\S+)') {
            $currentPlatform = $Matches[1]
            continue
        }
        if ($line -match '^\s*#\s*END\s+(\S+)') {
            & $writeEntry
            $entry = $null
            $identityFiles.Clear()
            $currentPlatform = '手动'
            continue
        }

        if ($line -match '^\s*#' -or $line -notmatch '^\s*(\S+)\s+(.+?)\s*$') {
            continue
        }

        $directive = $Matches[1]
        $value = $Matches[2].Trim()
        if ($directive -ieq 'Host') {
            & $writeEntry
            $identityFiles.Clear()
            $entry = @{
                Platform = $currentPlatform
                Host = $value
                HostName = $value
                Port = '22'
            }
            continue
        }
        if ($null -eq $entry) {
            continue
        }

        switch -Regex ($directive) {
            '^HostName$' { $entry.HostName = $value; break }
            '^Port$' { $entry.Port = $value; break }
            '^IdentityFile$' { $identityFiles.Add($value); break }
        }
    }

    & $writeEntry
}

try {
    if ($args.Count -eq 0) {
        Show-Usage
        exit 1
    }

    $command = $args[0]
    $commandArguments = @()
    if ($args.Count -gt 1) {
        $commandArguments = @($args[1..($args.Count - 1)])
    }

    switch ($command) {
        'add' { Invoke-Add $commandArguments }
        'remove' { Invoke-Remove $commandArguments }
        'list' {
            if ($commandArguments.Count -gt 0) {
                throw 'list 不接受额外参数。'
            }
            Invoke-List
        }
        { $_ -in @('-h', '--help', 'help') } { Show-Usage }
        default {
            Write-ErrorMessage "未知命令：$command"
            Show-Usage
            exit 1
        }
    }
} catch {
    Write-ErrorMessage $_.Exception.Message
    exit 1
}
