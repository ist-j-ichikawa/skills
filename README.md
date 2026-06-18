# skills

ist-j-ichikawa の Agent Skills 置き場。導入は **GitHub 公式の [`gh skill`](https://cli.github.com/manual/gh_skill)(個人におすすめ)** か **Claude Code プラグイン marketplace(チームにおすすめ・自動更新)** を推奨します。中身は同じ `skills/<name>/SKILL.md` なので、いずれか 1 つを使えば OK。

> [`npx skills add`(vercel skills CLI)](https://github.com/vercel-labs/skills) は**非推奨**です。`gh skill` にほぼ上位互換され(GitHub 公式・バージョン pin・マルチエージェント)、自動更新も無いため。既存利用者向けに末尾に残します。

**目次**

- [収録スキル](#収録スキル)
- [インストール: gh skill(個人におすすめ)](#インストール-gh-skill--github-公式--個人におすすめ)
- [インストール: marketplace(チームにおすすめ)](#インストール-claude-code-プラグイン-marketplace--チームにおすすめ)
- [(非推奨) vercel skills CLI](#非推奨-vercel-skills-cli)

## 収録スキル

| スキル | 概要 |
| --- | --- |
| [`publish-html-to-pages`](skills/publish-html-to-pages/) | 単体 HTML ドキュメントを、実行リポジトリの [GitHub Pages](https://docs.github.com/pages) 公開ブランチ経由で Pages に公開する skill。公開のたびに公開ブランチ上の全 HTML を走査してルートの `index.html` (動線=ランディングページ) を自動再生成する。`/publish-html-to-pages` を明示的に呼んだときだけ動く。図解は [`README`](skills/publish-html-to-pages/README.md)。 |
| [`codex`](skills/codex/) | Claude Code から [OpenAI Codex CLI](https://developers.openai.com/codex) (`codex exec`) を呼ぶ skill。fg(フォアグラウンド軽量: web検索/ファクトチェック/セカンドオピニオン/Q&A)と bg(バックグラウンド長時間委任: リファクタ/大規模調査/write 可)を自動ルーティングする。bg は `run_in_background` で Bash の 10 分制限を回避しつつ、idle/wall timeout・orphan 回収・部分出力を扱う堅牢ラッパー ([`scripts/run.sh`](skills/codex/scripts/run.sh) + [`job.sh`](skills/codex/scripts/job.sh)) で、公式 codex-plugin が未解決の hang/orphan 問題を構造的に解消する。「Codexに聞いて」「Codexに任せて」等で起動。図解は [`README`](skills/codex/README.md)、詳細は [`SKILL.md`](skills/codex/SKILL.md) / [CLI リファレンス](skills/codex/references/cli-reference.md)。 |
| [`codex-key-bootstrap`](skills/codex-key-bootstrap/) | クライアント提供の OpenAI API キーを、macOS Keychain + [direnv](https://direnv.net) + リポジトリスコープの `CODEX_HOME` 経由で安全に使えるよう、対象リポジトリをセットアップ/監査する skill。生の鍵は Keychain だけに置き、`.envrc` で `OPENAI_API_KEY` を注入、[OpenAI US エンドポイント](https://us.api.openai.com/v1) を使う。Codex CLI と Claude Code の `codex-plugin-cc` が同じ設定を継承する。リポジトリの `.envrc` を読んだときだけ鍵が有効。鍵の流れ・セットアップ手順の図解は [`README`](skills/codex-key-bootstrap/README.md)（日本語）、モデル向け指示は [`SKILL.md`](skills/codex-key-bootstrap/SKILL.md)（英語）。**macOS 専用**。起動名 `/codex-key-bootstrap`（marketplace 経由は `/j-stack:codex-key-bootstrap`）。 |

> 下のインストール例は `publish-html-to-pages` を使っていますが、**skill 名は任意に置き換え可**です（例: `codex-key-bootstrap`）。起動名は gh skill / vercel CLI 経由なら `/<skill>`、marketplace 経由なら `/j-stack:<skill>`。

## インストール (gh skill — GitHub 公式 / 個人におすすめ)

GitHub CLI 2.90.0+ なら、`gh skill` で直接入れられます(Claude Code / Copilot / Cursor 等マルチエージェント対応、agentskills.io 仕様)。バージョン pin・GitHub ネイティブが利点。リリース tag は ruleset で immutable 化してあるので、tag 固定でも安全です。

```bash
# グローバル (user スコープ) に Claude Code 用で入れる ← おすすめ。~/.claude/skills/ に配置され全プロジェクトで効く
gh skill install ist-j-ichikawa/skills publish-html-to-pages --agent claude-code --scope user

# バージョン固定 (immutable な tag。さらに固めたいなら commit SHA でも可)
gh skill install ist-j-ichikawa/skills publish-html-to-pages --agent claude-code --scope user --pin v0.2.0

# 更新 / 検索 / プレビュー
gh skill update                                   # 手動更新 (自動更新ではない)
gh skill search pages
gh skill preview ist-j-ichikawa/skills publish-html-to-pages
```

> 既定は project スコープ + `--agent github-copilot`(非対話時)。Claude Code でグローバルに使うなら上記のとおり `--agent claude-code --scope user` を明示する。引数を省いて `gh skill install` だけなら対話でリポ/スキル/エージェントを選べる。

### vercel skills CLI から `gh skill` への移行

すでに `npx skills add` で入れている場合、同じ配置先 (`~/.claude/skills/...`) を使うため**先に旧版を外してから**入れ直すと綺麗です(二重管理・`--force` 上書きを避ける)。

```bash
# 1. vercel skills CLI 版を外す
npx skills remove publish-html-to-pages -g

# 2. gh skill で入れ直す (グローバル / Claude Code)
gh skill install ist-j-ichikawa/skills publish-html-to-pages --agent claude-code --scope user
```

## インストール (Claude Code プラグイン marketplace — チームにおすすめ)

Claude Code 本体のプラグイン機能でも配布しています。marketplace 経由は **起動時に自動更新**できるので、チームで同じバージョンを保ちたい・更新忘れで品質が振れるのを防ぎたいときはこちらが向きます。

```text
# marketplace を追加
/plugin marketplace add ist-j-ichikawa/skills

# プラグインを install (j-stack に skills/ 一式が同梱)
/plugin install j-stack@ist-j-ichikawa-skills
```

**自動更新の有効化を推奨します。** サードパーティ marketplace は既定で自動更新 OFF なので、各自で ON にしてください(これをしないと skills CLI と同じく古いまま固定され、品質が振れます)。

- `/plugin` → Marketplaces タブ → `ist-j-ichikawa-skills` → **Enable auto-update**、または
- `settings.json`(`~/.claude/settings.json` など)に直接:

  ```json
  {
    "extraKnownMarketplaces": {
      "ist-j-ichikawa-skills": {
        "source": { "source": "github", "repo": "ist-j-ichikawa/skills" },
        "autoUpdate": true
      }
    }
  }
  ```

- **チーム/組織で配るなら**、上記を **managed settings**(`managed-settings.json`)やプロジェクトの `.claude/settings.json` に入れておけば、メンバー全員で自動更新 ON を既定にできる(各自トグル不要)。複数人で品質が振れる問題の根本対策。
- 起動名は **namespace 付き**になる: 例 `/j-stack:publish-html-to-pages`（skills CLI 経由だと `/publish-html-to-pages`）
- `disable-model-invocation: true` の skill はプラグイン経由でも同じく「明示呼び出しのみ」で動く

## (非推奨) vercel skills CLI

`npx skills add` 系([vercel skills CLI](https://github.com/vercel-labs/skills))。GitHub 公式の `gh skill` にほぼ上位互換され(バージョン pin・公式・マルチエージェント対応)、**自動更新も無い**ため、新規導入は上の `gh skill` か marketplace を推奨します。既存利用者向けに残します(`gh skill` への移行は上の「vercel skills CLI から `gh skill` への移行」を参照)。

```bash
npx skills add ist-j-ichikawa/skills          # 追加
npx skills update -g                          # 更新 (手動・自動更新なし)
npx skills list                               # 一覧
npx skills remove publish-html-to-pages -g    # 削除
```

> `update` / `list` は実行したディレクトリのスコープが対象(グローバルは `-g`)。npx キャッシュ破損で `ENOENT ... _npx/.../package.json` が出たら `rm -rf ~/.npm/_npx` 後に再実行(キャッシュは自動再生成)。

