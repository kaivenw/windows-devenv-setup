#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 一键安装配置 Python / Java 开发环境。

.DESCRIPTION
    组件：JDK(8/11/17/21 可自由切换) + Maven + Python + MySQL + Redis + IntelliJ IDEA + Trae
    特性：幂等可重跑、国内镜像加速、失败不中断、全量校验报告、可回滚(uninstall-devenv.ps1)。

.EXAMPLE
    # 最常用：双击 一键安装.bat 即可。手动执行等价于：
    .\setup-devenv.ps1

.EXAMPLE
    # 只装 JDK 和 Maven，装到 D 盘
    .\setup-devenv.ps1 -Root D:\devtools -Only jdk,maven

.EXAMPLE
    # 跳过 MySQL 和 Redis，默认 JDK 用 17
    .\setup-devenv.ps1 -Skip mysql,redis -DefaultJdk 17

.EXAMPLE
    # 演练模式：只打印将要做什么，不做任何改动
    .\setup-devenv.ps1 -DryRun
#>
[CmdletBinding()]
param(
    # 所有绿色版组件(JDK/Maven/MySQL/Redis)的安装根目录
    [string]$Root,

    # 只安装这些组件（与 -Skip 互斥）。可选值见 $script:AllComponents
    [string[]]$Only,

    # 跳过这些组件
    [string[]]$Skip,

    # 要安装的 JDK 版本列表，如 8,11,17,21,25
    [string[]]$JdkVersions,

    # 默认激活的 JDK 版本
    [string]$DefaultJdk,

    # MySQL root 密码。不传则用配置文件里的值
    [string]$MysqlRootPassword,

    # Redis 密码。留空表示不设密码（仅监听 127.0.0.1）
    [string]$RedisPassword,

    # IDEA 版本：Community / Ultimate
    [ValidateSet('Community', 'Ultimate')]
    [string]$IdeaEdition,

    # 禁用国内镜像，全部走官方源
    [switch]$NoMirror,

    # 演练模式：只输出计划，不实际改动系统
    [switch]$DryRun,

    # 强制重装（已安装的组件也重新处理）
    [switch]$Force,

    # 配置文件路径，默认同目录 devenv.config.psd1
    [string]$ConfigFile,

    # 由 一键安装.bat 传入的“提权前的用户主目录”，用于写 .m2/pip.ini 到正确的用户下
    [string]$InvokingUserProfile
)

$ErrorActionPreference = 'Stop'
# 用 2.0 而不是 Latest：3.0 的“数组越界即报错”在这种到处探测环境的脚本里
# 只会把可恢复的情况变成硬失败，得不偿失。
Set-StrictMode -Version 2.0
# Invoke-WebRequest 的进度条会让下载慢 10 倍以上
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:AllComponents = @('jdk', 'maven', 'python', 'mysql', 'redis', 'idea', 'trae', 'git')
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:StartTime = Get-Date

#region ───────────────────────────── 日志 ─────────────────────────────

$script:LogFile = $null

function Initialize-Log {
    $logDir = Join-Path $env:ProgramData 'devenv-setup\logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $script:LogFile = Join-Path $logDir ("setup-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    "==== devenv setup started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====" |
        Out-File -FilePath $script:LogFile -Encoding utf8
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0:HH:mm:ss}] [{1,-5}] {2}" -f (Get-Date), $Level, $Message
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 }
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        'SKIP'  { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-Step   { param([string]$m) Write-Host ''; Write-Log "── $m" 'STEP' }
function Write-Ok     { param([string]$m) Write-Log $m 'OK' }
function Write-Warn   { param([string]$m) Write-Log $m 'WARN' }
function Write-Err    { param([string]$m) Write-Log $m 'ERROR' }
function Write-Skip   { param([string]$m) Write-Log $m 'SKIP' }

function Write-Banner {
    $b = @'
  ____             _____
 |  _ \  _____   _| ____|_ ____   __
 | | | |/ _ \ \ / /  _| | '_ \ \ / /   Windows 一键开发环境
 | |_| |  __/\ V /| |___| | | \ V /    Java + Python 全家桶
 |____/ \___| \_/ |_____|_| |_|\_/
'@
    Write-Host $b -ForegroundColor Cyan
}

#endregion

#region ─────────────────────────── 配置加载 ───────────────────────────

function Get-DefaultConfig {
    @{
        Root         = 'C:\devtools'
        Components   = @('jdk', 'maven', 'python', 'mysql', 'redis', 'idea', 'trae')
        UseMirror    = $true

        Jdk = @{
            Versions = @('8', '11', '17', '21')
            Default  = '21'
        }
        Maven = @{
            Version         = '3.9.16'
            LocalRepository = ''      # 留空 => <Root>\maven-repo
            UseAliyunMirror = $true
        }
        Python = @{
            WingetIds = @('Python.Python.3.13', 'Python.Python.3.12')
            PipIndex  = 'https://pypi.tuna.tsinghua.edu.cn/simple'
            PipHost   = 'pypi.tuna.tsinghua.edu.cn'
        }
        MySql = @{
            Series       = '8.4'      # 8.4(LTS，推荐) / 8.0(已 EOL) / 9.7
            Version      = ''         # 留空 => 自动解析该系列最新版
            Port         = 3306
            RootPassword = 'root1234'
            ServiceName  = ''         # 留空 => 自动，如 MySQL84
            EnableNativePassword = $true   # 兼容老版 Navicat / 老 JDBC 驱动
            # 默认只监听本机。要让同事/虚拟机/手机连进来才改 0.0.0.0，
            # 并且必须同时把 AllowRemoteRoot 打开、把 RootPassword 换成强口令。
            BindAddress     = '127.0.0.1'
            AllowRemoteRoot = $false
        }
        Redis = @{
            Version  = ''             # 留空 => 自动取 redis-windows 最新 release
            Port     = 6379
            Password = ''             # 留空 => 不设密码（只监听 127.0.0.1）
            MaxMemory = '512mb'
        }
        Idea = @{
            Edition = 'Community'     # Community / Ultimate
        }
        Trae = @{
            WingetIds = @('ByteDance.Trae.CN', 'ByteDance.Trae')
            DownloadPage = 'https://www.trae.com.cn/download'
        }
    }
}

function Merge-Config {
    param([hashtable]$Base, [hashtable]$Override)
    foreach ($k in $Override.Keys) {
        if ($Base.ContainsKey($k) -and $Base[$k] -is [hashtable] -and $Override[$k] -is [hashtable]) {
            Merge-Config -Base $Base[$k] -Override $Override[$k]
        }
        else {
            $Base[$k] = $Override[$k]
        }
    }
    $Base
}

function Import-DevEnvConfig {
    $cfg = Get-DefaultConfig
    $path = if ($ConfigFile) { $ConfigFile } else { Join-Path $script:ScriptDir 'devenv.config.psd1' }
    if (Test-Path $path) {
        try {
            $user = Import-PowerShellDataFile -Path $path
            $cfg = Merge-Config -Base $cfg -Override $user
            Write-Log "已加载配置文件: $path"
        }
        catch { Write-Warn "配置文件解析失败，使用默认配置: $($_.Exception.Message)" }
    }
    else { Write-Log "未找到配置文件，使用内置默认配置" }

    # 命令行参数优先级最高
    if ($Root)              { $cfg.Root = $Root }
    if ($JdkVersions)       { $cfg.Jdk.Versions = $JdkVersions }
    if ($DefaultJdk)        { $cfg.Jdk.Default = $DefaultJdk }
    if ($MysqlRootPassword) { $cfg.MySql.RootPassword = $MysqlRootPassword }
    if ($PSBoundParameters.ContainsKey('RedisPassword')) { $cfg.Redis.Password = $RedisPassword }
    if ($IdeaEdition)       { $cfg.Idea.Edition = $IdeaEdition }
    if ($NoMirror)          { $cfg.UseMirror = $false }

    if ($Only) { $cfg.Components = @($Only | ForEach-Object { $_.ToLower() }) }
    if ($Skip) {
        $skipSet = @($Skip | ForEach-Object { $_.ToLower() })
        $cfg.Components = @($cfg.Components | Where-Object { $skipSet -notcontains $_.ToLower() })
    }

    $bad = @($cfg.Components | Where-Object { $script:AllComponents -notcontains $_.ToLower() })
    if ($bad) { throw "未知组件: $($bad -join ', ')。可选: $($script:AllComponents -join ', ')" }

    if ($cfg.Jdk.Versions -notcontains $cfg.Jdk.Default) {
        Write-Warn "默认 JDK $($cfg.Jdk.Default) 不在安装列表中，改用 $($cfg.Jdk.Versions[-1])"
        $cfg.Jdk.Default = $cfg.Jdk.Versions[-1]
    }
    $cfg
}

#endregion

#region ─────────────────────── 环境与前置检查 ───────────────────────

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RealUserProfile {
    # 提权后 $env:USERPROFILE 可能是管理员的，要拿到真正操作的人
    if ($InvokingUserProfile -and (Test-Path $InvokingUserProfile)) { return $InvokingUserProfile }
    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" |
                    Select-Object -First 1
        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            if ($owner.User) {
                $p = Join-Path (Split-Path $env:USERPROFILE -Parent) $owner.User
                if (Test-Path $p) { return $p }
            }
        }
    }
    catch { }
    $env:USERPROFILE
}

