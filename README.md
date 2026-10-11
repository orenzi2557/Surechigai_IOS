# Surechigai_IOS（動作検証用アプリ）

すれ違いマッチの**動作検証用**iOSアプリ。不具合が iPhone 側とサーバー側（`Surechigai_Server`）のどちらにあるかを切り分けるために使う。
**リリースするのはフロント班の `Surechigai-Match-front`**。このアプリはストアにも TestFlight にも出さない。

- サーバーの全API（21本）を画面から呼べる。開発者画面からBLE検知の注入・再送キューの確認ができる
- BLE（LocalName＋GATT特性）の形式は Match-front と同じなので、Match-front の端末ともすれ違える
- 起動方法・注意点は `HANDOFF.md`、ここで見つかった課題はサーバーリポジトリの `テストアプリを使用して出てきた課題_v1.md`
