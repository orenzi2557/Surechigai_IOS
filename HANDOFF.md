# Surechigai iOS 引き継ぎメモ（HANDOFF）

対象：フロントエンド担当（村上）
最終更新：2026-07-17（BLE検知 → サーバー送信の配線が完了し、実機2台で検証済み）

仕様の正は `Surechigai_Server/設計書_v3.md`。この文書は**iOS側のコードを触るために必要なこと**だけを書く。

---

## 1. 構成（2リポジトリ）

| パス | 役割 |
|---|---|
| `Projects/Surechigai_IOS` | **このリポジトリ。iOSアプリ本体**（SwiftUI / iOS 17+ / bundle id `com.maedataiki.Surechigai`） |
| `Projects/Surechigai_Server` | バックエンド（FastAPI + PostgreSQL）。Dockerで起動 |
| `Projects/SurechigaiApp` | BLEの参考実験。**絶対に変更しない**（読むだけ） |

---

## 2. 起動方法

### サーバ（先に立ち上げる）
```bash
cd Surechigai_Server
docker compose up -d          # API: http://localhost:8000  (Swagger: /docs)
```

### iOSアプリ
Xcodeで `Surechigai.xcodeproj` を開いてRun。コマンドラインなら：
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # 必須
xcodebuild -project Surechigai.xcodeproj -scheme Surechigai \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### サーバに繋ぐとき
アプリの「設定 → サーバー設定」で **モックモードOFF** ＋ **MacのLAN IP** を入力（`ipconfig getifaddr en0` で確認）。
シミュレータなら `127.0.0.1` でよい。実機はLAN IPが必要。

### テストアカウント
`maeda` / `maeda2` / `alice` / `bob`（パスワードは全て `test1234`）

---

## 3. iOSの構成（どのファイルが何をするか）

| ファイル | 役割 |
|---|---|
| `SurechigaiApp.swift` | エントリポイント。共有オブジェクトを生成してenvironmentに注入 |
| `RootView.swift` | ログイン状態で画面出し分け。**BLEとセッションの配線もここ**（アカウントUUIDの受け渡し、検知→送信の接続） |
| `APIClient.swift` | 全HTTP通信。**モックモード分岐もここ** |
| `BLEManager.swift` | BLEの検知・発信のみを担当。サーバーのことは知らない |
| `EncounterSync.swift` | **検知をサーバーへ送る**（`POST /encounters`）。BLEと通信の関心を分離するための層 |
| `SessionStore.swift` | ログイン状態とログインユーザー |
| `KeychainStore.swift` | JWT・UUIDの保存 |
| `AppSettings.swift` | モックON/OFF、サーバーIP |
| `Models.swift` | APIの型（snake_case ↔ camelCase変換） |
| `MockData.swift` | モック時のダミーデータ |
| `HomeView` / `EncounterDetailView` / `ProfileView` / `EditProfileView` / `MapPinsView` / `SettingsView` / `DeveloperView` | 各画面 |
| `Theme.swift` / `Components.swift` | 配色・共通部品（`.card()` など） |

### モックモード
`AppSettings.useMock`（既定ON）。`APIClient` が全メソッドの先頭で分岐し、300ms待って `MockData` を返す。
**サーバー無しでUIだけ触りたいときはこれ。** 新しいAPIを足すときは、モック側の分岐も書くこと。

---

## 4. すれ違いが成立するまでの流れ（中核）

```
BLEManager が相手を検知
  → アドバタイズのLocalNameから「相手のアカウントUUID」を復元
  → onDetect コールバック
  → EncounterSync.handle() が POST /encounters
  → サーバーが matches に pending を作成（★片方向でOK。両方向は不要）
  → 双方の「すれ違った人一覧」に表示される
  → 双方が承認して初めてSNSリンクが開示される
```

### ★ アカウントUUIDはBase64URLで詰めて運んでいる（重要）

BLEのアドバタイズは**31バイトしかない**。128bitのサービスUUIDだけで18バイト使うので、
**36文字のUUID文字列は載らない**（以前は `prefix(20)` で切り詰めていて復元不能だった＝バグ）。

UUIDの実体は16バイトなので、**Base64URLの22文字**に詰めて `CBAdvertisementDataLocalNameKey` に載せている。
受信側は `BLEIdentity.decode()` で36文字のUUIDに復元する。→ **実機2台で復元成功を確認済み。**

- サーバーのUUIDは**小文字**（Python の `str(uuid4())`）。Swiftの `uuidString` は**大文字**なので、
  **必ず `.lowercased()` する**（しないとDBの突合に失敗して404）。