function Test-Prerequisite {
    param([hashtable]$Cfg)
    Write-Step '前置环境检查'

    if (-not (Test-Admin)) {
        throw '需要管理员权限。请右键"以管理员身份运行" 一键安装.bat，或在管理员 PowerShell 中执行本脚本。'
    }
    Write-Ok '管理员权限：OK'

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log "系统：$($os.Caption) $($os.Version) / $($os.OSArchitecture)"
    if ([Environment]::Is64BitOperatingSystem -eq $false) {
        throw '本脚本仅支持 64 位 Windows。'
    }
    if ([version]$os.Version -lt [version]'10.0') {
        Write-Warn 'Windows 版本低于 10，winget 与部分组件可能不可用。'
    }

    try {
        $drive = Split-Path -Qualifier $Cfg.Root
        $free = (Get-PSDrive -Name $drive.TrimEnd(':') -ErrorAction Stop).Free / 1GB
        Write-Log ("目标盘 {0} 剩余空间：{1:N1} GB" -f $drive, $free)
        if ($free -lt 15) {
            Write-Warn '剩余空间不足 15GB，完整安装可能失败（建议 -Root 指向空间更充足的盘）。'
        }
    }
    catch { Write-Warn "无法检测 $($Cfg.Root) 所在盘的剩余空间，跳过该检查。" }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $script:HasWinget = $true
        Write-Ok "winget：$(winget --version 2>$null)"
    }
    else {
        $script:HasWinget = $false
        Write-Warn 'winget 不可用。IDEA / Trae / Python 将改用官方安装包直链方式，可能较慢。'
        Write-Warn '建议先从 Microsoft Store 安装"应用安装程序(App Installer)"以启用 winget。'
    }

    try {
        $null = Invoke-WebRequest -Uri 'https://www.baidu.com' -Method Head -TimeoutSec 8 -UseBasicParsing
        Write-Ok '网络连通性：OK'
    }
    catch { Write-Warn "网络探测失败（$($_.Exception.Message)），如在公司网络请先配置代理。" }

    $script:UserProfile = Get-RealUserProfile
    Write-Log "用户主目录（用于写 .m2 / pip.ini）：$script:UserProfile"
}

#endregion

#region ─────────────────────────── 通用工具 ───────────────────────────

function New-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        if ($DryRun) { Write-Log "[DryRun] 创建目录 $Path"; return }
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-TextFile {
    <#
        统一的文本落盘。默认 UTF-8 **不带 BOM**：
        my.ini / pip.ini / redis.conf 这类配置一旦带 BOM，解析器会把 BOM 算进第一行，
        导致 "[mysqld]" / "[global]" 段头识别不到。只有 .ps1 才需要 -Bom。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [switch]$Bom
    )
    if ($DryRun) { Write-Log "[DryRun] 写入 $Path"; return }
    New-Dir (Split-Path $Path -Parent)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($Bom.IsPresent))
    Write-Ok "写入 $Path"
}

function Get-MirrorUrls {
    <# 给一个官方 URL，返回 [官方 + 国内加速] 的候选列表 #>
    param([string]$Url, [hashtable]$Cfg)
    $list = [System.Collections.Generic.List[string]]::new()
    if ($Cfg.UseMirror) {
        if ($Url -match '^https://github\.com/') {
            foreach ($p in @('https://ghfast.top/', 'https://gh-proxy.com/', 'https://ghproxy.net/')) {
                $list.Add($p + $Url)
            }
        }
        elseif ($Url -match '^https://dlcdn\.apache\.org/(.+)$') {
            $list.Add("https://mirrors.tuna.tsinghua.edu.cn/apache/$($Matches[1])")
            $list.Add("https://mirrors.aliyun.com/apache/$($Matches[1])")
        }
    }
    $list.Add($Url)
    $list
}

