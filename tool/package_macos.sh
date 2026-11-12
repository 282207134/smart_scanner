#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$project_dir/build/macos/Build/Products/Release/smart_scanner.app"
plist="$app_path/Contents/Info.plist"

if [[ ! -f "$plist" ]]; then
  echo "请先运行 fvm flutter build macos --release --no-pub。" >&2
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
expected_version="$(sed -n 's/^version: //p' "$project_dir/pubspec.yaml")"
if [[ "$version+$build_number" != "$expected_version" ]]; then
  echo "构建版本 $version+$build_number 与项目版本 $expected_version 不一致，请重新构建。" >&2
  exit 1
fi

# Packaging must never conceal an invalid application signature.
/usr/bin/codesign --verify --deep --strict "$app_path"

staging_dir="$(mktemp -d "$project_dir/build/macos-package.XXXXXX")"
trap 'rm -rf "${staging_dir:?}"' EXIT
/usr/bin/ditto "$app_path" "$staging_dir/smart_scanner.app"
ln -s /Applications "$staging_dir/Applications"
cat > "$staging_dir/安装说明.txt" <<EOF
智能高拍仪 $version

将 smart_scanner.app 拖入 Applications 文件夹后启动。
首次使用请按系统提示允许摄像头访问。
EOF

dmg_path="$project_dir/build/SmartScanner-macOS-$version.dmg"
/usr/bin/hdiutil create -volname "SmartScanner $version" \
  -srcfolder "$staging_dir" -fs HFS+ -format UDZO -ov "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path"
(
  cd "$project_dir/build"
  /usr/bin/shasum -a 256 "SmartScanner-macOS-$version.dmg" \
    > "SmartScanner-macOS-$version.dmg.sha256"
)
echo "安装包已生成：$dmg_path"
