# Codex CLI リファレンス (codex-cli 0.137.0 / 確認日 2026-06-09)

一次ソース: ローカル `codex exec --help` / `codex exec resume --help` / `codex --help`、
`~/.codex/config.schema.json`、GitHub `openai/codex` リリースノート、
https://developers.openai.com/codex 。website と `--help` が食い違う場合は 0.137.0 では
`--help` を正とする。

> 更新時は必ず `codex --version` と各 `--help` を再確認し、本ファイルのバージョンと確認日を更新する。

## モデルと reasoning effort

- モデル (0.137.0 ローカルキャッシュ): **`gpt-5.5`(デフォルト/推奨)**, `gpt-5.4`, `gpt-5.4-mini`。
  Pro 系で `gpt-5.5-codex`, `gpt-5.3-Codex-Spark` も docs に記載。Bedrock カタログにも GPT-5.5 追加 (0.136.0)。
  - ⚠️ デフォルトは **gpt-5.5**。旧資料の「gpt-5.4 がデフォルト」は誤り。
- reasoning effort は **6 段階**: `none` / `minimal` / `low` / `medium` / `high` / `xhigh`。
  - exec には effort 専用フラグは無い → `-c model_reasoning_effort=<level>` で指定。
  - ⚠️ `web_search` と `model_reasoning_effort=minimal` は**非互換**。400 `tools cannot be used with reasoning.effort 'minimal'` が出る。web 検索時は `low` 以上にする。

## `codex exec` 主要フラグ (0.137.0 全量に近い)

| フラグ | 説明 |
|---|---|
| `[PROMPT]` | 位置引数。省略 or `-` で stdin から読む。引数 + パイプ stdin 併用時は stdin が `<stdin>` ブロックとして追記される。 |
| `-c, --config <k=v>` | config 上書き。ドット path で nested。値は TOML パース→失敗時リテラル文字列。 |
| `--enable <F>` / `--disable <F>` | `-c features.<name>=true/false` の糖衣。反復可。 |
| `--strict-config` | 未知の config キーでエラー。 |
| `-i, --image <FILE>...` | 画像添付 (スクショ等)。※docs の "container image" は誤記。 |
| `-m, --model <MODEL>` | `gpt-5.5` / `gpt-5.4` / `gpt-5.4-mini` 等。 |
| `--oss` / `--local-provider <lmstudio\|ollama>` | ローカル/OSS プロバイダ。 |
| `-p, --profile <NAME>` | **Profile v2**。`$CODEX_HOME/<name>.config.toml` を base config に重ねる (旧 `[profiles.NAME]` テーブルではない)。 |
| `-s, --sandbox <MODE>` | `read-only` \| `workspace-write` \| `danger-full-access`。 |
| `--dangerously-bypass-approvals-and-sandbox` | 全承認スキップ + サンドボックス無し。外部サンドボックス環境専用。 |
| `-C, --cd <DIR>` | 作業ルート。 |
| `--add-dir <DIR>` | workspace 以外の書込可ディレクトリ追加。 |
| `--skip-git-repo-check` | git 管理外でも実行可 (scratch/自動化で必須)。 |
| `--ephemeral` | session/rollout をディスクに残さない。⚠️ 残らない＝`resume` 不可。 |
| `--ignore-user-config` | `$CODEX_HOME/config.toml` を読まない (auth は CODEX_HOME 使用)。 |
| `--ignore-rules` | execpolicy `.rules` を読まない。 |
| `--output-schema <FILE>` | 最終応答を JSON Schema で制約。 |
| `--color <always\|never\|auto>` | 既定 auto。 |
| `--json` | JSONL イベントストリームを stdout に出力。 |
| `-o, --output-last-message <FILE>` | 最終メッセージをファイルに書く。 |

- `-a/--ask-for-approval` は**対話 `codex` 専用**。exec では `-c approval_policy=...`。
- `--full-auto` / `--search` は **exec に存在しない**。`--full-auto` は deprecated (docs:「`--sandbox workspace-write` を使え」)、`--search` は対話 `codex` 専用。
- exec のサブコマンド: `resume`, `review`, `help`。`exec review` は `--uncommitted` / `--base <BRANCH>` / `--commit <SHA>` / `--title` を持つ。

## `codex exec resume`

