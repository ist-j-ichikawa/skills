---
name: codex
effort: low
license: MIT
description: |
  Call the OpenAI Codex CLI from Claude Code, auto-routing between a fast
  foreground query and a hardened background delegation. Use whenever the user
  mentions Codex, GPT, or OpenAI, wants another AI's perspective, wants to
  fact-check against live web data, or wants to hand a substantial coding task
  to Codex — even without saying "codex". Foreground mode (read-only, seconds)
  covers web search, fact-check, second opinion, Q&A, and substitutes for
  WebSearch on Bedrock Claude Code. Background mode (write-capable, long-running)
  covers multi-file refactors, deep analysis, reviews, and anything that
  would blow the Bash tool's 10-minute timeout — surviving hangs and
  orphaning where the official codex-plugin does not.
  Triggers: /codex, "Codexに聞いて", "Codexで調べて", "GPTで調べて", "別のAIに聞いて",
  "セカンドオピニオン", "ファクトチェックして", "web検索して", "Codexに任せて",
  "Codexでリファクタ", "ask Codex", "delegate to codex", or any /codex:rescue timeout.
---

# /codex — Codex CLI 統合呼び出し (fg 軽量クエリ + bg 長時間委任)

OpenAI Codex CLI を `codex exec` でヘッドレス呼び出しする。**fg**(フォアグラウンド軽量)と
**bg**(バックグラウンド長時間)を自動で使い分ける 1 本。codex CLI の詳細仕様は
`references/cli-reference.md`、活用パターンは `references/use-cases.md`。

> コードレビューは公式 `/codex:review`、ジョブ管理 UI が要るなら公式 `/codex:rescue` も併用可
> (namespace が違うので衝突しない)。本 skill は公式が未解決の hang/orphan/部分出力欠落を構造的に解消した直接実行版。

## 前提

- **codex CLI が無ければ公式の方法で入れる**: `command -v codex` で確認し、無ければインストールする (Homebrew があれば `brew install --cask codex`、無ければ公式インストーラ `curl -fsSL https://chatgpt.com/codex/install.sh | sh`、npm 派は `npm install -g @openai/codex` ※スコープ付き。無印 `codex` は別物)。確認: `codex --version` (想定 0.137.0 以降)。
- `codex login` 済み、または `OPENAI_API_KEY`/`CODEX_API_KEY` が設定済みであること。未認証なら案内する (鍵・ログインの代行はしない)。公式 docs: https://developers.openai.com/codex

## Step 0: プロジェクト設定の確認 (毎回)

`.codex/config.toml`(CWD 相対)と `~/.codex/config.toml` を Read で同時に読む(無くてもエラー無視)。
設定済みの model / web_search / profiles を把握し `-c` で重複指定しない。`[profiles.search]` 等の
profile v2 (別ファイル `$CODEX_HOME/<name>.config.toml`) があれば `-p <name>` で使う。

## Step 1: fg / bg のルーティング (FR1)

判定して、実行前に **1 行**で「mode / sandbox / 想定時間」を提示してから動く。

- **fg にするのは以下を全て満たす時だけ**: read-only・ファイル編集なし・テスト/ビルドなし・対象が狭い・想定 2〜3 分以内・出力が短い。
- **以下のいずれかなら bg**: 書き込みが要る・multi-file 調査・実装修正・レビュー・テスト/ビルド・依存操作・長い web 調査・成果物(diff/ファイル)が要る・**所要時間が読めない**。
- **迷ったら bg**。軽いクエリを bg に回す損失より、重いタスクを fg で回して Claude の 10 分制限に被弾する損失の方が大きい。
- ユーザー明示の override を尊重: 「軽く聞く/read-only/foreground」→ fg、「委任/background/write/任せて」→ bg。

## Step 2 (fg): フォアグラウンド軽量クエリ

read-only・`--ephemeral`(session 不要)で直接実行。Bash `timeout` は **300000 (5 分) の fail-fast**。
**timeout したら自動で bg に再投入**する(Step 3 へ)。

