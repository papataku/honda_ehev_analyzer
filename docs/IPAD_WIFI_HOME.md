# Honda Analyzer: 自宅Mac miniから無料でiPadへWi-Fiインストール

**TestFlight/Apple Developer Programの有料契約は不要。**
Xcodeの無料 **Personal Team** 開発署名を使い、
自宅のMac miniからiPadへアプリをインストールします。
リポジトリには**無線インストール用スクリプト**と
**GitHub Actions手動配信ワークフロー**を追加済みです。
Appleアカウントそのもののサインインと初回iPadペアリングは
Mac/iPad上で行ってください。

## 1. 最初の一度だけ（Mac miniとiPad）

- Mac miniに対象iPadOSをサポートする**完全版Xcode**をインストール。
  `xcode-select -p` が `/Applications/Xcode.app/Contents/Developer` などを指す必要があります。
  初回はMacでXcodeを起動して使用許諾、コンポーネントのインストールを完了。
- Xcode → Settings → Accounts (Apple Accounts) に**無料Apple Account**でサインイン。
  Xcodeで **Personal Team** を選べるようにする。
  Apple Developer Programの年会費は不要です。
- `brew install xcodegen` でXcodeGenをインストール。
- Mac miniとiPadを同一Wi-Fiネットワークに接続。
  Xcode → **Device Hub（Manage Devices）** でiPadをペアリングする。
  **iPadOS 27以降なら無線で初回ペアリングできます。**
  それより古いOSは最初だけ有線ペアリングが必要です。
  iPadで開発者モードの有効化やペアリング確認が求められたら、画面の指示に従う。
  Wi-Fi上でiPadが見えないときはVPN/ゲストネットワーク/端末間分離を確認。
- Xcodeでプロジェクトを一度開き、Signing & Capabilities →
  **Automatically manage signing** をON、TeamをPersonal Teamにする。
  **初回はXcodeのRun Destinationで対象iPadを選び、実機Runを1回完了**させて、
  Personal Teamの開発用プロファイルにそのiPadを登録してください。
  端末登録や開発者アカウントの承認などをXcodeが要求したらMac上で許可します。
  **署名成功後の`HondaAnalyzer.xcodeproj`をそのまま残してください。**
  スクリプトは`xcodegen generate`を繰り返さず、Xcodeで設定した
  Signing & Capabilitiesを保持して、実機iPadを指定してビルドします。
  プロジェクト未作成の場合だけXcodeGenを実行し、署名設定・実機Runを促して一旦停止します。
  `devicectl`のCoreDevice識別子がXcodeのiPad UDIDと異なる場合のみ
  `--xcode-device`でXcode側UDIDを別途指定してください。
  このリポジトリのTeam設定はコミットしなくて構いません。
- iPadで「未信頼のデベロッパ」等の警告が出たときは
  iPad Settings → General → VPN & Device Management で開発者を信頼。
  Developer Modeの要否もiPadの指示に従う。

