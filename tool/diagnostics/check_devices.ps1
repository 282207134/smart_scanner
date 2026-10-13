# 检查扫描仪设备状态
Write-Output "=== 搜索 BC05/1802 (扫描仪) 所有类 ==="
Get-PnpDevice | Where-Object { $_.InstanceId -match 'BC05' -or $_.FriendlyName -match 'USB Camera' } |
  Format-Table Status, Class, FriendlyName, InstanceId -AutoSize | Out-String -Width 220

Write-Output "=== 当前在位的 Camera/Image/Media 类设备 ==="
Get-PnpDevice -PresentOnly | Where-Object { $_.Class -in @('Camera','Image') } |
  Format-Table Status, Class, FriendlyName, InstanceId -AutoSize | Out-String -Width 220

Write-Output "=== 当前在位的 USB 设备 (按 VID:PID) ==="
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^USB' } |
  ForEach-Object {
    if ($_.InstanceId -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
      "{0}  {1}:{2}  {3}" -f $_.Status, $Matches[1], $Matches[2], $_.FriendlyName
    }
  }