`codex exec resume [OPTIONS] [SESSION_ID] [PROMPT]`
- `[SESSION_ID]`: conversation/session UUID か thread 名 (UUID 優先)。
- `--last`: 直近 session を再開 (id 不要)。0.138.0 で state DB 優先解決により高速化。
- `--all`: 全 session 表示 (cwd フィルタ無効化)。
- **受理**: `-c`, `--enable/--disable`, `-i`, `--strict-config`, `-m`, `--dangerously-bypass-*`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--output-schema`, `--json`, `-o`。
- ⚠️ **拒否**: `-s/--sandbox`, `-C/--cd`, `-p/--profile`, `--add-dir`, `--color`。
  → sandbox は `-c sandbox_mode=...`、approval は `-c approval_policy=never` で渡す。cwd は再開元 session のものを継承。

## Web 検索

- config enum `web_search` = `disabled` | `cached`(既定) | `live`。`cached` は OpenAI 管理インデックス (`external_web_access=false`)、`live` は実 fetch。
- exec で有効化: **`-c web_search=live`** (`--search` は使えない)。
- 旧 `tools.web_search` boolean は deprecated → top-level / profile の `web_search` を使う。

## config.toml の要点 (config.schema.json 準拠)

```toml
model = "gpt-5.5"
model_reasoning_effort = "medium"   # none|minimal|low|medium|high|xhigh
approval_policy = "on-request"      # untrusted|on-request|never  (on-failure は deprecated)
sandbox_mode = "workspace-write"    # read-only|workspace-write|danger-full-access
web_search = "cached"               # disabled|cached|live

[sandbox_workspace_write]
network_access = false
writable_roots = ["/path/..."]

[projects."/abs/path"]
trust_level = "trusted"
```

- Profile v2 は**別ファイル** `$CODEX_HOME/<name>.config.toml` を base に重ねる。`-p <name>` で有効化。
- 高速 web 検索 profile 例 (`$CODEX_HOME/search.config.toml`):
  ```toml
  model = "gpt-5.4-mini"
  model_reasoning_effort = "low"
  web_search = "live"
  ```
  → `codex exec -p search "..."` で mini + low + live を一括適用。

## Headless / background の落とし穴

- **stdin ハング**: プロンプト未指定だと stdin 待ちでハング。引数で渡し `</dev/null` で stdin を閉じる。
- **git repo check**: git 管理外で即エラー → `--skip-git-repo-check`。
- **非対話 approval**: `-c approval_policy=never` で承認待ちブロックを防ぐ (`on-failure` は deprecated)。
- **timeout**: Codex 自体は wall-clock timeout を課さない。詰まるのは呼び出し側 (Claude の Bash 10 分制限) → background 化 + watchdog で対処 (本 skill の run.sh)。
- **ephemeral と resume の排他**: `--ephemeral` は session を残さないので後で `resume` できない。継続予定なら付けない。

## 検証済みの headless 起動パターン

```bash
# 一発実行 (read-only, web 検索あり)
codex exec -m gpt-5.5 -c model_reasoning_effort=low -c approval_policy=never \
  -c web_search=live --sandbox read-only --skip-git-repo-check "プロンプト"

# resume (resume は --sandbox/-C 不可。-c で渡す)
codex exec resume --last -c sandbox_mode=read-only -c approval_policy=never "追いプロンプト"
```

## `codex mcp-server` / `codex app-server`

- `codex mcp-server`: Codex 自身を stdio MCP サーバ化。MCP クライアント (別エージェント/IDE/オーケストレータ) が Codex をツールとして駆動できる。headless 連携で `codex exec` をシェルアウトする代わりの選択肢。
- `codex app-server` (experimental): desktop app / remote-control / SDK 用の永続 JSON プロトコルサーバ。`mcp-server` より重い。永続統合向け。
- ※ `codex mcp`(mcp-server と別物): Codex が**クライアントとして**接続する外部 MCP を管理。

## 0.137.0 前後の注目 CHANGELOG

- **0.137.0**: exec で auto-review approval policy を保持 (#23763)。standalone web 検索の並列実行。sandbox setup 修正。`codex plugin list --json`。
- **0.136.0**: `codex archive`/`unarchive`。`codex app-server --stdio`。`deny` read rules を承認バイパス経路でも強制。exec-server がブラウザ origin の websocket を拒否。
- **0.138.0** (次版): `resume --last` を state DB 優先で高速化。effort levels がモデル広告順で流れる。MCP OAuth creds の事前リフレッシュ。
