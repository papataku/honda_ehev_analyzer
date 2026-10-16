# Honda Analyzer (iPad) — TestFlight配信

iPadをMacへUSB接続し直さず、TestFlightアプリから更新するための配信フローです。
**TestFlightへ登録済みという意味ではありません。** Apple Developer Program と本人の
App Store Connect 設定が済んで初めてアップロードできます。

## 前提

1. [Apple Developer Program](https://developer.apple.com/programs/) 有効会員。
   無料の Personal Team 署名では TestFlight 配信はできません。
2. [App Store Connect](https://appstoreconnect.apple.com/) にアプリを追加：
   - Platform: iOS
   - App: Honda Analyzer
   - Bundle ID: **com.papataku.HondaAnalyzer** （現在のアプリを変更しない）
   - SKU: 任意。別の既存アプリとBundle IDを重複登録しない。
3. 「Certificates, Identifiers & Profiles」で
   **Apple Distribution** 証明書（秘密鍵を含む \`.p12\`）と
   **App Store Connect / iOS App Store** 用のプロビジョニングプロファイルを作成。
   証明書を作っただけで秘密鍵があるわけではないので、同じMacのキーチェーンから
   秘密鍵付き \`.p12\` をエクスポートする。別の組織の証明書を使わない。
4. App Store Connect の「Users and Access → Integrations → App Store Connect API」で
   **App Manager** 権限の API key を作成し、Issuer ID、Key ID、
   ダウンロード時に一度だけ表示される \`AuthKey_*.p8\` を保管。

Apple アカウント情報、証明書、秘密鍵は**Gitへコミットしない**こと。

## GitHub Actions の設定

[リポジトリの Settings](https://github.com/papataku/honda_ehev_analyzer/settings)
→ Secrets and variables → Actions へ追加する。
GitHub Actions の \`testflight\` Environment を必要に応じて作成し、
承認者を設定すると誤配信を抑止できる。登録先を repository / environment
のいずれにする場合も、本ジョブから参照できることを確認する。

### Variables（公開しても秘密ではない識別子）
| 名前 | 内容 |
| --- | --- |
| \`APPSTORE_TEAM_ID\` | Apple Developer Team ID（10桁英数字） |
| \`APPSTORE_ISSUER_ID\` | App Store Connect API Issuer ID |
| \`APPSTORE_API_KEY_ID\` | 作成したAPI Key ID |

### Secrets（**公開・ログ・コミット不可**）
| 名前 | 内容 |
| --- | --- |
| \`APPSTORE_API_PRIVATE_KEY\` | \`AuthKey_*.p8\` の**中身全体**。BEGIN/END行を含む |
| \`APPSTORE_CERTIFICATES_FILE_BASE64\` | Apple Distribution 秘密鍵入り \`.p12\` のBase64 |
| \`APPSTORE_CERTIFICATES_PASSWORD\` | 上記 \`.p12\` のエクスポート時パスワード |

\`.p12\` をBase64にする例（ローカルMacで実行し、出力をGitHub Secretへ登録）：

\`\`\`bash
base64 -i /path/to/ios_distribution.p12 | pbcopy
\`\`\`

署名用プロファイルはワークフロー内の
\`Apple-Actions/download-provisioning-profiles@v7\` が
Apple側に登録済みの有効な \`IOS_APP_STORE\` プロファイルを取得する。
API keyだけでは .p12 の秘密鍵を復元できない。

## TestFlightへアップロード

1. [GitHub Actions](https://github.com/papataku/honda_ehev_analyzer/actions/workflows/ipad-testflight.yml)
   → **iPad TestFlight (manual)** → **Run workflow**。
2. Workflowを実行するブランチは **main** にする
   （配信定義を改変したPRから直接署名秘密鍵を使わないため）。
3. \`source_ref\` を選択：
   - \`main\`：本流のiPadアプリ
   - \`feature/ipad-standard-pid-inventory-issue12\`：統合収集・PID変化グラフを含む実機テスト版
4. \`app_version\` は初期値 \`0.4.0\`。既存のApp Store Connectで同バージョンの配信制約がある場合は上げる。
   ビルド番号は GitHub Actions の通し番号 \`GITHUB_RUN_NUMBER\` を使用。
5. ジョブが Swift テスト → Xcode 26 以上で実機用アーカイブ作成 → 配布用署名 →
   IPA出力 → App Store Connectへアップロードし、処理完了を確認する。
   失敗した場合はジョブログを確認。秘密鍵を Issue/PRへ貼らない。
6. App Store Connect → Honda Analyzer → TestFlight でビルドを確認し、
   「Internal Testing」グループを作成、対象ビルドを割り当て、自分を内部テスターに追加。
   一度iPadのTestFlightから招待を承諾すれば、以降はTestFlightからインストール・更新できる。

内部テスターはApp Store Connectにアクセスできるユーザーが対象（最大100名）。
知人等の外部テスター（最大1万人）に配る場合は別グループとAppleのBeta App Reviewが必要。
**一般公開のApp Store審査や本番販売はこのワークフローでは行わない。**
ビルドのテスト可能期間は通常90日。

## 運用・注意

- アップロードは**手動トリガー**のみ。通常のpushやPRではAppleの署名を実行しない。
- Apple署名情報が未登録の段階では preflight で失敗し、**署名済みIPAもTestFlight招待リンクもまだ存在しない**。
- \`macos-26\` runnerのXcode 26系を使用。通常の回帰CIは従来どおりSimulatorで独立実行。
- 初回のApp Store Connect側アプリ登録、証明書・API Key発行、初回テスター登録は
  Appleアカウントの管理者作業が必要。
- デバッグ中の \`feature/ipad-standard-pid-inventory-issue12\` は main へ未マージ。
  TestFlightへの配信はそれをマージする操作とは別。
- 初回実車試験では運転中のiPad操作をしない。停車0 km/hはPレンジの証明ではないので、
  未知DID探索は停車条件で動く「読取専用」実験機能として扱う。
- Appleによるアプリの暗号化輸出コンプライアンス確認が必要になる場合は
  App Store Connect画面で事実に即して対応する。未確認の免除宣言は自動追加しない。
