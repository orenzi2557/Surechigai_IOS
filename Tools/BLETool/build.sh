#!/bin/bash
# Mac を「すれ違い相手」にして GATT を確かめるツールをビルドする（iPhone が1台しかないとき用）
#
#   ./build.sh
#   open --env DURATION=60 --stdout /tmp/ble.log --stderr /tmp/ble.log BLETool.app --args peripheral <アカウントUUID>
#       → LocalName なし・GATT特性のみで発信（裏にいる iPhone のふり）。iPhone 側がUUIDを読んで POST /encounters するか確認
#   open --env DURATION=40 --stdout /tmp/ble.log --stderr /tmp/ble.log BLETool.app --args central
#       → 近くの Surechigai 端末に接続して GATT 特性を読む（iPhone を画面ロックした状態で試す）
#
# 素の実行ファイルで CoreBluetooth を使うと、macOS のプライバシー保護で強制終了される（exit 134）。
# そのため .app にまとめて open で起動する。初回は Mac に Bluetooth 許可のダイアログが出るので「許可」を押す。
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p BLETool.app/Contents/MacOS
xcrun swiftc -O main.swift -o BLETool.app/Contents/MacOS/BLETool
cp Info.plist BLETool.app/Contents/Info.plist
codesign --force -s - BLETool.app
echo "built: $(pwd)/BLETool.app"