- 復元できない検知（無関係なBLE機器）は**送信しない**。ログに `相手UUID=復元不可` と出るのは正常。
- 送るのは**必ずアカウントUUID**。`peripheral.identifier` は端末ごとのランダム値なのでサーバーと突合できない。

### マッチ On/Off（`match_enabled`）
- オフにすると**発信もスキャンも止まる**（相手に拾われず、自分も拾わない）。
- **判定はクライアント側のみ**。サーバーは値を保存するだけで、`POST /encounters` でガードしていない（意図的な判断）。

---

## 5. 実装済み / 未実装

### できている
ログイン・新規登録、ホーム（すれ違い一覧・マッチOn/Off）、すれ違い詳細（承認→SNS開示）、
プロフィール表示/編集、マップ（サーバー連携）、設定、開発者画面、モックモード、
**BLE検知 → サーバー送信（実機検証済み）**

### 未実装（優先順）
1. ★★ **マッチ拒否UI**（サーバー `POST /matches/{uuid}/reject` は完備）
2. ★★ **ブロックUI**（サーバー `POST/GET/DELETE /blocklist` は完備）
3. ★★ 画像のリサイズ/圧縮（現状は生データ送信・content-typeがjpeg固定）、SNSリンク編集UI（`PUT /users/me/sns_links` は完備）、登録時のタグ入力
4. ★ 通知（FCM）、Bluetooth一時ID（固定UUID配信の追跡対策）、頻度制限（同一相手1日1回）

---

## 6. ハマりどころ（gotchas）

- コマンドラインの `xcodebuild` は **`DEVELOPER_DIR=...` の指定が必須**。
- **BLEは実機でしか動かない**（シミュレータは `.unsupported`）。すれ違いテストには**iPhone 2台**必要。
  シミュレータでは開発者画面の「テストデータを注入」で送信経路まで確認できる。
- UIは**ライトモード固定**（`.preferredColorScheme(.light)`）。固定配色なので端末ダーク時に崩れるのを防いでいる。
- **無料の開発者アカウント**なので、実機のプロビジョニングは**7日で失効**する（失効したら再インストール）。
  さらに**プロファイルは1端末につき1つ**しか出ないので、2台に入れるなら端末ごとにビルドが要る。
- `UpdateMeRequest` は nil を送らない（encodeIfPresent）→ サーバーは未指定フィールドを「変更なし」として扱う。
- 日時は**秒精度ISO8601（末尾Z）**。Swiftの `.iso8601` は小数秒を解釈できないので、サーバー側が合わせている。
- シミュレータで文字入力が化けるときは、Simulatorの **I/O → Keyboard →「Use the Same Keyboard Language as macOS」をOFF**にする（日本語IMEが介入するため）。

---

## 7. 実機ですれ違いをテストする手順

1. サーバー起動（`docker compose up -d`）、MacのIPを確認（`ipconfig getifaddr en0`）
2. 2台にインストール（端末ごとにビルドが必要）
   ```bash
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcrun devicectl list devices                      # 端末IDを確認
   xcodebuild ... -destination 'id=<端末ID>' -allowProvisioningUpdates build
   xcrun devicectl device install app --device <端末ID> <ビルドした.app>
   ```
3. 各端末で「設定 → 一般 → VPN とデバイス管理」から開発者Appを**信頼**（端末ごとに1回）
4. 2台で**別アカウント**にログイン（例：`maeda` と `maeda2`）、モックOFF＋MacのLAN IPを設定
5. 2台を近づける
6. 確認方法：
   - アプリの**開発者画面**「サーバー送信」カードに成功件数が出る
   - ログを見る：`xcrun devicectl device process launch --device <端末ID> --console com.maedataiki.Surechigai`
     → `[BLE] 検出(実機): ... 相手UUID=<36文字>` と `[すれ違い送信] 成功:` が出れば成功
   - DBを直接見る：
     ```bash
     docker compose exec db psql -U surechigai -d surechigai \
       -c "SELECT user_uuid_my, user_uuid_you, rssi, detection_method FROM encounters ORDER BY detected_at DESC LIMIT 5;"
     ```

**2026-07-17の検証結果**：iPhone 15 Pro（maeda）と 16 Pro（maeda2）が相互に検知し、
両方向の `encounters` 行（RSSI -60 / -80、緯度経度あり、`detection_method=ble`）と
`pending` のマッチ1行がDBに作られることを確認済み。
