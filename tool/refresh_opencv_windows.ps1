param()

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskConfigPath = Join-Path $taskRoot '.dart_tool/package_config.json'
if (-not (Test-Path -LiteralPath $taskConfigPath)) { return }
$taskConfig = Get-Content -LiteralPath $taskConfigPath -Raw | ConvertFrom-Json
$taskPackage = $taskConfig.packages | Where-Object name -eq 'dartcv4'
if (-not $taskPackage) { return }
$taskUri = [Uri]::new([Uri]::new($taskConfigPath), $taskPackage.rootUri)
$taskPackageRoot = $taskUri.LocalPath
$taskShared = Join-Path $taskRoot '.dart_tool/hooks_runner/shared/dartcv4'
New-Item -ItemType Directory -Path $taskShared -Force | Out-Null
$taskKeep = Join-Path $taskShared 'dartcv_keep.txt'
$taskSymbols = [Collections.Generic.HashSet[string]]::new()
if (Test-Path -LiteralPath $taskKeep) {
    foreach ($taskSymbol in Get-Content -LiteralPath $taskKeep) {
        if ($taskSymbol.Trim()) { [void]$taskSymbols.Add($taskSymbol.Trim()) }
    }
}
# The dependency shares its last AOT export list with JIT/test builds. New
# native calls can otherwise resolve against an older restricted DLL. Keep
# all symbols for our three modules during development, without editing the
# dependency or discarding its compiled OpenCV cache.
foreach ($taskModule in @('core', 'imgproc', 'imgcodecs')) {
    $taskMapping = Join-Path $taskPackageRoot "lib/src/g/$taskModule.record_use_mapping.g.dart"
    $taskBindings = Get-Content -LiteralPath $taskMapping -Raw
    foreach ($taskMatch in [regex]::Matches($taskBindings, "'[^']+': '([^']+)'")) {
        [void]$taskSymbols.Add($taskMatch.Groups[1].Value)
    }
}
[IO.File]::WriteAllLines($taskKeep, @($taskSymbols | Sort-Object))
$taskBuildRoot = Join-Path $taskShared 'build'
if (-not (Test-Path -LiteralPath $taskBuildRoot)) { return }
foreach ($taskVariant in Get-ChildItem -LiteralPath $taskBuildRoot -Directory) {
    $taskCache = Join-Path $taskVariant.FullName 'CMakeCache.txt'
    $taskExports = Join-Path $taskVariant.FullName 'dartcv/dartcv_exports.def'
    if (-not (Test-Path -LiteralPath $taskCache)) { continue }
    if (Test-Path -LiteralPath $taskExports) {
        $taskExisting = [Collections.Generic.HashSet[string]]::new()
        foreach ($taskExport in Get-Content -LiteralPath $taskExports) {
            [void]$taskExisting.Add($taskExport.Trim())
        }
        if ($taskSymbols.IsSubsetOf($taskExisting)) { continue }
    }
    $taskCacheText = Get-Content -LiteralPath $taskCache -Raw
    $taskCmake = [regex]::Match($taskCacheText, '(?m)^CMAKE_COMMAND:INTERNAL=(.+)$').Groups[1].Value.Trim()
    $taskSource = [regex]::Match($taskCacheText, '(?m)^CMAKE_HOME_DIRECTORY:INTERNAL=(.+)$').Groups[1].Value.Trim()
    if (-not (Test-Path -LiteralPath $taskCmake) -or -not (Test-Path -LiteralPath $taskSource)) {
        throw "OpenCV cache references an unavailable compiler or source: $($taskVariant.Name)"
    }
    $taskLog = Join-Path $taskVariant.FullName 'scanner-refresh.log'
    & $taskCmake -S $taskSource -B $taskVariant.FullName "-DDARTCV_KEEP_FILE=$taskKeep" *> $taskLog
    if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath $taskLog -Tail 30; throw 'OpenCV configure failed' }
    & $taskCmake --build $taskVariant.FullName --config Release --target install --parallel 4 *>> $taskLog
    if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath $taskLog -Tail 30; throw 'OpenCV rebuild failed' }
    Write-Output "OpenCV exports refreshed: $($taskVariant.Name)"
}
