# codex skill — 活用パターン集

fg(フォアグラウンド軽量クエリ)と bg(バックグラウンド長時間委任)の実績ベースの使い分けと型。

## fg(軽量・read-only・即返し)

短く・読み取りのみ・数分以内で終わるものは fg。`codex exec --ephemeral -s read-only` で直接実行し、出力をそのまま/要約して返す。

### #1 ファクトチェック / 最新情報の確認

- 検証項目を**番号付きリスト**で渡す。
- 「正確 / 不正確 / 要修正」の 3 段階判定を指定。
- 「Web 検索して最新の公式ドキュメントに基づいて」と明示 → `-c web_search=live`(profile があれば `-p search`)。
- Bash `timeout` は 300000(5 分)。多数の Web 検索で時間がかかる。

```bash
codex exec --ephemeral -s read-only --skip-git-repo-check -c approval_policy=never \
  -c web_search=live -m gpt-5.4-mini -c model_reasoning_effort=low \
  "次を最新の公式ドキュメントで検証し各項目を 正確/不正確/要修正 で判定して: 1) ... 2) ..."
```

### #2 セカンドオピニオン / 技術 Q&A

別系列モデル (GPT) の視点を取りに行く。同一分布モデルの自己レビューは相関した盲点が出るので、クロスチェックに価値がある。設計判断・比較・概念説明など。最新性が不要なら web 検索は付けない(`cached` のまま)。

### #3 Bedrock Claude Code の WebSearch 代替

Bedrock 版など WebSearch/WebFetch が使えない環境で Codex の web 検索を代替に使う。WebSearch が使えるならそちらを優先。主流の代替は MCP Search Server(Brave/Tavily)だが、「別 AI の視点も欲しい」場合に Codex が効く。

## bg(長時間・write 可・委任)

書き込み・multi-file 調査・実装修正・レビュー・テスト/ビルド・所要時間不明なものは bg。`run.sh` を `run_in_background:true` で起動し、完了通知を待つ。詳細手順は SKILL.md。

### #4 マルチファイルのリファクタ / 実装委任

- sandbox は `workspace-write`。
- プロンプトは**一発ハンドオフ**として完結させる(Codex は Claude の会話を見られない):何を/制約/読み始める場所/会話で確定済みの前提。
- 開始時に `git status`、完了時に `git diff --stat` を取り、Codex の自己申告でなく実ファイル状態を報告する。

### #5 大きめの調査 / 横断分析(write 不要だが長い)

read-only でも「多数ファイルを横断」「長い web 調査」で数分を超えるなら bg。fg で回すと Claude の 10 分制限に被弾する。**迷ったら bg**。

### #6 追い指示 / 継続(resume)

「さっきの続き」「その修正を適用」は `--resume-last` で直近 Codex session を継続。新しい run dir に継続出力を取る。resume は `--sandbox`/`--cd` を受けない仕様なので run.sh が `-c sandbox_mode=...` で渡す(再開元 cwd を継承)。

## 異常系のハンドリング(bg)

- **hang / 無反応**: run.sh の idle timeout(既定 300s 無出力)が pgid ごと kill し `timed_out`。`job.sh result` で部分出力(log tail)を返す。
- **crash / 異常終了**: exit≠0 で `failed`。`job.sh result` が log の末尾を返す。
- **orphan(ホスト再起動・OOM・-9 で run.sh ごと消滅)**: status が `running` のまま pid 死亡 → `job.sh status`/`result` 実行時に `orphaned` へ自動 reconcile。ゴーストを永遠に待たない。
- **中断**: `job.sh cancel <run-dir>` で codex プロセスグループを kill し `cancelled`。

## プロンプト設計の原則

- argv 直書きせずファイル経由(run.sh は `--prompt-file`、fg は heredoc/一時ファイル)。quoting/injection/長さ事故を防ぐ。
- 日本語で可。技術質問で英語の方が精度が出そうなら翻訳してもよい。
- under-specify が最大の失敗要因。bg は特に、1 段落程度の十分な文脈を与える。
