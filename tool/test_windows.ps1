param([string]$Flutter = 'flutter')

$ErrorActionPreference = 'Stop'
$taskWorkspace = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $taskWorkspace
try {
    & $Flutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & (Join-Path $PSScriptRoot 'refresh_opencv_windows.ps1')

    & $Flutter test --no-pub --concurrency=1 test/protocol_test.dart test/ws_client_test.dart test/export_test.dart test/capture_processor_test.dart test/km_server_backend_test.dart test/native_camera_backend_test.dart test/document_vision_test.dart test/auto_scan_detector_test.dart test/document_capture_test.dart test/page_management_test.dart
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # Separate UI results with a fresh Windows engine for each scenario.
    # Native 0xc0000005 crashes can still occur in isolated tests; never
    # ignore a failed scenario or retry it automatically.
    $taskSource = [IO.File]::ReadAllText((Join-Path $taskWorkspace 'test/ui_flow_test.dart'))
    $taskCases = [regex]::Matches($taskSource, "testWidgets\('([^']+)'")
    foreach ($taskCase in $taskCases) {
        $taskName = $taskCase.Groups[1].Value
        Write-Output "Checking: $taskName"
        & $Flutter test --no-pub --concurrency=1 test/ui_flow_test.dart --plain-name $taskName
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    Write-Output "All core checks completed, plus $($taskCases.Count) UI scenarios."
} finally {
    Pop-Location
}
