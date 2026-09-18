# grok-build-nix

[English](README.md) | **日本語**

[![Build](https://github.com/gesop0n/grok-build-nix/actions/workflows/build.yml/badge.svg)](https://github.com/gesop0n/grok-build-nix/actions/workflows/build.yml)
[![Update Grok](https://github.com/gesop0n/grok-build-nix/actions/workflows/update.yml/badge.svg)](https://github.com/gesop0n/grok-build-nix/actions/workflows/update.yml)

xAI のターミナル型コーディングエージェント [**Grok Build**](https://github.com/xai-org/grok-build)
を、バージョン固定・再現可能な derivation としてパッケージ化した Nix flake です。

公式の導入方法は `curl -fsSL https://x.ai/cli/install.sh | bash` で、バージョン固定のない
自己更新バイナリが `~/.grok/bin` に置かれます。この flake は代わりに、ハッシュ検証つきで
特定バージョンを固定します。これにより各マシンの状態を宣言的かつ再現可能に保てます。

## クイックスタート

```bash
nix run github:gesop0n/grok-build-nix
```

初回のみ `grok login` で認証し（エンタープライズ環境では `GROK_DEPLOYMENT_KEY` を設定）、
セッションを開始します。

```bash
cd your-project
grok                                  # 対話型 TUI を起動
grok -p "このリポジトリの構成を説明して"   # ヘッドレス実行（単発）
```

## インストール

### flake input として追加

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    grok-build-nix = {
      url = "github:gesop0n/grok-build-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

更新を明示的な操作にしたい場合は、タグで特定のリリースに固定できます。

```nix
grok-build-nix.url = "github:gesop0n/grok-build-nix/v1.0.34";
```

### Home Manager

```nix
{ inputs, pkgs, ... }:
{
  home.packages = [
    inputs.grok-build-nix.packages.${pkgs.system}.default
  ];
}
```

### NixOS / nix-darwin

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.grok-build-nix.packages.${pkgs.system}.default
  ];
}
```

### overlay

どこからでも `pkgs.grok` として参照したい場合は overlay を使います。

```nix
{
  nixpkgs.overlays = [ inputs.grok-build-nix.overlays.default ];
  environment.systemPackages = [ pkgs.grok ];
}
```

### 手続き的にインストール

```bash
nix profile install github:gesop0n/grok-build-nix
```

## 対応プラットフォーム

| Nix system       | 上流アーティファクト | flake の出力            |
| ---------------- | ------------------- | ----------------------- |
| `aarch64-darwin` | `macos-aarch64`     | あり                    |
| `aarch64-linux`  | `linux-aarch64`     | あり                    |
| `x86_64-linux`   | `linux-x86_64`      | あり                    |
| `x86_64-darwin`  | `macos-x86_64`      | overlay のみ（下記参照）|

nixpkgs 26.11 が `x86_64-darwin` のサポートを削除したため、この flake は Intel Mac 向けの
per-system 出力を公開できません（その出力は評価すら通りません）。derivation 自体はこの
プラットフォームに対応しているので、nixpkgs 26.05 を固定すれば `overlays.default` 経由で
`pkgs.grok` として利用できます。`sources.json` はまさにこのケースのために
`x86_64-darwin` のハッシュを維持し続けます。

上流は Windows 向けビルドも配布していますが、Nix の対象外です。

## このパッケージが行うこと

- **公式のリリースバイナリを取得します。** ホストのプラットフォーム向けのものを
  `https://x.ai/cli` から取得し（上流の GCS バケットをミラーとして併用）、
  [`sources.json`](sources.json) のハッシュで検証します。
- **内蔵の自動アップデータを無効化します。** ラッパーで `GROK_DISABLE_AUTOUPDATER=1` を
  設定します。Nix ストアは読み取り専用なので自己更新は成功しえず、更新はこの flake 側で
  行います。`grok update` による更新情報の確認自体は引き続き動作します。
- **bash / zsh / fish の補完をインストールします。** ビルド時に `grok completions` を
  実行して生成します。
- **バイナリには一切手を加えません。** Linux 版は static-pie、Darwin 版は署名済み Mach-O
  であり、どちらも fixup phase で壊れてしまうため `dontPatchELF` と `dontStrip` を
  設定しています。Grok は画面モード切り替え時に自分自身を再 exec するため、実体は
  `libexec/grok` に置き、ファイル名を `grok` のまま維持しています。
- **ビルド時に自己検査します。** `installCheckPhase` で `grok --version` を実行し、
  固定したバージョンと一致することを検証します。

## パッケージのオプション

他の nixpkgs の derivation と同様に override できます。

```nix
inputs.grok-build-nix.packages.${pkgs.system}.default.override {
  withAgentAlias = true;
}
```

| オプション                | 既定値            | 説明                                                                                               |
| ------------------------ | ---------------- | -------------------------------------------------------------------------------------------------- |
| `withAgentAlias`         | `false`          | 上流のインストーラと同様に、バイナリを `agent` という名前でもリンクします。`agent` は `PATH` 上で衝突しやすいため既定では無効です。`grok-with-agent-alias` パッケージとしても公開しています。 |
| `disableAutoUpdater`     | `true`           | ラッパーで `GROK_DISABLE_AUTOUPDATER=1` を設定します。                                                |
| `installShellCompletions`| ネイティブビルド時のみ | シェル補完を生成します。ビルドしたバイナリの実行が必要なため、クロスコンパイル時は無効になります。        |
| `sources`                | `./sources.json` | リリースのメタデータ。独自の JSON を指定すれば、別のバージョンやチャンネルに固定できます。                |

## 更新

バージョンの固定情報は [`sources.json`](sources.json) の 1 ファイルにまとまっています。

```json
{
  "channel": "stable",
  "version": "1.0.34",
  "platforms": {
    "aarch64-darwin": { "artifact": "macos-aarch64", "hash": "sha256-..." }
  }
}
```

[`scripts/update.sh`](scripts/update.sh) がこのファイルを書き換えます。チャンネルの
バージョンポインタを解決し、全プラットフォームのハッシュを取得し直し、その結果が
ビルドできることまで検証します。途中で失敗した場合は元の固定内容に復元されます。

```bash
./scripts/update.sh                  # チャンネルの最新リリースに追従する
./scripts/update.sh --check          # 更新があれば終了コード 1、エラー時は 2 で終了する
./scripts/update.sh --version 1.0.34 # 特定のバージョンに固定する
./scripts/update.sh --channel alpha  # チャンネルを切り替える（stable | alpha | enterprise）
```

[Update Grok](.github/workflows/update.yml) ワークフローがこれを毎時実行し、上流が更新
されていれば Pull Request を作成します。続いて [Build](.github/workflows/build.yml) が
対応する全プラットフォームでビルドとテストを行い、[Tag Release](.github/workflows/tag.yml)
が `main` に `v<version>` タグと、移動する `latest` タグを付与します。

## リポジトリ構成

```
.
├── flake.nix                 # 出力: packages, apps, checks, devShell, overlay
├── package.nix               # derivation 本体
├── sources.json              # 固定情報: チャンネル、バージョン、プラットフォーム別ハッシュ
├── scripts/update.sh         # sources.json を書き換えてビルドを検証する
└── .github/workflows/
    ├── build.yml             # 対応する全プラットフォームでのビルドとテスト、flake check
    ├── update.yml            # 毎時の上流チェックと PR 作成
    └── tag.yml               # 固定バージョンで main にタグを付与
```

## 開発

```bash
nix develop           # cachix、jq、nix-prefetch、nixfmt、shellcheck を利用できる
nix build .#grok      # 現在のシステム向けにビルドする
nix flake check       # checks を評価してビルドする
nix flake check --all-systems   # 現在のシステムだけでなく全システムを評価する
nix fmt               # Nix ファイルを整形する
```

### 任意: バイナリキャッシュ

CI は `CACHIX_AUTH_TOKEN` シークレットが存在する場合のみ [Cachix](https://cachix.org) に
push し、無ければ該当ステップをスキップします。有効にするには、キャッシュを作成したうえで
リポジトリシークレット `CACHIX_AUTH_TOKEN` を設定してください。キャッシュ名が `grok-build`
と異なる場合は、リポジトリ変数 `CACHIX_CACHE` も設定します。

利用者側は Nix の設定で opt-in します。

```nix
nix.settings = {
  substituters = [ "https://grok-build.cachix.org" ];
  trusted-public-keys = [ "grok-build.cachix.org-1:..." ];
};
```

## 関連リポジトリ

- [xai-org/grok-build](https://github.com/xai-org/grok-build) — 上流
- [sadjow/claude-code-nix](https://github.com/sadjow/claude-code-nix) — Claude Code 向けの同じ発想のリポジトリ
- [sadjow/codex-cli-nix](https://github.com/sadjow/codex-cli-nix) — Codex CLI 向けの同じ発想のリポジトリ

## ライセンス

このリポジトリのパッケージング部分は MIT ライセンスです。[LICENSE](LICENSE) を参照してください。

Grok Build 自体は xAI による別個の著作物であり、独自の条項のもとで配布されています
（上流のソースは Apache-2.0）。この flake は公式のリリースバイナリを再パッケージする
だけのものであり、xAI とは提携しておらず、公認も受けていません。
