# skills

ist-j-ichikawa の Agent Skills 置き場。[skills CLI](https://github.com/vercel-labs/skills) でインストールできます。

## インストール

```bash
# 全スキル
npx skills add ist-j-ichikawa/skills

# 特定のスキルだけ
npx skills add ist-j-ichikawa/skills --skill publish-html-to-pages
```

## 収録スキル

| スキル | 概要 |
| --- | --- |
| [`publish-html-to-pages`](skills/publish-html-to-pages/) | 単体 HTML ドキュメントを、実行リポジトリの GitHub Pages 公開ブランチ経由で Pages に公開する skill。公開のたびに公開ブランチ上の全 HTML を走査してルートの `index.html` (動線=ランディングページ) を自動再生成する。`/publish-html-to-pages` を明示的に呼んだときだけ動く。 |
