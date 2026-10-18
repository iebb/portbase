# Portbase

[English](README.md) · [简体中文](README.zh-CN.md) · [Español](README.es.md) · [日本語](README.ja.md)

![Portbase — Your Portable DB Client](Docs/images/portbase-github-banner.png)

Portbase は、iPhone・iPad・Mac 向けのネイティブデータベースクライアントです。同じワークスペースで、データベースの閲覧、クエリの実行、結果の確認・編集、グラフの保存ができます。
旧プロジェクト名は PortSQL で、Xcode プロジェクトと iOS ターゲットには現在もこの名前を使用しています。

[App Store からダウンロード](https://apps.apple.com/app/id6762447018) ·
[ビルドワークフロー](https://github.com/iebb/portbase/actions/workflows/app-store-connect.yml) ·
[スクリーンショット](ReviewScreenshots/2.0.0/README.md) ·
[ソースコード](https://github.com/iebb/portbase)

## 対応データベース

| データベース | 機能 |
| --- | --- |
| MySQL / MariaDB | SQL コンソール、スキーマ閲覧、行を一意に特定できる場合の編集、トランザクション、インポート・エクスポート |
| PostgreSQL | SQL コンソール、スキーマ閲覧、行を一意に特定できる場合の編集、トランザクション、インポート・エクスポート |
| SQLite | ローカルファイル、スキーマ閲覧、行を一意に特定できる場合の編集、インポート・エクスポート |
| MongoDB | JSON コマンド、ドキュメントの閲覧・編集、集計パイプライン、インデックス確認、インポート・エクスポート |
| Redis | SCAN によるキー閲覧、型に応じた値の確認、確認操作を伴うコマンド実行・有効期限変更 |
| ClickHouse | HTTP/HTTPS 経由の SQL クエリ、データベースとテーブルの閲覧、結果とグラフ |
| Elasticsearch | JSON リクエスト、インデックスマッピング、検索結果、集計、確認操作を伴うドキュメント書き込み |

機能はエンジンによって異なります。コンソールのトランザクションは MySQL・MariaDB・PostgreSQL に対応しています。
Redis は単一の接続先に対応し、Cluster・Sentinel の自動検出は未実装です。
ClickHouse と Elasticsearch ではリレーショナル型の行エディタは利用できません。詳細は[データベースの対応状況と制限](Docs/portbase.md)（英語）をご覧ください。

## ワークスペース

- 複数のクエリコンソール、下書きの復元、保存済みクエリ、検索可能な実行履歴。
- SQL 補完、整形、パラメータ、Explain、指定行への移動、キーボードショートカット。
- テーブルの絞り込み・並べ替えと、結果列の幅調整・固定・非表示。
- セルの値全体の確認、NULL と空文字の区別、特定可能な行への変更の一括送信。
- 保存済みグラフの手動実行、読み込み済み結果の CSV・JSON エクスポート。対応エンジンではクエリ全体のエクスポートとデータのインポートも利用できます。
- 接続への環境ラベル付けと、本番データ閲覧用の読み取り専用プロファイル。

![Portbase のネイティブ Mac ワークスペース](ReviewScreenshots/2.0.0/macOS/02-sql-console.png)

UI は英語、ドイツ語、スペイン語、フランス語、日本語、韓国語、ブラジルポルトガル語、ロシア語、簡体字中国語、繁体字中国語に対応しています。

## 接続とデータの安全性

既定では、システムの認証局による検証付き TLS を必須にしています。
ホスト名検証付きのプライベート CA、TLS 優先、常時警告を表示する明示的な平文接続にも対応しています。
未信頼の CA はユーザーの確認後にのみ保存されます。TLS 優先で平文に切り替わるのは、対応プロトコルが TLS 非対応を明示した場合だけです。

SSH トンネルは初回接続時にサーバーの SHA-256 ホスト鍵を固定し、鍵の変更時には接続を拒否します。
パスワード、SSH 鍵とパスフレーズ、プライベート CA は端末のキーチェーンに保存されます。接続 JSON と iCloud のデータにはこれらの秘密情報を含めません。
ローカルの SQLite ファイルは端末内に保存されます。

閲覧・グラフ・Explain は読み取り専用の実行ポリシーを使用します。書き込みにはエンジン別の検査と確認が必要で、リレーショナル型の行編集では元の行を特定できる必要があります。
クエリの既定タイムアウトは 30 秒です。メモリに保持する結果は最大 10,000 行で、切り詰め時には明示的に表示します。

## ソースからのビルド

macOS、Xcode 27 以降、Swift 6 対応が必要です。iOS アプリは iOS 18 以降、ネイティブ Mac アプリは macOS 15 以降に対応しています。Mac Catalyst は使用していません。

```sh
git clone https://github.com/iebb/portbase.git
cd portbase
open PortSQL.xcodeproj
```

iPhone/iPad では `PortSQL`、Mac では `PortbaseMac` を選択します。シミュレータのビルドに配布用認証情報は不要です。
実機では、ローカルのチェックアウトで自分の署名チームとケイパビリティを設定してください。コミット済みの App Store 署名設定と移管された iCloud 識別子は、公開中のアプリに属します。

依存関係は Swift Package Manager で解決します。コミット済みのロックファイルと `Packages/mysql-nio` を維持してください。このパッケージには通信処理と型付き値の修正が含まれ、依存関係の更新時にも引き継ぐ必要があります。

`project.yml` が XcodeGen の設定元です。再生成前に、コミット済みプロジェクトの署名とエンタイトルメントを比較し、[AGENTS.md](AGENTS.md) に従ってください。通常のビルドは既存のプロジェクトをそのまま使用できます。

## テスト

インストール済みの iPhone シミュレータを指定して iOS テストを実行します。

```sh
xcodebuild test \
  -project PortSQL.xcodeproj \
  -scheme PortSQL \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO

ruby -Itests/ci -e 'Dir["tests/ci/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
sh scripts/validate-release-inputs.sh
```

外部データベースの結合テストには、それぞれのテスト用サービスが必要です。利用できない場合、シミュレータのテストスイートは該当する検査をスキップします。
MySQL パッケージのテストには破棄可能なデータベースが必要です。既定値はデータベース `test_database`、ユーザー `test_username`、パスワード `test_password` です。

```sh
cd Packages/mysql-nio
MYSQL_HOSTNAME=127.0.0.1 MYSQL_PORT=3306 swift test
```

`MYSQL_DATABASE`・`MYSQL_USERNAME`・`MYSQL_PASSWORD` で変更できます。テストはデータを作成・変更するため、必ずテスト専用のデータベースを使用してください。

## ビルドと App Store Connect

GitHub Actions は `master` に push されたコミット、または手動実行時の `master` のコミットを対象に、iOS とネイティブ macOS をビルドします。
`PortSQLCI`・`PortbaseMacCI` スキーム、`Release-CI` 設定、リポジトリのシークレットにある既存の署名情報と自動プロビジョニングを使用します。Xcode Cloud は廃止済みです。

ワークフローは App Store Connect からアップロード可能なマーケティングバージョンと未使用のビルド番号を選び、App Store 配布に利用できるビルドをアーカイブ・アップロードした後、内部 TestFlight 配布を検証し、外部ベータ審査を申請します。
審査待ち、別ビルドの審査中、審査申請回数の制限があっても、その後のアップロードや内部テストは継続できます。公開版の App Store 審査申請は別の手順です。

詳細は[リリース設定と必要なシークレット](Docs/app-store-connect.md)（英語）をご覧ください。ビルド成果物、認証情報、ローカルプレビュー、一時ファイルは Git の対象外です。

## ソース構成

| パス | 内容 |
| --- | --- |
| `PortSQL/` | 共通モデル、データベースサービス、SwiftUI ビュー、翻訳リソース |
| `PortbaseMac/` | ネイティブ Mac ワークスペース、エディタ、グリッド、アプリのエントリポイント |
| `PortSQLTests/` | アプリとサービスのテスト |
| `Packages/mysql-nio/` | リポジトリ内で管理する MySQL ドライバと回帰テスト |
| `scripts/`・`tests/ci/` | リリースツールと自動化の回帰テスト |
| `Docs/` | 製品仕様、ワークスペースの詳細、リリース文書 |
| `AppStore/`・`fastlane/`・`ReviewScreenshots/` | ストア情報、過去のリリース記録、スクリーンショット |

過去のリリース文書は各申請時点の記録です。現在の審査・配布状況は App Store Connect で確認してください。

## ライセンス

Portbase の独自コードは [BSD 3-Clause ライセンス](LICENSE)で公開しています。
同梱の [MySQL ドライバ](Packages/mysql-nio/LICENSE)と[フォント](PortSQL/Fonts/OFL.txt)には、それぞれのライセンスが適用されます。
