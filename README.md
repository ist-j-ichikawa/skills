# skills

ist-j-ichikawa の Agent Skills 置き場。**3 通り**で入れられます — GitHub 公式の [`gh skill`](https://cli.github.com/manual/gh_skill)、[skills CLI](https://github.com/vercel-labs/skills)(`npx skills add`)、Claude Code の**プラグイン marketplace**。中身は同じ `skills/<name>/SKILL.md` なので、**いずれか 1 つ**を使えば OK。

## インストール (gh skill — GitHub 公式)

GitHub CLI 2.90.0+ なら、`gh skill` で直接入れられます(Claude Code / Copilot / Cursor 等マルチエージェント対応、agentskills.io 仕様)。バージョン pin ができ、GitHub ネイティブなのが利点。

```bash
# インストール (対話で対象エージェントを選択 → Claude Code なら .claude/skills/ に配置)
gh skill install ist-j-ichikawa/skills publish-html-to-pages

# バージョン固定 (タグやコミットハッシュ。タグは可変なので commit 指定が安全)
gh skill install ist-j-ichikawa/skills publish-html-to-pages --pin <ref>

# 更新 / 検索 / プレビュー
gh skill update
gh skill search pages
gh skill preview ist-j-ichikawa/skills publish-html-to-pages
```

## インストール (skills CLI)

```bash
# 全スキル
npx skills add ist-j-ichikawa/skills

# 特定のスキルだけ
npx skills add ist-j-ichikawa/skills --skill publish-html-to-pages

# 全プロジェクトで使えるようグローバルに入れる (~/<agent>/skills/)
npx skills add ist-j-ichikawa/skills -g
```

インストール時に Symlink（推奨・正本のコピー 1 つを各 agent から参照、更新が楽）か Copy（独立コピー）を選べます。

## インストール (Claude Code プラグイン marketplace)

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

## 更新・管理 (skills CLI)

インストール済みスキルを最新に追従させる / 一覧・削除するコマンド（[skills CLI](https://github.com/vercel-labs/skills) の機能。詳細は本家 README 参照）。

```bash
# インストール済みスキルを最新に更新 (スコープは対話で確認)
npx skills update

# 特定スキルだけ更新
npx skills update publish-html-to-pages

# スコープを指定して更新 (-g: グローバル / -p: プロジェクト / -y: 対話を省略し自動判定)
npx skills update -g

# インストール済み一覧 / 削除
npx skills list
npx skills remove publish-html-to-pages
```

> `update` / `list` は「**実行したディレクトリのスコープ**」に入っているスキルが対象。グローバルに入れたものは `-g`、特定プロジェクトのものはそのプロジェクトのルートで実行する。
>
> skills CLI 経由のインストールは**自動更新されない**。正本に新機能が入っても、`skills update` で取り込み直すまで古いコピーのまま動く(古いまま使うと旧仕様で出力される)。自動更新したい場合は上記のプラグイン marketplace 経由で入れる。
>
> npx のキャッシュ破損で `ENOENT ... _npx/.../package.json` が出たら `rm -rf ~/.npm/_npx` で消してから再実行する（キャッシュは自動再生成される）。

## 収録スキル

| スキル | 概要 |
| --- | --- |
| [`publish-html-to-pages`](skills/publish-html-to-pages/) | 単体 HTML ドキュメントを、実行リポジトリの GitHub Pages 公開ブランチ経由で Pages に公開する skill。公開のたびに公開ブランチ上の全 HTML を走査してルートの `index.html` (動線=ランディングページ) を自動再生成する。`/publish-html-to-pages` を明示的に呼んだときだけ動く。 |
