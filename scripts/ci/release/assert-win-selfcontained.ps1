# assert-win-selfcontained.ps1 — Windows 安装树自含性判据（0.1.20 W2 门禁）
#
# 背景：v0.1.20 发行包 agentrt-v0.1.20-windows-x86-64.zip 共 531 条目，bin/
# 内只有 8 个 DLL 且全部是 MSVC 运行时（concrt140 / msvcp140* /
# vcruntime140*），没有任何 vcpkg 依赖（libcurl / libssl / zlib1 / sqlite3 /
# cjson / libmicrohttpd / libwebsockets / libevent）。资产一致性判据（28/28
# digest 互证）对此完全无感——它只证"下载到的字节与清单一致"，不证"字节能跑"。
# 干净 Windows 上 daemon 群一个都起不来，而发行流水线全绿。
#
# 判据：bin/ 下每个 PE（.exe/.dll）的每一个依赖 DLL，必须落在
#   ① bin/ 内（随包自带），或
#   ② System32（Windows 自带），或
#   ③ api-ms-win-* / ext-ms-*（API set，由 loader 按 schema 解析，无实体文件）；
# 三者皆否即判负。扫描面含 bin/ 内的 DLL 自身，故覆盖传递依赖闭包。
#
# 用法：pwsh -NoProfile -File assert-win-selfcontained.ps1 -BinDir <stage>\bin

param(
    [Parameter(Mandatory = $true)][string]$BinDir
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BinDir)) {
    Write-Host "::error::安装树 bin/ 不存在: $BinDir"
    exit 1
}
$bin = (Resolve-Path -LiteralPath $BinDir).Path

function Find-Dumpbin {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $null }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if (-not $vs) { return $null }
    $tool = Get-ChildItem -Path (Join-Path $vs 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe') -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($tool) { return $tool.FullName }
    return $null
}

$dumpbin = Find-Dumpbin
if (-not $dumpbin) {
    Write-Host '::error::dumpbin.exe 未找到（vswhere / MSVC 工具链缺失），判据无法执行，按 fail-closed 判负'
    exit 1
}

$peList = @(Get-ChildItem -LiteralPath $bin -File | Where-Object { $_.Extension -in '.exe', '.dll' })
if ($peList.Count -eq 0) {
    Write-Host "::error::bin/ 下无 PE 二进制: $bin"
    exit 1
}

$sys32 = Join-Path $env:SystemRoot 'System32'
$missing = New-Object System.Collections.Generic.List[string]
$sysCount = 0

foreach ($pe in $peList) {
    $out = & $dumpbin /nologo /dependents $pe.FullName 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::error::dumpbin 解析失败: $($pe.Name)"
        exit 1
    }
    foreach ($line in $out) {
        if ($line -notmatch '^\s+([A-Za-z0-9._-]+\.dll)\s*$') { continue }
        $dep = $Matches[1]
        if (Test-Path -LiteralPath (Join-Path $bin $dep)) { continue }
        if ($dep -match '^(api-ms-win-|ext-ms-)') { $sysCount++; continue }
        if (Test-Path -LiteralPath (Join-Path $sys32 $dep)) { $sysCount++; continue }
        $missing.Add("$($pe.Name) -> $dep")
    }
}

if ($missing.Count -gt 0) {
    Write-Host "::error::安装树不自含：$($missing.Count) 条依赖既不在 bin/ 也不在 System32（干净 Windows 上无法启动）"
    $missing | Select-Object -First 60 | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host "[OK] bin/ 自含：$($peList.Count) 个 PE，系统解析 $sysCount 条依赖，包外缺失 0 条"