```bash
codex exec --ephemeral -s read-only --skip-git-repo-check -c approval_policy=never "プロンプト"
# web 検索が要るとき (最新/料金/バージョン/公式ドキュメント/ファクトチェック):
#   profile があれば: -p search
#   無ければ:        -m gpt-5.4-mini -c model_reasoning_effort=low -c web_search="live"
#   ※ web_search は reasoning effort=minimal と非互換。low 以上にする。
```

- web 検索の判定: 「最新/現在/調べて/ニュース/公式ドキュメント/料金/リリース」やバージョン番号・日付・URL・時事・ファクトチェック → `live`。概念説明など最新性不要なものは `cached` のまま。
- 出力は stdout をそのまま表示。200 行超なら要約。exit≠0 は stderr を確認して正直に報告。
- モデル: ユーザー指定があればそれ。無ければ config 既定。軽い検索/確認は `gpt-5.4-mini` + `low` が速い。

## Step 3 (bg): バックグラウンド長時間委任

`scripts/run.sh` を Bash の **`run_in_background: true`** で起動する。これで Bash 10 分制限を回避し、
run.sh が親として codex を握り続け(detached にしない)、idle/wall timeout・orphan・partial output を扱う。

スクリプトはこの SKILL.md と同じディレクトリの `scripts/` 配下にある
(marketplace: `${CLAUDE_PLUGIN_ROOT}/skills/codex/scripts/`、gh skill/user: `~/.claude/skills/codex/scripts/`)。

### 3-1. sandbox を正直に選ぶ

| モード | 用途 |
|---|---|
| `read-only` (既定) | 調査・分析・レビュー。編集しない |
| `workspace-write` | 複数ファイル編集・リファクタ・codegen — 典型的な「委任」 |
| `danger-full-access` | 外部サンドボックス内でのみ |

write を選ぶ前に `git status` を取る(開始時の状態を記録)。

### 3-2. プロンプトをファイルに書く

一発ハンドオフとして完結させる(Codex は Claude の会話を見られない): 何を・制約(触る/触らないファイル, style, テスト期待)・大きいリポなら読み始める場所・会話で確定済みの前提。run dir に `prompt.txt` として保存(argv 直書きしない = NFR5)。

### 3-3. 起動

```bash
RUN_DIR="$HOME/.local/state/j-stack-codex/runs/codex-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUN_DIR"; # prompt.txt を書いてから:
bash <skill-dir>/scripts/run.sh \
  --run-dir "$RUN_DIR" --prompt-file "$RUN_DIR/prompt.txt" \
  --work-dir "$PWD" --sandbox workspace-write
#  任意: --model gpt-5.5 / --effort high / --idle-timeout 600 / --wall-timeout 3600 / --resume-last
#  resume の追い指示は --resume-last (run.sh が -c sandbox_mode= で渡す)
```

`run_in_background: true` で起動し、即ユーザーに run id と run dir を伝える。**ポーリングしない**
(Bash の完了通知を待つ)。途中経過を聞かれたら `job.sh tail "$RUN_DIR" 50`。

### 3-4. 完了後の報告 (job.sh で per-run dir を直読 — app-server 不要)

```bash
bash <skill-dir>/scripts/job.sh status "$RUN_DIR"   # 状態 (orphan は自動 reconcile)
bash <skill-dir>/scripts/job.sh result "$RUN_DIR"   # 最終回答、空なら log 末尾(部分出力)
bash <skill-dir>/scripts/job.sh cancel "$RUN_DIR"   # 中断 (プロセスグループ kill → cancelled)
bash <skill-dir>/scripts/job.sh list                # 全 run 一覧
```

- `status` が `completed` 以外(`failed`/`timed_out`/`cancelled`/`orphaned`)なら、成功を装わず `result`/`tail` の部分出力で正直に報告する(FR6)。
- write モードだったら `git status` / `git diff --stat` を取り、Codex の自己申告でなく**実ファイル状態**を報告する。

## やらないこと / 注意

- 短い read-only クエリを bg に回さない(fg で十分)。逆に重い/書き込み/時間不明は fg に回さない。
- `codex login`/API キーの面倒は見ない(前提)。対話 TUI が欲しい場合は素の `codex` を案内。
- そもそも Codex が不要(Claude が直接やれる)なら使わない。