function Invoke-Download {
    <# 多源下载，支持断点续传与自动回退。返回本地文件路径。 #>
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$MinBytes = 1024
    )
    if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt $MinBytes) -and -not $Force) {
        Write-Skip "已缓存，跳过下载：$(Split-Path $OutFile -Leaf)"
        return $OutFile
    }
    if ($DryRun) { Write-Log "[DryRun] 下载 $($Urls[0]) -> $OutFile"; return $OutFile }

    New-Dir (Split-Path $OutFile -Parent)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue

    foreach ($u in $Urls) {
        Write-Log "下载：$u"
        try {
            if ($curl) {
                # -C - 断点续传；--retry 处理瞬时抖动
                & $curl.Source -L --fail --retry 3 --retry-delay 2 --connect-timeout 20 `
                    '-C' '-' '-o' $OutFile $u
                if ($LASTEXITCODE -eq 33) {
                    # 33 = 服务端不支持 Range，退回完整下载
                    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                    & $curl.Source -L --fail --retry 3 --connect-timeout 20 '-o' $OutFile $u
                }
                if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
            }
            else {
                Invoke-WebRequest -Uri $u -OutFile $OutFile -UseBasicParsing -TimeoutSec 1800
            }
            if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt $MinBytes) {
                Write-Ok ("下载完成：{0} ({1:N1} MB)" -f (Split-Path $OutFile -Leaf), ((Get-Item $OutFile).Length / 1MB))
                return $OutFile
            }
            throw '文件过小，疑似下载失败'
        }
        catch {
            Write-Warn "该源失败：$($_.Exception.Message)"
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
        }
    }
    throw "所有下载源均失败：$($Urls[0])"
}

function Expand-ToDirectory {
    <# 解压 zip 并把内部唯一顶层目录“提升”为 $Destination（去掉 apache-maven-3.9.16 这层） #>
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Flatten
    )
    if ($DryRun) { Write-Log "[DryRun] 解压 $ZipPath -> $Destination"; return }

    if (Test-Path $Destination) {
        if (-not $Force) { Write-Skip "目标已存在，跳过解压：$Destination"; return }
        Remove-Item $Destination -Recurse -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    # 临时目录放在目标同一个盘上，Move-Item 才是改名而不是跨卷复制 200MB
    $tmp = Join-Path (Split-Path $Destination -Parent) (".unpack-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $tmp)
        $entries = @(Get-ChildItem -LiteralPath $tmp)
        $src = if ($Flatten -and $entries.Count -eq 1 -and $entries[0].PSIsContainer) {
            $entries[0].FullName
        } else { $tmp }

        New-Dir (Split-Path $Destination -Parent)
        Move-Item -LiteralPath $src -Destination $Destination -Force
        Write-Ok "解压完成：$Destination"
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

#endregion

#region ───────────────────── 环境变量 / PATH 处理 ─────────────────────

function Get-MachinePathRaw {
    # 必须用 DoNotExpandEnvironmentNames 读，否则会把 %SystemRoot% 之类展开后写死
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
    try {
        [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    finally { $key.Close() }
}

function Set-MachinePathRaw {
    param([string]$Value)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
    finally { $key.Close() }
}

function Add-MachinePath {
    param([Parameter(Mandatory)][string]$Entry, [switch]$Prepend)
    if ($DryRun) { Write-Log "[DryRun] PATH += $Entry"; return }
    $raw = Get-MachinePathRaw
    $parts = @($raw -split ';' | Where-Object { $_.Trim() })
    if ($parts -contains $Entry -or ($parts | Where-Object { $_.TrimEnd('\') -ieq $Entry.TrimEnd('\') })) {
        Write-Skip "PATH 已包含：$Entry"; return
    }
    $new = if ($Prepend) { @($Entry) + $parts } else { $parts + @($Entry) }
    Set-MachinePathRaw (($new -join ';'))
    # 当前会话里要用展开后的真实路径，%JAVA_HOME% 这种 PowerShell 不认
    $env:Path = "$([Environment]::ExpandEnvironmentVariables($Entry));$env:Path"
    Write-Ok "PATH += $Entry"
}

function Set-MachineEnv {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    if ($DryRun) { Write-Log "[DryRun] $Name=$Value"; return }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    Set-Item -Path "Env:$Name" -Value $Value
    Write-Ok "$Name = $Value"
}

function Publish-EnvChange {
    # 广播 WM_SETTINGCHANGE，新开的资源管理器/终端能立刻读到新变量
    if ($DryRun) { return }
    if (-not ('Win32.NativeMethods' -as [type])) {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1A
    $result = [UIntPtr]::Zero
    [void][Win32.NativeMethods]::SendMessageTimeout(
        $HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

function Set-DirectoryJunction {
    param([Parameter(Mandatory)][string]$Link, [Parameter(Mandatory)][string]$Target)
    if ($DryRun) { Write-Log "[DryRun] junction $Link -> $Target"; return }
    if (Test-Path $Link) {
        $item = Get-Item $Link -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # 注意：PS5.1 的 Remove-Item -Recurse 删 junction 会连目标内容一起删。
            # Directory.Delete 只摘掉重解析点本身，绝不会碰到目标目录。
            [IO.Directory]::Delete($Link)
        }
        else {
            throw "$Link 已存在且不是目录联接，请先手动处理。"
        }
    }
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
}

#endregion

#region ───────────────────────── winget 封装 ─────────────────────────

function Test-WingetInstalled {
    param([string]$Id)
    if (-not $script:HasWinget) { return $false }
    $out = & winget list --exact --id $Id --accept-source-agreements 2>&1 | Out-String
    return ($out -match [regex]::Escape($Id))
}

function Install-ViaWinget {
    <# 依次尝试候选包 ID，任一成功即返回该 ID；全失败返回 $null #>
    param([Parameter(Mandatory)][string[]]$Ids, [string]$Scope)
    if (-not $script:HasWinget) { return $null }

    foreach ($id in $Ids) {
        if ((Test-WingetInstalled -Id $id) -and -not $Force) {
            Write-Skip "winget 已安装：$id"
            return $id
        }
        if ($DryRun) { Write-Log "[DryRun] winget install $id"; return $id }

        Write-Log "winget 安装：$id ..."
        $wgArgs = @('install', '--exact', '--id', $id, '--silent',
                    '--accept-package-agreements', '--accept-source-agreements',
                    '--disable-interactivity')
        if ($Scope) { $wgArgs += @('--scope', $Scope) }

        & winget @wgArgs 2>&1 | ForEach-Object { Write-Log "  $_" }
        $code = $LASTEXITCODE
        # 0 成功；-1978335189 (0x8A15002B) = 已是最新版
        if ($code -eq 0 -or $code -eq -1978335189) {
            Write-Ok "winget 安装成功：$id"
            return $id
        }
        Write-Warn "winget 安装 $id 失败（exit=$code），尝试下一个候选。"
    }
    $null
}

#endregion

#region ─────────────────────────── JDK ───────────────────────────

function Resolve-JdkDownload {
    <#
        返回该 JDK 大版本的下载候选列表 + 缓存文件名。
        官方 /v3/binary/latest 跳转最终落在 GitHub 上，国内很慢，
        所以先问 /v3/assets/latest 拿到确切文件名，再优先走清华的 Adoptium 镜像。
    #>
    param([string]$Major, [hashtable]$Cfg)

    $urls = [System.Collections.Generic.List[string]]::new()
    $name = "temurin-$Major-windows-x64.zip"

    try {
        $api = "https://api.adoptium.net/v3/assets/latest/$Major/hotspot" +
               "?os=windows&architecture=x64&image_type=jdk&vendor=eclipse"
        $assets = Invoke-RestMethod -Uri $api -TimeoutSec 25
        $pkg = $assets[0].binary.package
        if ($pkg.name) {
            $name = $pkg.name
            Write-Log "JDK $Major 解析到：$name"
            if ($Cfg.UseMirror) {
                $urls.Add("https://mirrors.tuna.tsinghua.edu.cn/Adoptium/$Major/jdk/x64/windows/$name")
            }
            if ($pkg.link) { foreach ($u in (Get-MirrorUrls -Url $pkg.link -Cfg $Cfg)) { $urls.Add($u) } }
        }
    }
    catch { Write-Warn "JDK $Major 版本解析失败，退回官方跳转链接：$($_.Exception.Message)" }

    # 兜底：这个地址永远指向最新 GA，不需要知道小版本号
    $urls.Add("https://api.adoptium.net/v3/binary/latest/$Major/ga/windows/x64/jdk/hotspot/normal/eclipse")
    @{ Urls = $urls; FileName = $name }
}

function Install-Jdk {
    param([hashtable]$Cfg)
    Write-Step "安装 JDK（$($Cfg.Jdk.Versions -join ', ')），默认 $($Cfg.Jdk.Default)"

    $javaRoot = Join-Path $Cfg.Root 'java'
    New-Dir $javaRoot
    $cacheDir = Join-Path $Cfg.Root '.cache'

    $installed = @()
    foreach ($v in $Cfg.Jdk.Versions) {
        $dest = Join-Path $javaRoot "jdk-$v"
        if ((Test-Path (Join-Path $dest 'bin\java.exe')) -and -not $Force) {
            Write-Skip "JDK $v 已存在：$dest"
            $installed += $v
            continue
        }
        try {
            $src = Resolve-JdkDownload -Major $v -Cfg $Cfg
            $zip = Join-Path $cacheDir $src.FileName
            Invoke-Download -Urls $src.Urls -OutFile $zip -MinBytes 50MB | Out-Null
            Expand-ToDirectory -ZipPath $zip -Destination $dest -Flatten
            $installed += $v
            Write-Ok "JDK $v 安装到 $dest"
        }
        catch {
            Write-Err "JDK $v 安装失败：$($_.Exception.Message)"
        }
    }

    if (-not $installed) { throw '没有任何 JDK 安装成功。' }

    # ── 核心：JAVA_HOME 指向 junction，切换版本只需重指 junction ──
    $default = if ($installed -contains $Cfg.Jdk.Default) { $Cfg.Jdk.Default } else { $installed[-1] }
    $current = Join-Path $javaRoot 'current'
    Set-DirectoryJunction -Link $current -Target (Join-Path $javaRoot "jdk-$default")

    Set-MachineEnv -Name 'JAVA_HOME' -Value $current
    Add-MachinePath -Entry '%JAVA_HOME%\bin' -Prepend
    # 老项目（尤其 Ant / 旧 IDE 插件）还在读 CLASSPATH，给个无害的默认值
    Set-MachineEnv -Name 'CLASSPATH' -Value '.;%JAVA_HOME%\lib\dt.jar;%JAVA_HOME%\lib\tools.jar'

    Install-JdkSwitcher -Cfg $Cfg -JavaRoot $javaRoot

    Add-Result -Name 'JDK' -Status 'OK' -Detail "已装 $($installed -join '/'), 当前 $default"
}

function Install-JdkSwitcher {
    <# 生成 jdk.cmd / jdk.ps1，放进 <Root>\bin 并加入 PATH #>
    param([hashtable]$Cfg, [string]$JavaRoot)

    $binDir = Join-Path $Cfg.Root 'bin'
    New-Dir $binDir

    # 用单引号 here-string（不做任何插值），再替换占位符 —— 避免多层转义踩坑
    $template = @'
#Requires -Version 5.1
<#
    JDK 版本切换器 —— 由 setup-devenv.ps1 生成，请勿手工修改。

    原理：JAVA_HOME 常年指向 <JavaRoot>\current 这个目录联接(junction)，
          切换版本 = 把 junction 重新指向 jdk-XX，环境变量一个字都不用改，
          所有已打开的终端、IDEA、Maven 立即生效。

    用法： jdk        查看已安装版本
           jdk 17     切换到 JDK 17
#>
param([string]$Version)

$ErrorActionPreference = 'Stop'
$JavaRoot = '__JAVA_ROOT__'
$Current  = Join-Path $JavaRoot 'current'

function Get-Installed {
    Get-ChildItem $JavaRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^jdk-(\d+)$' -and (Test-Path (Join-Path $_.FullName 'bin\java.exe')) } |
        ForEach-Object {
            [pscustomobject]@{ Version = [int]($_.Name -replace '^jdk-', ''); Path = $_.FullName }
        } | Sort-Object Version
}

function Get-Active {
    if (Test-Path $Current) {
        $t = (Get-Item $Current -Force).Target
        if ($t) { return ((Split-Path (@($t)[0]) -Leaf) -replace '^jdk-', '') }
    }
    return $null
}

$list   = @(Get-Installed)
$active = Get-Active

if (-not $Version) {
    Write-Host ''
    Write-Host '  已安装的 JDK：' -ForegroundColor Cyan
    foreach ($j in $list) {
        $isActive = ("$($j.Version)" -eq $active)
        $mark  = if ($isActive) { '*' } else { ' ' }
        $color = if ($isActive) { 'Green' } else { 'Gray' }
        Write-Host ("   {0} {1,-4}  {2}" -f $mark, $j.Version, $j.Path) -ForegroundColor $color
    }
    Write-Host ''
    Write-Host '  切换： jdk <版本号>      例如  jdk 17' -ForegroundColor DarkGray
    Write-Host ''
    if ($active) { & (Join-Path $Current 'bin\java.exe') -version }
    return
}

$want   = $Version.Trim()
$target = $list | Where-Object { "$($_.Version)" -eq $want } | Select-Object -First 1
if (-not $target) {
    Write-Host "未安装 JDK $want。已安装：$(($list.Version) -join ', ')" -ForegroundColor Red
    exit 1
}
if ($want -eq $active) {
    Write-Host "当前已经是 JDK $want" -ForegroundColor Green
    return
}

function Switch-Junction {
    param([string]$To)
    if (Test-Path $Current) { [System.IO.Directory]::Delete($Current) }
    New-Item -ItemType Junction -Path $Current -Target $To -ErrorAction Stop | Out-Null
}

try {
    Switch-Junction -To $target.Path
}
catch {
    Write-Host '权限不足，正在请求管理员权限...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, $want)
}

$now = Get-Active
if ($now -eq $want) {
    Write-Host "已切换到 JDK $now  ($($target.Path))" -ForegroundColor Green
    & (Join-Path $Current 'bin\java.exe') -version
}
else {
    Write-Host "切换失败，当前仍为 JDK $now" -ForegroundColor Red
    exit 1
}
'@
    $ps1 = $template.Replace('__JAVA_ROOT__', $JavaRoot)
    if (-not $DryRun) {
        # PowerShell 5.1 读 .ps1 默认按 ANSI，中文必须带 BOM 才不乱码
        [IO.File]::WriteAllText((Join-Path $binDir 'jdk.ps1'), $ps1, [Text.UTF8Encoding]::new($true))
    }

    # .cmd 包装，让 cmd / PowerShell 里都能直接敲 jdk
    $cmd = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0jdk.ps1" %*
"@
    if (-not $DryRun) {
        Set-Content -Path (Join-Path $binDir 'jdk.cmd') -Value $cmd -Encoding ASCII
    }

    # 让普通用户无需提权也能切换（只放开 java 这一个目录，S-1-5-32-545 = BUILTIN\Users）
    if (-not $DryRun) {
        & icacls.exe $JavaRoot /grant '*S-1-5-32-545:(OI)(CI)M' /T /Q 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'java 目录授权失败，以后切换 JDK 时会弹 UAC 提权，功能不受影响。'
        }
    }

    Add-MachinePath -Entry $binDir
    Write-Ok "JDK 切换命令已就绪：直接敲 jdk / jdk 17 / jdk 8"
}

#endregion

#region ─────────────────────────── Maven ───────────────────────────

function Install-Maven {
    param([hashtable]$Cfg)
    $ver = $Cfg.Maven.Version
    Write-Step "安装 Maven $ver"

    $dest = Join-Path $Cfg.Root "apache-maven-$ver"
    if (-not ((Test-Path (Join-Path $dest 'bin\mvn.cmd')) -and -not $Force)) {
        $file = "apache-maven-$ver-bin.zip"
        $official = "https://dlcdn.apache.org/maven/maven-3/$ver/binaries/$file"
        $urls = @(Get-MirrorUrls -Url $official -Cfg $Cfg)
        # dlcdn 只保留当前版本，老版本要去 archive
        $urls += "https://archive.apache.org/dist/maven/maven-3/$ver/binaries/$file"

        $zip = Join-Path (Join-Path $Cfg.Root '.cache') $file
        Invoke-Download -Urls $urls -OutFile $zip -MinBytes 5MB | Out-Null
        Expand-ToDirectory -ZipPath $zip -Destination $dest -Flatten
    }
    else { Write-Skip "Maven 已存在：$dest" }

    Set-MachineEnv -Name 'MAVEN_HOME' -Value $dest
    Set-MachineEnv -Name 'M2_HOME'    -Value $dest   # 老项目/老插件还在读 M2_HOME
    Add-MachinePath -Entry '%MAVEN_HOME%\bin'

    $localRepo = if ($Cfg.Maven.LocalRepository) { $Cfg.Maven.LocalRepository }
                 else { Join-Path $Cfg.Root 'maven-repo' }
    New-Dir $localRepo

    Write-MavenSettings -Cfg $Cfg -MavenHome $dest -LocalRepo $localRepo
    Add-Result -Name 'Maven' -Status 'OK' -Detail "$ver, 仓库 $localRepo"
}

function Write-MavenSettings {
    param([hashtable]$Cfg, [string]$MavenHome, [string]$LocalRepo)

    $mirrorXml = if ($Cfg.Maven.UseAliyunMirror -and $Cfg.UseMirror) {
@'
    <mirror>
      <id>aliyun-public</id>
      <name>Aliyun Public</name>
      <url>https://maven.aliyun.com/repository/public</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
    <mirror>
      <id>aliyun-spring</id>
      <name>Aliyun Spring</name>
      <url>https://maven.aliyun.com/repository/spring</url>
      <mirrorOf>spring-milestones,spring-snapshots</mirrorOf>
    </mirror>
'@
    } else { '    <!-- 未启用镜像，直连 Maven Central -->' }

    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<!-- 由 setup-devenv.ps1 生成于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -->
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              https://maven.apache.org/xsd/settings-1.0.0.xsd">

  <localRepository>$LocalRepo</localRepository>

  <mirrors>
$mirrorXml
  </mirrors>

  <profiles>
    <profile>
      <id>jdk-default</id>
      <activation>
        <activeByDefault>true</activeByDefault>
      </activation>
      <properties>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <project.reporting.outputEncoding>UTF-8</project.reporting.outputEncoding>
      </properties>
    </profile>
  </profiles>
</settings>
"@

    foreach ($target in @(
        (Join-Path $script:UserProfile '.m2\settings.xml'),
        (Join-Path $MavenHome 'conf\settings.xml')
    )) {
        if (-not $DryRun -and (Test-Path $target)) {
            $bak = "$target.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
            Copy-Item $target $bak -Force
            Write-Log "已备份原 settings.xml -> $bak"
        }
        Write-TextFile -Path $target -Content $xml
    }
}

#endregion

#region ─────────────────────────── Python ───────────────────────────

function Install-Python {
    param([hashtable]$Cfg)
    Write-Step '安装 Python'

    $existing = Get-Command python -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        $v = & python --version 2>&1
        Write-Skip "已检测到 $v （$($existing.Source)）"
    }
    else {
        $id = Install-ViaWinget -Ids $Cfg.Python.WingetIds -Scope 'machine'
        if (-not $id) { $id = Install-ViaWinget -Ids $Cfg.Python.WingetIds }   # machine 作用域失败就退回 user
        if (-not $id) { Install-PythonFromOfficial -Cfg $Cfg }
        Update-SessionPath
    }

    Write-PipConfig -Cfg $Cfg
    Install-PythonBasePackages

    $ver = '未知'
    try { $ver = ((& python --version 2>&1) | Out-String).Trim() } catch { }
    Add-Result -Name 'Python' -Status 'OK' -Detail $ver
}

function Install-PythonFromOfficial {
    param([hashtable]$Cfg)
    Write-Log 'winget 不可用，改用 python.org 官方安装包'
    $index = Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/' -UseBasicParsing -TimeoutSec 30
    $ver = ($index.Content |
        Select-String -Pattern 'href="(3\.(?:11|12|13)\.\d+)/"' -AllMatches).Matches |
        ForEach-Object { [version]$_.Groups[1].Value } |
        Sort-Object -Descending | Select-Object -First 1
    if (-not $ver) { throw '无法解析 python.org 版本列表' }

    $exe = Join-Path (Join-Path $Cfg.Root '.cache') "python-$ver-amd64.exe"
    Invoke-Download -Urls @("https://www.python.org/ftp/python/$ver/python-$ver-amd64.exe") `
                    -OutFile $exe -MinBytes 10MB | Out-Null
    if ($DryRun) { return }

    $p = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList @(
        '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_pip=1',
        'Include_launcher=1', 'AssociateFiles=1')
    if ($p.ExitCode -ne 0) { throw "Python 安装器退出码 $($p.ExitCode)" }
    Write-Ok "Python $ver 安装完成"
}

function Write-PipConfig {
    param([hashtable]$Cfg)
    if (-not $Cfg.UseMirror) { Write-Skip '未启用镜像，跳过 pip 源配置'; return }

    $content = @"
[global]
index-url = $($Cfg.Python.PipIndex)
timeout = 60
disable-pip-version-check = true

[install]
trusted-host = $($Cfg.Python.PipHost)
"@
    # Windows 上 pip 的用户级配置是 %APPDATA%\pip\pip.ini（不是 ~\pip\pip.ini）
    $target = Join-Path $script:UserProfile 'AppData\Roaming\pip\pip.ini'
    Write-TextFile -Path $target -Content $content
    Write-Ok "pip 源已配置为清华镜像：$target"
}

function Install-PythonBasePackages {
    if ($DryRun) { Write-Log '[DryRun] pip install 基础包'; return }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Warn 'python 不在 PATH 中，跳过基础包安装（重开终端后可手动执行）'; return
    }
    foreach ($cmd in @(
        @('-m', 'pip', 'install', '--upgrade', 'pip'),
        @('-m', 'pip', 'install', 'virtualenv', 'pipx')
    )) {
        try { & python @cmd 2>&1 | ForEach-Object { Write-Log "  $_" } }
        catch { Write-Warn "pip 命令失败：$($_.Exception.Message)" }
    }
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

#endregion

#region ─────────────────────────── MySQL ───────────────────────────

function Resolve-MySqlVersion {
    param([hashtable]$Cfg)
    if ($Cfg.MySql.Version) { return $Cfg.MySql.Version }
    $series = $Cfg.MySql.Series
    try {
        $json = Invoke-RestMethod -Uri 'https://endoflife.date/api/mysql.json' -TimeoutSec 20
        $row = $json | Where-Object { $_.cycle -eq $series } | Select-Object -First 1
        if ($row -and $row.latest) {
            Write-Log "解析到 MySQL $series 最新版：$($row.latest)"
            return $row.latest
        }
    }
    catch { Write-Warn "在线解析 MySQL 版本失败：$($_.Exception.Message)" }

    $fallback = @{ '8.4' = '8.4.11'; '8.0' = '8.0.46'; '9.7' = '9.7.2' }
    if ($fallback.ContainsKey($series)) { return $fallback[$series] }
    throw "无法确定 MySQL $series 的版本号，请在配置文件中显式指定 MySql.Version"
}

function Install-MySql {
    param([hashtable]$Cfg)
    $ver = Resolve-MySqlVersion -Cfg $Cfg
    $series = $Cfg.MySql.Series
    $svcName = if ($Cfg.MySql.ServiceName) { $Cfg.MySql.ServiceName }
               else { 'MySQL' + ($series -replace '\.', '') }

    Write-Step "安装 MySQL $ver（服务名 $svcName，端口 $($Cfg.MySql.Port)）"
    if ($series -eq '8.0') {
        Write-Warn 'MySQL 8.0 已于 2026-04 随 8.0.46 结束生命周期，建议改用 8.4 LTS。'
    }

    $existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        Write-Skip "服务 $svcName 已存在（状态 $($existing.Status)）"
        if ($existing.Status -ne 'Running') { Start-Service $svcName }
        Add-Result -Name 'MySQL' -Status 'SKIP' -Detail "服务 $svcName 已存在"
        return
    }

    $dest = Join-Path $Cfg.Root "mysql-$ver"
    if (-not (Test-Path (Join-Path $dest 'bin\mysqld.exe'))) {
        $file = "mysql-$ver-winx64.zip"
        $urls = @(
            "https://cdn.mysql.com/Downloads/MySQL-$series/$file",
            "https://dev.mysql.com/get/Downloads/MySQL-$series/$file",
            "https://downloads.mysql.com/archives/get/p/23/file/$file"
        )
        if ($Cfg.UseMirror) {
            $urls = @("https://mirrors.huaweicloud.com/mysql/Downloads/MySQL-$series/$file") + $urls
        }
        $zip = Join-Path (Join-Path $Cfg.Root '.cache') $file
        Invoke-Download -Urls $urls -OutFile $zip -MinBytes 100MB | Out-Null
        Expand-ToDirectory -ZipPath $zip -Destination $dest -Flatten
    }
    else { Write-Skip "MySQL 程序目录已存在：$dest" }

    $dataDir = Join-Path $Cfg.Root 'mysql-data'
    $iniPath = Join-Path $dest 'my.ini'
    Write-MySqlIni -Cfg $Cfg -BaseDir $dest -DataDir $dataDir -IniPath $iniPath -Series $series

    if ($DryRun) {
        Add-Result -Name 'MySQL' -Status 'DRYRUN' -Detail $ver
        return
    }

    $mysqld = Join-Path $dest 'bin\mysqld.exe'

    if (-not (Test-Path (Join-Path $dataDir 'mysql'))) {
        Write-Log '初始化数据目录（--initialize-insecure，root 初始无密码）...'
        if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force }
        New-Dir $dataDir
        & $mysqld "--defaults-file=$iniPath" --initialize-insecure --console 2>&1 |
            ForEach-Object { Write-Log "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "mysqld --initialize-insecure 失败（exit=$LASTEXITCODE）" }
        Write-Ok '数据目录初始化完成'
    }
    else { Write-Skip "数据目录已初始化：$dataDir" }

    if (-not (Get-Service -Name $svcName -ErrorAction SilentlyContinue)) {
        & $mysqld "--install" $svcName "--defaults-file=$iniPath" 2>&1 |
            ForEach-Object { Write-Log "  $_" }
        Write-Ok "已注册 Windows 服务：$svcName"
    }
    Set-Service -Name $svcName -StartupType Automatic
    Start-Service -Name $svcName
    [void](Wait-ForPort -Port $Cfg.MySql.Port -TimeoutSec 60 -Name 'MySQL')

    Set-MySqlRootPassword -BaseDir $dest -Cfg $Cfg

    Add-MachinePath -Entry (Join-Path $dest 'bin')
    Set-MachineEnv -Name 'MYSQL_HOME' -Value $dest

    Add-Result -Name 'MySQL' -Status 'OK' -Detail "$ver / 服务 $svcName / root 密码见配置"
}

function Write-MySqlIni {
    param([hashtable]$Cfg, [string]$BaseDir, [string]$DataDir, [string]$IniPath, [string]$Series)

    # MySQL 8.4 起 mysql_native_password 默认不加载；老 Navicat / 老 JDBC 需要它
    $nativeLine = if ($Cfg.MySql.EnableNativePassword -and $Series -like '8.4*') {
        "mysql_native_password=ON"
    } elseif ($Cfg.MySql.EnableNativePassword -and $Series -like '8.0*') {
        "default_authentication_plugin=mysql_native_password"
    } else { "# 使用默认 caching_sha2_password" }

    $ini = @"
# 由 setup-devenv.ps1 生成于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
[mysqld]
basedir=$BaseDir
datadir=$DataDir
port=$($Cfg.MySql.Port)
bind-address=$($Cfg.MySql.BindAddress)

character-set-server=utf8mb4
collation-server=utf8mb4_0900_ai_ci
default-time-zone='+08:00'

max_connections=500
max_allowed_packet=64M
innodb_buffer_pool_size=512M
innodb_flush_log_at_trx_commit=2

# 开发机常用：关闭 ONLY_FULL_GROUP_BY，避免老 SQL 报错
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION

log-error=$DataDir\mysql-error.log
slow_query_log=1
slow_query_log_file=$DataDir\mysql-slow.log
long_query_time=2

$nativeLine

[client]
port=$($Cfg.MySql.Port)
default-character-set=utf8mb4

[mysql]
default-character-set=utf8mb4
"@
    Write-TextFile -Path $IniPath -Content $ini
}

function Set-MySqlRootPassword {
    param([string]$BaseDir, [hashtable]$Cfg)
    $mysql = Join-Path $BaseDir 'bin\mysql.exe'
    $escaped = ($Cfg.MySql.RootPassword) -replace "'", "''"

    $sql = "ALTER USER 'root'@'localhost' IDENTIFIED BY '$escaped';`n"
    if ($Cfg.MySql.AllowRemoteRoot) {
        Write-Warn 'AllowRemoteRoot=$true：将创建可从任意主机登录的 root 账号，请确保口令足够强。'
        $sql += "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$escaped';`n"
        $sql += "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;`n"
    }
    $sql += "FLUSH PRIVILEGES;`n"

    # 密码不能出现在命令行参数里（任务管理器/进程列表可见），走临时文件 + stdin
    $sqlFile = Join-Path ([IO.Path]::GetTempPath()) ("mysql-init-" + [Guid]::NewGuid().ToString('N') + '.sql')
    try {
        [IO.File]::WriteAllText($sqlFile, $sql, [Text.UTF8Encoding]::new($false))
        # 用 stdin 而不是 -e "source <路径>"：路径里有空格时 source 会断
        $out = Get-Content -LiteralPath $sqlFile -Raw |
               & $mysql -u root --skip-password --protocol=TCP -P "$($Cfg.MySql.Port)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'root 密码已设置为配置文件中的值'
        }
        else {
            Write-Warn "设置 root 密码失败（可能之前已设置过）：$out"
        }
    }
    finally {
        if (Test-Path $sqlFile) {
            # 覆写后再删，避免密码残留在磁盘扇区
            [IO.File]::WriteAllText($sqlFile, ('0' * 4096))
            Remove-Item $sqlFile -Force
        }
    }
}