Apple公式：
[Personal Teamの7日制限](https://developer.apple.com/jp/help/account/basics/about-your-developer-account/)、
[Device Hubの無線ペアリング](https://developer.apple.com/documentation/xcode/pairing-your-devices-with-your-mac)。

## 2. まずはMac miniで手動確認（GitHub Runner不要）

Mac miniの**いつものログインユーザー**で実行：

```bash
cd ~/Developer/honda_ehev_analyzer
git fetch origin
git switch feature/ipad-standard-pid-inventory-issue12
git pull --ff-only

# Xcodeで実機ビルドに成功したHondaAnalyzer.xcodeprojは削除しない

# ペアリングできたiPadの識別子を表示
bash ipad/Scripts/install_wifi.sh --list-devices

# Personal Team IDと、上記のiPad識別子を指定してビルド→署名→インストール
bash ipad/Scripts/install_wifi.sh --team YOURTEAMID --device YOUR_IPAD_ID
```

`YOURTEAMID` はXcodeのPersonal Team（10桁英数字）。
`YOUR_IPAD_ID` はDevice Hub / `devicectl`に表示された対象iPadのID。
複数デバイス接続時の誤インストールを避けるため、**対象ID指定は必須**です。
XcodeのiPad UDIDとCoreDevice IDが異なる場合は次のように分離できます：

```bash
bash ipad/Scripts/install_wifi.sh \
  --team UPXY83S8SR \
  --device <devicectlで表示されたiPadのID> \
  --xcode-device <xcodebuild-showdestinationsのiPadUDID>
```

2026-10-16の実機診断：`DEVELOPMENT_TEAM`や`CODE_SIGN_STYLE`をCLIから
強制すると`No Account for Team`が発生しましたが、これらを渡さず、
既存のXcodeプロジェクトで実機ビルドすると成功しました。
修正済みスクリプトは署名設定を**上書きしません**。
スクリプトは既存アプリを**削除しません**。インストールだけ行い、自動起動もしません
（`--launch` を指定した場合のみ起動）。実行前に車両データの記録を停止してください。

毎回オプションを入れたくない場合：

```bash
export HONDA_APPLE_TEAM_ID=YOURTEAMID
export HONDA_IPAD_DEVICE_ID=YOUR_IPAD_ID
bash ipad/Scripts/install_wifi.sh
```

同じApple TeamとBundle ID `com.papataku.HondaAnalyzer`を維持して上書きインストールすれば、
通常はアプリ内SQLiteを残せます。ただし初回署名変更やインストール失敗に備え、
**最初にiPadからSQLiteファイルを共有・バックアップ**してください。
アプリを削除するとアプリ内データは消えるため、削除して入れ直さないこと。

## 3. GitHub Actionsの手動配信（自宅Mac miniから動かす）

既存のTacoTacoMeterの**Linux/Dockerランナーからは不可**。
Xcode・ログインユーザーのKeychain・Device Hubへのアクセスが必要なので
**macOSホストに直接GitHub Actions Runnerを導入**します。
別リポジトリ専用Runnerは通常自動的に共有されません。

1. `papataku/honda_ehev_analyzer` の
   [Settings → Actions → Runners](https://github.com/papataku/honda_ehev_analyzer/settings/actions/runners)
   → New self-hosted runnerで、Mac mini向けのmacOS runnerを作成。
   `./config.sh` 設定時の追加ラベルに **`honda-ipad-deploy`** を付与。
   配布されたregistration tokenはGitHubに再掲・コミットしない。
2. Mac miniの**Xcodeにログイン済みの同じユーザー**でRunnerを実行。
   初回は `./run.sh` などで対話的に動作確認し、Keychainが利用可能か確認。
   Mac miniでログアウトした状態やDockerでの使用は想定していません。
   ワークフローは新しい一時チェックアウトではなく、デフォルトで
   **`~/Developer/honda_ehev_analyzer`の既存チェックアウト**から実行します。
   これはGUIで成功した`.xcodeproj`署名設定を保持するためです。
   別の保存先を使う場合はGitHub Actions Variable `HONDA_LOCAL_REPO_DIR` を設定します。
   ワークフローは追跡済みファイルにローカル変更がある場合、上書きせずに停止します。
3. GitHub → Settings → Secrets and variables → Actions に登録：
   - **Variables**: `HONDA_APPLE_TEAM_ID` = XcodeのPersonal Team ID
   - **Secrets**: `HONDA_IPAD_DEVICE_ID` = Wi-Fiペアリング済みiPadのDevice Hub識別子
     （公開GitHub Actionsログで端末固有IDを漏らさないため、必ずSecret扱い）
   `home-ipad` Environmentで管理しても構いませんが、workflowから参照できる必要があります。
   配布証明書・TestFlight用APIキー・有料契約は不要。
4. GitHubで `home-ipad` Environmentを作成し、
   **必要に応じて承認者とmainからの配信ルールを設定**して誤インストールを防止。
5. [Actions → Honda Analyzer — Home iPad Wi-Fi Install](https://github.com/papataku/honda_ehev_analyzer/actions/workflows/ipad-wifi-install.yml)
   → **Run workflow**。実行するworkflowブランチは `main` を指定し、
   アプリの `source_ref` として次のいずれかを選択：
   - `feature/ipad-standard-pid-inventory-issue12`：統合収集・自動グラフを含む試験版
   - `main`：標準版
6. Xcodeの開発署名 → iPadへのWi-Fiインストールが成功したら
   GitHub Actionsの実行結果に完了表示が出ます。

GitHub runnerがオンラインでも**iPadがWi-Fiで到達できなければ配信できません**。
この方式はTestFlightのようなインターネット経由の配信ではありません。
Mac miniへのリモート接続自体にはUSBが不要です。

## 4. 7日間の無料署名更新

無料Personal Teamの開発用provisioning profileは発行から**7日で期限切れ**。
7日以内を目安に同じ手動workflowを再実行すれば、
通常はUSB無しで再ビルドと上書きインストールができます。
Appleのアカウント再認証等が求められたらMac miniのXcodeで対応してください。
**完全無人の更新は保証しません。** iPadが自宅Wi-Fi外、オフライン、
ロック状態や車両記録中の場合は実行しないでください。

## 5. トラブルシュート

| 状況 | 対応 |
| --- | --- |
| workflowがqueuedのまま | macOS self-hosted runnerがオンラインか、`honda-ipad-deploy`ラベルがあるか確認 |
| デバイスが見えない | 同一Wi-Fi・Device Hubのペアリング・Developer Mode・iPadのロック解除を確認 |
| `xcodebuild`の署名失敗 | XcodeのApple Account/Personal Team/Automatically Manage Signing・Keychainを確認 |
| 開発用プロファイル期限切れ | ビルド/再署名/上書きインストールを再実行 |
| アプリの更新でログが心配 | iPadのSQLiteを先にエクスポート。Bundle IDや署名主体を変えず、削除しない |

**セキュリティ:** GitHubの未信頼PRコードを、署名鍵がある自宅Mac miniランナーで
勝手に実行しないこと。ワークフローはmainからの手動実行だけで、
選択できるcheckout先もmainと指定の試験ブランチに限定しています。
