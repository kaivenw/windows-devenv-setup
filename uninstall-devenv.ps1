#Requires -Version 5.1
<#
.SYNOPSIS
    回滚 setup-devenv.ps1 做的改动。

.DESCRIPTION
    停止并删除 MySQL / Redis 服务与计划任务、清理本脚本写入的环境变量与 PATH 条目、
    可选删除安装根目录。winget 装的 IDEA / Trae / Python / Git 默认不动，
    需要一并卸载请加 -IncludeApps。

.EXAMPLE
    .\uninstall-devenv.ps1                       # 只看会删什么，不动手
.EXAMPLE
    .\uninstall-devenv.ps1 -Confirm2             # 真的执行
.EXAMPLE
    .\uninstall-devenv.ps1 -Confirm2 -RemoveData -IncludeApps
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\devtools',

    # 不加这个开关就只是演练，什么都不删
    [switch]$Confirm2,

    # 连同 mysql-data / redis-data / maven-repo 一起删（数据不可恢复）
    [switch]$RemoveData,

    # 一并 winget uninstall IDEA / Trae / Python / Git
    [switch]$IncludeApps
)

$ErrorActionPreference = 'Continue'
$dry = -not $Confirm2

function Say { param($m, $c = 'Gray') Write-Host "  $m" -ForegroundColor $c }
function Act { param($m) if ($dry) { Say "[演练] $m" 'DarkGray' } else { Say $m 'Yellow' } }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '请以管理员身份运行。'
}

Write-Host ''
Write-Host '  ═══ devenv 卸载 ═══' -ForegroundColor Cyan
if ($dry) { Say '演练模式：只列出将要执行的操作。确认无误后加 -Confirm2 真正执行。' 'Magenta' }
Write-Host ''

# ── 1. 服务 ──────────────────────────────────────────────────────
Say '[1/5] 停止并删除服务' 'Cyan'
foreach ($svcName in @('MySQL84', 'MySQL80', 'MySQL97', 'MySQL', 'Redis')) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    Act "停止并删除服务 $svcName"
    if (-not $dry) {
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        # mysqld --remove 更干净，但 sc delete 对两种服务都通用
        & sc.exe delete $svcName | Out-Null
    }
}

$task = Get-ScheduledTask -TaskName 'DevEnv-RedisServer' -ErrorAction SilentlyContinue
if ($task) {
    Act '删除计划任务 DevEnv-RedisServer'
    if (-not $dry) {
        Stop-ScheduledTask -TaskName 'DevEnv-RedisServer' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'DevEnv-RedisServer' -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# 兜底：干掉还在跑的 redis-server / mysqld
foreach ($p in @('redis-server', 'mysqld')) {
    $procs = Get-Process -Name $p -ErrorAction SilentlyContinue
    if ($procs) {
        Act "结束进程 $p (x$($procs.Count))"
        if (-not $dry) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
}

# ── 2. 环境变量 ──────────────────────────────────────────────────
Write-Host ''
Say '[2/5] 清理环境变量' 'Cyan'
foreach ($n in @('JAVA_HOME', 'MAVEN_HOME', 'M2_HOME', 'MYSQL_HOME', 'CLASSPATH')) {
    if ([Environment]::GetEnvironmentVariable($n, 'Machine')) {
        Act "删除 $n"
        if (-not $dry) { [Environment]::SetEnvironmentVariable($n, $null, 'Machine') }
    }
}

# ── 3. PATH ──────────────────────────────────────────────────────
Write-Host ''
Say '[3/5] 清理 PATH 条目' 'Cyan'
$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
    'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
try {
    $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $parts = @($raw -split ';' | Where-Object { $_.Trim() })
    $kept = @()
    foreach ($p in $parts) {
        $drop = ($p -like '%JAVA_HOME%*') -or ($p -like '%MAVEN_HOME%*') -or
                ($p -like "$Root*")
        if ($drop) { Act "PATH -= $p" } else { $kept += $p }
    }
    if (-not $dry -and $kept.Count -ne $parts.Count) {
        $key.SetValue('Path', ($kept -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        Say 'PATH 已更新' 'Green'
    }
}
finally { $key.Close() }

# ── 4. winget 应用 ───────────────────────────────────────────────
Write-Host ''
Say '[4/5] winget 应用' 'Cyan'
if ($IncludeApps) {
    foreach ($id in @('JetBrains.IntelliJIDEA.Community', 'JetBrains.IntelliJIDEA.Ultimate',
                      'ByteDance.Trae.CN', 'ByteDance.Trae',
                      'Python.Python.3.13', 'Python.Python.3.12', 'Git.Git')) {
        Act "winget uninstall $id"
        if (-not $dry) {
            & winget uninstall --exact --id $id --silent --disable-interactivity 2>&1 | Out-Null
        }
    }
}
else { Say '未加 -IncludeApps，跳过 IDEA / Trae / Python / Git' 'DarkGray' }

# ── 5. 目录 ──────────────────────────────────────────────────────
Write-Host ''
Say '[5/5] 删除目录' 'Cyan'
if (Test-Path $Root) {
    # junction 必须先摘掉，否则递归删会把目标 JDK 一起删了
    $junction = Join-Path $Root 'java\current'
    if (Test-Path $junction) {
        Act "摘除目录联接 $junction"
        if (-not $dry) { [IO.Directory]::Delete($junction) }
    }

    $dataDirs = @('mysql-data', 'redis-data', 'maven-repo') |
                ForEach-Object { Join-Path $Root $_ } | Where-Object { Test-Path $_ }

    if ($dataDirs -and -not $RemoveData) {
        Say '以下数据目录将被保留（要删请加 -RemoveData）：' 'Yellow'
        $dataDirs | ForEach-Object { Say "  - $_" 'Yellow' }
        foreach ($d in (Get-ChildItem $Root -Force)) {
            if ($dataDirs -contains $d.FullName) { continue }
            Act "删除 $($d.FullName)"
            if (-not $dry) { Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    else {
        Act "删除整个目录 $Root"
        if (-not $dry) { Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
else { Say "$Root 不存在" 'DarkGray' }

Write-Host ''
if ($dry) {
    Write-Host '  以上为演练结果。确认无误后重新运行并加上 -Confirm2' -ForegroundColor Magenta
}
else {
    Write-Host '  卸载完成。请重开终端使环境变量生效。' -ForegroundColor Green
    Write-Host "  Maven 配置 $env:USERPROFILE\.m2\settings.xml 与 pip.ini 未删除，如需请手动清理。" -ForegroundColor DarkGray
}
Write-Host ''