function Wait-ForPort {
    param([int]$Port, [int]$TimeoutSec = 30, [string]$Name = '服务')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $c = New-Object Net.Sockets.TcpClient
        try {
            $c.Connect('127.0.0.1', $Port)
            if ($c.Connected) { $c.Close(); Write-Ok "$Name 端口 $Port 已就绪"; return $true }
        }
        catch { Start-Sleep -Milliseconds 800 }
        finally { $c.Dispose() }
    }
    Write-Warn "$Name 端口 $Port 在 ${TimeoutSec}s 内未就绪"
    $false
}

#endregion

#region ─────────────────────────── Redis ───────────────────────────

function Resolve-RedisAsset {
    param([hashtable]$Cfg)
    if ($Cfg.Redis.Version) {
        $v = $Cfg.Redis.Version
        return @{
            Version = $v
            Url = "https://github.com/redis-windows/redis-windows/releases/download/$v/Redis-$v-Windows-x64-msys2-with-Service.zip"
        }
    }
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/redis-windows/redis-windows/releases/latest' `
                                 -Headers @{ 'User-Agent' = 'devenv-setup' } -TimeoutSec 25
        $asset = $rel.assets | Where-Object { $_.name -match 'msys2-with-Service\.zip$' } | Select-Object -First 1
        if (-not $asset) {
            $asset = $rel.assets | Where-Object { $_.name -match 'with-Service\.zip$' } | Select-Object -First 1
        }
        if ($asset) {
            Write-Log "解析到 Redis 最新版：$($rel.tag_name) / $($asset.name)"
            return @{ Version = $rel.tag_name; Url = $asset.browser_download_url }
        }
    }
    catch { Write-Warn "解析 Redis 最新版失败：$($_.Exception.Message)" }

    $v = '8.10.0'
    @{
        Version = $v
        Url = "https://github.com/redis-windows/redis-windows/releases/download/$v/Redis-$v-Windows-x64-msys2-with-Service.zip"
    }
}

