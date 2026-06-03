# skills

ist-j-ichikawa の Agent Skills 置き場。[skills CLI](https://github.com/vercel-labs/skills) でインストールできます。

## インストール

```bash
# 全スキル
npx skills add ist-j-ichikawa/skills

# 特定のスキルだけ
npx skills add ist-j-ichikawa/skills --skill publish-html-to-pages

# 全プロジェクトで使えるようグローバルに入れる (~/<agent>/skills/)
npx skills add ist-j-ichikawa/skills -g
```

インストール時に Symlink（推奨・正本のコピー 1 つを各 agent から参照、更新が楽）か Copy（独立コピー）を選べます。

## 更新・管理

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
> npx のキャッシュ破損で `ENOENT ... _npx/.../package.json` が出たら `rm -rf ~/.npm/_npx` で消してから再実行する（キャッシュは自動再生成される）。

## 収録スキル

| スキル | 概要 |
| --- | --- |
| [`publish-html-to-pages`](skills/publish-html-to-pages/) | 単体 HTML ドキュメントを、実行リポジトリの GitHub Pages 公開ブランチ経由で Pages に公開する skill。公開のたびに公開ブランチ上の全 HTML を走査してルートの `index.html` (動線=ランディングページ) を自動再生成する。`/publish-html-to-pages` を明示的に呼んだときだけ動く。 |