function Install-Redis {
    param([hashtable]$Cfg)
    Write-Step "安装 Redis（端口 $($Cfg.Redis.Port)）"

    $svc = Get-Service -Name 'Redis' -ErrorAction SilentlyContinue
    if ($svc -and -not $Force) {
        Write-Skip "Redis 服务已存在（状态 $($svc.Status)）"
        if ($svc.Status -ne 'Running') { Start-Service Redis }
        Add-Result -Name 'Redis' -Status 'SKIP' -Detail '服务已存在'
        return
    }

    $asset = Resolve-RedisAsset -Cfg $Cfg
    $dest = Join-Path $Cfg.Root 'redis'
    $dataDir = Join-Path $Cfg.Root 'redis-data'

    if (-not (Test-Path (Join-Path $dest 'redis-server.exe'))) {
        $zip = Join-Path (Join-Path $Cfg.Root '.cache') "redis-$($asset.Version).zip"
        Invoke-Download -Urls (Get-MirrorUrls -Url $asset.Url -Cfg $Cfg) -OutFile $zip -MinBytes 1MB | Out-Null
        Expand-ToDirectory -ZipPath $zip -Destination $dest -Flatten
        # 有的包多套了一层目录
        if (-not (Test-Path (Join-Path $dest 'redis-server.exe'))) {
            $inner = Get-ChildItem $dest -Directory -ErrorAction SilentlyContinue |
                     Where-Object { Test-Path (Join-Path $_.FullName 'redis-server.exe') } |
                     Select-Object -First 1
            if ($inner) {
                Get-ChildItem $inner.FullName -Force | Move-Item -Destination $dest -Force
                Remove-Item $inner.FullName -Recurse -Force
            }
        }
    }
    else { Write-Skip "Redis 程序目录已存在：$dest" }

    New-Dir $dataDir
    $conf = Join-Path $dest 'redis.conf'
    Write-RedisConf -Cfg $Cfg -ConfPath $conf -DataDir $dataDir

    if ($DryRun) { Add-Result -Name 'Redis' -Status 'DRYRUN' -Detail $asset.Version; return }

    $registered = Register-RedisService -Dest $dest -Conf $conf -DataDir $dataDir -Cfg $Cfg
    Add-MachinePath -Entry $dest

    $detail = "$($asset.Version) / " + $(if ($registered -eq 'service') { 'Windows 服务 Redis' }
                                        elseif ($registered -eq 'task') { '计划任务(开机自启)' }
                                        else { '未托管，需手动启动' })
    Add-Result -Name 'Redis' -Status $(if ($registered) { 'OK' } else { 'WARN' }) -Detail $detail
}

function Write-RedisConf {
    param([hashtable]$Cfg, [string]$ConfPath, [string]$DataDir)
    $authLine = if ($Cfg.Redis.Password) { "requirepass $($Cfg.Redis.Password)" }
                else { "# requirepass 未设置：仅监听 127.0.0.1，请勿改成 0.0.0.0" }

    $conf = @"
# 由 setup-devenv.ps1 生成于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
bind 127.0.0.1
protected-mode yes
port $($Cfg.Redis.Port)
timeout 0
tcp-keepalive 300

daemonize no
databases 16

save 900 1
save 300 10
save 60 10000
rdbcompression yes
dbfilename dump.rdb

appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

maxmemory $($Cfg.Redis.MaxMemory)
maxmemory-policy allkeys-lru

$authLine

loglevel notice
"@
    Write-TextFile -Path $ConfPath -Content $conf   # 必须无 BOM，redis 解析不了
}

function Register-RedisService {
    <# 优先用发行包自带的 RedisService.exe；失败则退回“开机计划任务”方案 #>
    param([string]$Dest, [string]$Conf, [string]$DataDir, [hashtable]$Cfg)

    $svcExe = Get-ChildItem -Path $Dest -Filter 'RedisService.exe' -Recurse -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($svcExe) {
        try {
            Write-Log "使用 RedisService.exe 注册服务..."
            & $svcExe.FullName install -c $Conf --dir $DataDir --port "$($Cfg.Redis.Port)" 2>&1 |
                ForEach-Object { Write-Log "  $_" }
            Start-Sleep -Seconds 2
            if (Get-Service -Name 'Redis' -ErrorAction SilentlyContinue) {
                Set-Service -Name 'Redis' -StartupType Automatic
                Start-Service -Name 'Redis' -ErrorAction Stop
                if (Wait-ForPort -Port $Cfg.Redis.Port -TimeoutSec 30 -Name 'Redis') { return 'service' }
            }
            Write-Warn 'Redis 服务注册后未能正常启动，改用计划任务方案。'
            & $svcExe.FullName uninstall 2>&1 | Out-Null
        }
        catch { Write-Warn "RedisService.exe 注册失败：$($_.Exception.Message)" }
    }

    # 兜底：开机计划任务
    try {
        $server = Join-Path $Dest 'redis-server.exe'
        $taskName = 'DevEnv-RedisServer'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $action = New-ScheduledTaskAction -Execute $server -Argument "`"$Conf`"" -WorkingDirectory $DataDir
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        if (Wait-ForPort -Port $Cfg.Redis.Port -TimeoutSec 30 -Name 'Redis') {
            Write-Ok "Redis 已注册为开机计划任务：$taskName"
            return 'task'
        }
    }
    catch { Write-Warn "计划任务注册失败：$($_.Exception.Message)" }

    Write-Warn "Redis 未能自动托管，可手动运行： $Dest\redis-server.exe `"$Conf`""
    $null
}

#endregion

#region ──────────────────────── IDEA / Trae / Git ────────────────────────

function Install-Idea {
    param([hashtable]$Cfg)
    $edition = $Cfg.Idea.Edition
    Write-Step "安装 IntelliJ IDEA ($edition)"

    $ids = if ($edition -eq 'Ultimate') {
        @('JetBrains.IntelliJIDEA.Ultimate')
    } else {
        @('JetBrains.IntelliJIDEA.Community', 'JetBrains.IntelliJIDEA.Ultimate')
    }
    $id = Install-ViaWinget -Ids $ids -Scope 'machine'
    if (-not $id) { $id = Install-ViaWinget -Ids $ids }

    if (-not $id) {
        try {
            Install-IdeaFromJetBrains -Cfg $Cfg -Edition $edition
            $id = 'JetBrains 官方直链'
        }
        catch {
            Write-Err "IDEA 安装失败：$($_.Exception.Message)"
            Add-Result -Name 'IDEA' -Status 'FAIL' -Detail '请手动安装 https://www.jetbrains.com/idea/download/'
            return
        }
    }
    Add-Result -Name 'IDEA' -Status 'OK' -Detail "$edition ($id)"
}

function Install-IdeaFromJetBrains {
    param([hashtable]$Cfg, [string]$Edition)
    $code = if ($Edition -eq 'Ultimate') { 'IIU' } else { 'IIC' }
    $api = "https://data.services.jetbrains.com/products/releases?code=$code&latest=true&type=release"
    $rel = Invoke-RestMethod -Uri $api -TimeoutSec 30
    $info = ($rel.$code)[0]          # 括号必须有，否则会被解析成 $rel.($code[0])
    $url = $info.downloads.windows.link
    if (-not $url) { throw '未从 JetBrains API 获取到下载链接' }

    $exe = Join-Path (Join-Path $Cfg.Root '.cache') "idea-$code-$($info.version).exe"
    Invoke-Download -Urls @($url) -OutFile $exe -MinBytes 100MB | Out-Null
    if ($DryRun) { return }

    # NSIS 静默安装
    $p = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList '/S'
    if ($p.ExitCode -ne 0) { throw "IDEA 安装器退出码 $($p.ExitCode)" }
    Write-Ok "IDEA $($info.version) 安装完成"
}

function Install-Trae {
    param([hashtable]$Cfg)
    Write-Step '安装 Trae'

    $id = Install-ViaWinget -Ids $Cfg.Trae.WingetIds -Scope 'machine'
    if (-not $id) { $id = Install-ViaWinget -Ids $Cfg.Trae.WingetIds }

    if ($id) {
        Add-Result -Name 'Trae' -Status 'OK' -Detail $id
        return
    }

    # Trae 官方没有稳定的静默直链，退化为“打开下载页 + 提示”
    Write-Warn 'winget 安装 Trae 失败。Trae 未提供稳定的静默安装直链，需手动完成。'
    Write-Warn "请打开：$($Cfg.Trae.DownloadPage)"
    if (-not $DryRun) {
        try { Start-Process $Cfg.Trae.DownloadPage } catch { }
    }
    Add-Result -Name 'Trae' -Status 'MANUAL' -Detail "请从 $($Cfg.Trae.DownloadPage) 手动安装"
}

function Install-Git {
    param([hashtable]$Cfg)
    Write-Step '安装 Git'
    if ((Get-Command git -ErrorAction SilentlyContinue) -and -not $Force) {
        Write-Skip "已安装：$(git --version)"
        Add-Result -Name 'Git' -Status 'SKIP' -Detail (git --version)
        return
    }
    $id = Install-ViaWinget -Ids @('Git.Git') -Scope 'machine'
    if ($id) { Add-Result -Name 'Git' -Status 'OK' -Detail $id }
    else { Add-Result -Name 'Git' -Status 'FAIL' -Detail '请手动安装 https://git-scm.com/' }
}

#endregion

#region ─────────────────────── 结果汇总与校验 ───────────────────────

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail)
    $script:Results.Add([pscustomobject]@{ Component = $Name; Status = $Status; Detail = $Detail })
}

function Invoke-Verification {
    param([hashtable]$Cfg)
    Write-Step '安装后校验'
    if ($DryRun) { Write-Skip '演练模式，跳过校验'; return }

    Update-SessionPath
    $javaCurrent = Join-Path $Cfg.Root 'java\current'

    $checks = @(
        @{ Name = 'java';   Cmd = { & (Join-Path $javaCurrent 'bin\java.exe') -version 2>&1 | Select-Object -First 1 } }
        @{ Name = 'javac';  Cmd = { & (Join-Path $javaCurrent 'bin\javac.exe') -version 2>&1 | Select-Object -First 1 } }
        @{ Name = 'mvn';    Cmd = { & (Join-Path $Cfg.Root "apache-maven-$($Cfg.Maven.Version)\bin\mvn.cmd") -v 2>&1 | Select-Object -First 1 } }
        @{ Name = 'python'; Cmd = { & python --version 2>&1 | Select-Object -First 1 } }
        @{ Name = 'pip';    Cmd = { & python -m pip --version 2>&1 | Select-Object -First 1 } }
        @{ Name = 'git';    Cmd = { & git --version 2>&1 | Select-Object -First 1 } }
    )
    foreach ($c in $checks) {
        try {
            $out = & $c.Cmd
            if ($out) { Write-Ok "$($c.Name): $out" } else { Write-Warn "$($c.Name): 无输出" }
        }
        catch { Write-Warn "$($c.Name): 不可用（重开终端后再试）" }
    }

    foreach ($s in @('MySQL84', 'MySQL80', 'MySQL97', 'Redis')) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) { Write-Ok "服务 $s : $($svc.Status) / 启动类型 $($svc.StartType)" }
    }

    $redisCli = Join-Path $Cfg.Root 'redis\redis-cli.exe'
    if (Test-Path $redisCli) {
        try {
            $cliArgs = @('-p', "$($Cfg.Redis.Port)")
            if ($Cfg.Redis.Password) { $cliArgs += @('-a', $Cfg.Redis.Password, '--no-auth-warning') }
            $pong = & $redisCli @cliArgs ping 2>&1
            Write-Ok "redis-cli ping -> $pong"
        }
        catch { Write-Warn "redis-cli 探测失败：$($_.Exception.Message)" }
    }
}

function Show-Summary {
    param([hashtable]$Cfg)
    $elapsed = (Get-Date) - $script:StartTime

    Write-Host ''
    Write-Host ('═' * 74) -ForegroundColor Cyan
    Write-Host '  安装结果汇总' -ForegroundColor Cyan
    Write-Host ('═' * 74) -ForegroundColor Cyan
    $script:Results |
        Format-Table -AutoSize @{ L = '组件'; E = { $_.Component } },
                               @{ L = '状态'; E = { $_.Status } },
                               @{ L = '说明'; E = { $_.Detail } } |
        Out-String -Width 200 | Write-Host

    Write-Host ('─' * 74) -ForegroundColor DarkGray
    Write-Host '  常用信息' -ForegroundColor Cyan
    Write-Host ('─' * 74) -ForegroundColor DarkGray
    Write-Host "  安装根目录     : $($Cfg.Root)"
    Write-Host "  JAVA_HOME      : $(Join-Path $Cfg.Root 'java\current')  (junction，切版本不改环境变量)"
    Write-Host "  切换 JDK       : jdk          -> 查看已装版本"
    Write-Host "                   jdk 8/11/17/21 -> 切换（立即对所有终端和 IDEA 生效）"
    Write-Host "  Maven 配置     : $(Join-Path $script:UserProfile '.m2\settings.xml')"
    Write-Host "  Maven 本地仓库 : $(if ($Cfg.Maven.LocalRepository) { $Cfg.Maven.LocalRepository } else { Join-Path $Cfg.Root 'maven-repo' })"
    $redisAuth = if ($Cfg.Redis.Password) { "密码 $($Cfg.Redis.Password)" } else { '无密码（仅本机）' }
    Write-Host "  MySQL          : $($Cfg.MySql.BindAddress):$($Cfg.MySql.Port)  用户 root  密码 $($Cfg.MySql.RootPassword)"
    Write-Host "  Redis          : 127.0.0.1:$($Cfg.Redis.Port)  $redisAuth"
    Write-Host "  pip 源         : $($Cfg.Python.PipIndex)"
    Write-Host "  日志           : $script:LogFile"
    Write-Host ('─' * 74) -ForegroundColor DarkGray
    Write-Host ("  耗时 {0:mm} 分 {0:ss} 秒" -f $elapsed) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  ⚠  环境变量对"已经打开"的终端不生效，请重开一个终端窗口。' -ForegroundColor Yellow
    Write-Host '  ⚠  MySQL / Redis 密码是开发默认值，请勿用于生产或暴露到公网。' -ForegroundColor Yellow
    Write-Host ''

    $failed = @($script:Results | Where-Object { @('FAIL', 'WARN', 'MANUAL') -contains $_.Status })
    if ($failed) {
        Write-Host '  以下组件需要人工跟进：' -ForegroundColor Yellow
        $failed | ForEach-Object { Write-Host "    - $($_.Component): $($_.Detail)" -ForegroundColor Yellow }
        Write-Host ''
    }
}

#endregion

#region ─────────────────────────── 主流程 ───────────────────────────

function Main {
    Initialize-Log
    Write-Banner

    $cfg = Import-DevEnvConfig
    if ($DryRun) { Write-Host '  *** 演练模式（-DryRun）：不会对系统做任何改动 ***' -ForegroundColor Magenta }

    Write-Log "安装根目录：$($cfg.Root)"
    Write-Log "待安装组件：$($cfg.Components -join ', ')"

    Test-Prerequisite -Cfg $cfg
    New-Dir $cfg.Root
    New-Dir (Join-Path $cfg.Root '.cache')

    $installers = [ordered]@{
        'jdk'    = { Install-Jdk    -Cfg $cfg }
        'maven'  = { Install-Maven  -Cfg $cfg }
        'python' = { Install-Python -Cfg $cfg }
        'mysql'  = { Install-MySql  -Cfg $cfg }
        'redis'  = { Install-Redis  -Cfg $cfg }
        'idea'   = { Install-Idea   -Cfg $cfg }
        'trae'   = { Install-Trae   -Cfg $cfg }
        'git'    = { Install-Git    -Cfg $cfg }
    }

    foreach ($name in $installers.Keys) {
        if ($cfg.Components -notcontains $name) { continue }
        try {
            & $installers[$name]
        }
        catch {
            Write-Err "[$name] 安装失败：$($_.Exception.Message)"
            Write-Log $_.ScriptStackTrace 'ERROR'
            Add-Result -Name $name.ToUpper() -Status 'FAIL' -Detail $_.Exception.Message
        }
    }

    Publish-EnvChange
    Invoke-Verification -Cfg $cfg
    Show-Summary -Cfg $cfg

    $hardFail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
    if ($hardFail) { exit 1 }
}

Main

#endregion
