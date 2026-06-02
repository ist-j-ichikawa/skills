---
name: publish-html-to-pages
description: 単体 HTML ドキュメントを、実行リポジトリの GitHub Pages 公開ブランチ (`review` / `gh-pages` 等、Pages 設定で決まる) 経由で GitHub Pages に公開する skill。push を伴う外向き操作のため自動起動はせず、ユーザーが明示的に `/publish-html-to-pages` を呼んだときだけ動く。公開ブランチと URL は `gh api .../pages` から動的取得し、対象 HTML 1 ファイルだけを別 worktree から commit + push して公開 URL を返す。本リポの worktree や他ブランチの history は触らない。
disable-model-invocation: true
---

# publish-html-to-pages

単体 HTML ドキュメント (レビュー資料 / 設計書 HTML 等) を、実行リポジトリの GitHub Pages 公開ブランチ経由で Pages に **1 ファイルだけ** 公開する skill。

push という外向き・実質不可逆な操作を含むため、モデルからの自動起動は無効化してある (`disable-model-invocation: true`)。ユーザーが `/publish-html-to-pages` を明示的に呼んだときだけ動く。

公開ブランチ名 (`review` 等) も公開 URL も **リポジトリの Pages 設定で決まる**ため、ハードコードせず `gh api repos/{owner}/{repo}/pages` から実行時に取得する。

## 動機

Pages 公開ブランチ (Pages 専用、history 持ち込み禁止で運用されることが多い) に対象 HTML だけを足して push すると、自動で Pages の URL で見られる。だが手順を毎回手で再現すると以下を踏みやすい:

- main の history を公開ブランチに巻き込んでしまう (Pages 専用ブランチが汚れる)
- 関係ないファイルを `git add .` で巻き込む
- 進行中の別ブランチを公開ブランチの checkout で巻き戻してしまう
- 権限のない gh アカウントがアクティブなまま push して 403 (private リポや org 制約のある環境)
- ローカルの公開ブランチが古いまま push して non-fast-forward で弾かれる

この skill は、公開ブランチを本リポの外 (`/tmp`) の専用 worktree に隔離して「対象 HTML 1 ファイルだけを add する」フローに固定することで、これらを手順として踏まないようにする。worktree 操作を `git -C "$WT"` に固める運用でも同じ効果は出せるが、本 skill では誤爆を一段防ぐため `EnterWorktree(path=...)` で session ごと worktree に閉じ込める (§4 参照)。

## 引数

- **必須**: 公開したい HTML ファイル path (絶対 / 相対どちらでも可)
- 任意: commit message (省略時は `publish: <basename>`)

## 前提

- CWD が対象リポジトリ内であること (`git rev-parse --show-toplevel` で確認)
- **本リポのメイン作業ツリーから起動すること**。既に別の worktree session 内にいる場合、§4 の `EnterWorktree(path=/tmp/...)` は `.claude/worktrees/` 配下でない path を受け付けないため弾かれる。その場合は先に `ExitWorktree` でメインに戻ってから起動する (§ハマりどころ参照)
- 対象リポジトリで GitHub Pages が有効化済みで、公開元がブランチ (legacy/branch ソース) であること。GitHub Actions ソースでは使えない (§1・§ハマりどころ参照)
- `gh` CLI が install 済み・対象リポに push 権限のあるアカウントでログイン済み
- 実行環境が Claude Code であり `EnterWorktree` / `ExitWorktree` tool が使えること (session を worktree 内に切り替える前提のため。CLI 単発実行には不向き)

## ワークフロー

### 1. 入力検証 (ローカルのみ、ネットワーク不要)

入力 HTML を検証する:

- 引数の HTML path を解決し、絶対 path に正規化する (`realpath`)。以降 `SRC` として使う
- ファイルが存在しなければ即エラーで終了 (worktree も切らない)
- 拡張子が `.html` でなければ即エラー。GitHub Pages 自体は `.htm` も配信するが、公開 URL を `<basename>` で素直に組むため本 skill は `.html` のみ受け付ける
- `basename` (例: `2026-05-28-foo.html`) を抽出しておく

### 2. gh アクティブアカウント確認

private リポや org 制約のある環境では、対象リポに push 権限のあるアカウントがアクティブでないと、この後の Pages 設定取得 (§3) すら 404/403 で滑ったり、最終的な push が 403 になる。**ネットワークを叩く §3 より前に**ここで確認しておく。

```bash
gh auth status --active
```

active が対象リポに push できるアカウントでなければ switch する。

```bash
gh auth status           # 全アカウントを列挙
gh auth switch -u <対象リポに push 権限のあるアカウント>
```

どのアカウントを使うかが個人 CLAUDE.md / メモリで「この org ならこのアカウント」と決まっていればそれに従う。判断に迷ったらそのまま進めて、§3 や §7 が 403/404 で落ちたら switch して再試行する。

### 3. Pages 設定の取得

実行リポジトリの Pages 設定を取得する (`{owner}`/`{repo}` は gh が現リポに自動解決する):

```bash
gh api repos/{owner}/{repo}/pages \
  --jq '{branch: .source.branch, path: .source.path, html_url: .html_url, public: .public, build_type: .build_type}'
```

ここから変数を確定する:

- `PAGES_BRANCH` = `.source.branch` (例: `review`、`gh-pages` 等)。以降このブランチに push する
- `PAGES_BASE_URL` = `.html_url` (例: `https://xxxx.pages.github.io/`)。公開 URL のベース

**使えないケースは先に弾く**:

- `build_type` が `workflow` の場合 → 公開元が「GitHub Actions」なので、ブランチに push しても公開されない。この skill は対象外。「Actions ソースの Pages なのでこの skill は使えない」と案内して止める (誤ったブランチに push しない)。`build_type` が `legacy` のときだけ続行する
- `404` / 取得失敗 → 「Pages が未設定か、auth (§2) のアカウントに権限がない」と案内して終了
- `.source.branch` が `null` / 空 → ブランチ公開でない。やはり止める

`.source.path` が `/` でない (例: `/docs`) 場合は、その配下に置く必要がある (§5)。`public: false` なら private Pages (閲覧にログインが要る)。

> なぜ `build_type` で判定するか: 「Actions ソースだと `source.branch` が `null` になる」のは観測的には起きるが GitHub の公開 schema には明記がない (schema 上 branch は required 扱い)。文書化された `build_type` (`legacy` / `workflow`) を一次判定に使い、`source.branch` の有無は念のための二次チェックにしている。

### 4. 公開ブランチの worktree を用意して session を切り替える

`PAGES_BRANCH` を **どの worktree でチェックアウトするか**を最初に決める。実運用では、公開ブランチが既に別の worktree (例: `.claude/worktrees/review`) で常設されていることがある (レビュー用に開きっぱなしのリポなど)。その状態で自分用に `git worktree add` しようとすると `'<branch>' is already used by worktree '...'` で**必ず失敗する**ので、先に既存を調べて分岐する。

```bash
# 公開ブランチを既にチェックアウトしている worktree がないか調べる
EXIST_WT=$(git worktree list --porcelain | awk -v b="refs/heads/$PAGES_BRANCH" '
  /^worktree /{p=$2} /^branch /{if($2==b) print p}')
```

**ケース A: 既存 worktree が `$PAGES_BRANCH` を握っている (`EXIST_WT` が非空)**

それを **再利用する** (自分で add すると衝突するため。また、他用途で常設された worktree を勝手に消さない方針に従う)。ただし他作業を壊さないよう、使う前に **clean かつ origin と同期**を確認する。

```bash
WT="$EXIST_WT"
git -C "$WT" fetch origin "$PAGES_BRANCH"
# 未コミットの変更があれば触らない (他の作業中かもしれない)
test -z "$(git -C "$WT" status --porcelain)" || { echo "既存 worktree $WT に未コミット変更あり。中断。"; exit 1; }
# origin より遅れている分だけ前進。乖離 (非 fast-forward) なら勝手に巻き戻さず中断
git -C "$WT" merge --ff-only "origin/$PAGES_BRANCH"
```

`OWN_WT=0` (自分が作った worktree ではない) として覚えておき、§9 では **消さない**。

**ケース B: どの worktree も握っていない (`EXIST_WT` が空)**

従来どおり自分用の worktree を `/tmp` に切り、最新化する。

```bash
# realpath で実体パスに正規化 (macOS の /tmp→/private/tmp 対策、理由は下)。
# タイムスタンプで必ずユニーク名にする (同時実行や残骸で衝突しないため)。
WT="$(realpath /tmp)/pages-publish-$(date +%s)"
git fetch origin "$PAGES_BRANCH"
# -B で local PAGES_BRANCH を origin の最新に揃えてチェックアウトするので、
# ローカルが古いまま push して non-fast-forward で弾かれる事故を防げる。
# 公開ブランチは「この skill が push するだけ」の前提なので、未 push 差分を捨てて困らない。
git worktree add -B "$PAGES_BRANCH" "$WT" "origin/$PAGES_BRANCH"
```

`OWN_WT=1` として覚えておき、§9 で `git worktree remove` する。

> なぜ `realpath /tmp` か: macOS では `/tmp` は `/private/tmp` への symlink で、`git worktree add /tmp/foo` しても `git worktree list` には `/private/tmp/foo` で登録される。`EnterWorktree(path=...)` は「渡した path が `git worktree list` に載っていること」を要求するため、`/tmp/...` のまま渡すとパス表記の食い違いで弾かれうる。最初から `realpath` で実体パスに寄せておけば、add・EnterWorktree・remove の全段で表記が揃う (Linux では `/tmp` は symlink でないので realpath は無害)。

その後、Claude Code の `EnterWorktree` tool を **`path` モード** で呼んで session を切り替える。

- `EnterWorktree(path=$WT)` で session の CWD が worktree 内に移る
- これにより以降のコマンドが本リポを指して暴れる事故を構造的に防げる

ケース A の既存 worktree は `.claude/worktrees/` 配下なら既に worktree session 内にいても `EnterWorktree(path=...)` で入れる。ケース B の `/tmp` worktree は `.claude/worktrees/` 配下でないため、**既に別の worktree session 内から呼ばれた場合は `EnterWorktree(path=/tmp/...)` が弾かれる** (§前提・§ハマりどころ)。なお、すべてのコマンドを `git -C "$WT"` で明示的に worktree 先に向ける運用でも代替できる (tool 必須ではない)。EnterWorktree が使えない状況ではこの `git -C "$WT"` フォールバックに切り替える。

session 切替直後に `pwd` と `git branch --show-current` が `$PAGES_BRANCH` になっていることを必ず確認する。違っていたら ExitWorktree で session を戻し、`git worktree remove --force` で片付けてエラー終了。

### 5. 対象 HTML を worktree 直下にコピー

worktree 直下 (リポルート) に `<basename>` でコピーする。

```bash
cp -- "$SRC" "./<basename>"   # SRC は §1 で絶対化した入力 path
```

サブディレクトリに置かない (公開 URL を `<PAGES_BASE_URL><basename>` に揃えるため)。Pages の `source.path` が `/docs` 等の場合のみ、その配下 (例 `./docs/<basename>`) に置く。`/docs` 公開でも配信 URL はルート扱い (URL に `/docs` は付かない) なので、公開 URL の組み方 (§8) は変わらない。

### 6. 上書き告知 (同名ファイルが既にあるとき)

「対象ファイルが既に公開ブランチに追跡されているか」で上書きかどうかを判定する。`git add` (§7) の **前**に走るので、`git ls-files` で素直に見るのが確実。

```bash
if git ls-files --error-unmatch -- "<basename>" >/dev/null 2>&1; then
  echo "上書き: <basename> は既に $PAGES_BRANCH にあり、今回の push で上書きされます"
fi
```

> なぜ `git status --porcelain` の文字コードで判定しないか: porcelain の 2 文字は `XY` (X=staged 側 / Y=worktree 側)。§7 の `git add` より前の時点では、既存ファイルを `cp` で上書きしただけの状態は ` M` (先頭スペース + M = 未 staged の modified)、新規ファイルは `??` で出る。`M ` (M + スペース = staged 済み modified) とは位置が逆なので、`M ` を照合すると上書きケースを取りこぼし、告知が出ないまま黙って上書き push される。`git ls-files --error-unmatch` は「追跡対象に既にあるか」を直接見るので、コード位置やタイミングに依存しない。

- **上書きに当たるとき**: 黙って push せず、`AskUserQuestion` で一拍置いて確認する (例: 「`<basename>` は既に公開ブランチ `$PAGES_BRANCH` にあり、今回の push で上書きされます。続けますか？」)。上書き自体は Pages 的には想定内の挙動だが、既存資料を差し替える向きの操作なので明示同意を取る。止められたらここで終了し、§9 の後始末 (worktree 片付け) へ進む。
- **新規 (未追跡) のとき**: 確認は挟まずそのまま続行する (新しく足すだけで既存を壊さないため)。

### 7. commit + push

`git add` は対象 1 ファイルだけ。`git add .` や `git add -A` は禁止 (公開ブランチに無関係なファイルを混ぜないため)。

push の直前に、どこへ publish するかを一言告げる (`$PAGES_BRANCH` はリポによって `review` / `gh-pages` / `main` 等まちまちなので、ユーザーが意図と違うブランチへの push に気付けるように)。例: 「公開ブランチ `review` に `<basename>` を push します」。Pages の公開元は GitHub 側で 1 つに確定しているため選択肢を出す必要はないが、確定先を明示してから進む。

```bash
git add -- "<basename>"
git -c commit.gpgsign=false commit -m "<commit message>"
git push origin "$PAGES_BRANCH"
```

commit message は引数で指定が無ければ `publish: <basename>` を使う。

差分が空 (まったく同じ HTML を再 push) の場合は commit が空になるので、`git diff --cached --quiet` で事前検出して、その場合は push をスキップして「変更なし、Pages 側は既に最新です」と案内する。

push 時に remote から dependabot の脆弱性警告行 (`GitHub found N vulnerabilities ...`) が出ることがあるが、これはリポ全体の依存関係に対する GitHub 側の通知で、本 skill の push 内容 (HTML 1 ファイル) とは無関係。push 失敗と誤解しないこと。

### 8. 公開 URL を表示

push 完了後、以下を **目立つ 1 行** で出す (`PAGES_BASE_URL` は末尾 `/` 付きなので basename をそのまま連結):

```
公開: <PAGES_BASE_URL><basename>
```

private Pages (`public: false`) なら「ログイン済みブラウザでのみ閲覧可」を 1 行添える。Pages の反映には 1〜2 分のタイムラグがあることも添える。

basename に日本語など非 ASCII が含まれる場合、上記の素朴連結 URL はブラウザの直打ちでは通るが、Slack やチケットに貼ると壊れることがある。その時は percent-encode 版 (例: `jq -rn --arg s "<basename>" '$s|@uri'` で basename をエンコードして連結) も併記すると貼り付け先で確実に開ける。

### 9. ExitWorktree + `git worktree remove` で畳む

`EnterWorktree` を **`path` モード**で呼んだ場合、`ExitWorktree` は worktree のディレクトリを消さない (tool 仕様: path で入った worktree は session を戻すだけ)。worktree の実体を消すのは **§4 ケース B で自分が作った `/tmp` の worktree だけ** (`OWN_WT=1`)。ケース A で再利用した既存 worktree (例 `.claude/worktrees/review`) は他用途の常設物なので残す。

```
ExitWorktree(action="keep")
↓
# 自分で作った worktree のときだけ実体を消す。既存を再利用した場合 (OWN_WT=0) は残す。
[ "$OWN_WT" = 1 ] && git worktree remove --force "$WT"   # 本リポ側 (session が戻った後) で実行
```

`action="remove"` を指定しても、path モードで入った worktree の実体は消えない (tool が消すのは `EnterWorktree` 自身が `name` モードで作った worktree だけ)。つまり remove を指定しても結果は keep と同じなので、迷わず `keep` を使い実体は `git worktree remove` で消す。`--force` を付けるのは、パス表記の揺れがあっても確実に外すため (既に消えていてもエラーは無視してよい)。

途中でエラーが出た場合も、最後に必ず `ExitWorktree` で session を戻す。`git worktree remove --force` で残骸を消すのは `OWN_WT=1` (自分が作った `/tmp` の worktree) のときだけ。既存を再利用していた (`OWN_WT=0`) なら消さない。

## やらないこと

- 公開ブランチの新規作成 (既に存在する前提。Pages 設定済みのブランチを使う)
- main や他ブランチの merge (公開ブランチは history 持ち込み禁止の運用が前提)
- 複数ファイルの一括公開 (1 回 1 ファイル。複数あるなら skill を複数回呼ぶ)
- 本リポ側 (メイン作業ツリー) でのファイル操作
- 自分が作っていない worktree の削除 (常設の `.claude/worktrees/*` 等は §4 ケース A で再利用するだけ。消すのは自分が切った `/tmp` のものだけ)
- `git push --force` (公開ブランチは単純 fast-forward 前提。最新は §4 の `fetch` + `-B` で揃える)
- Pages 設定の変更 (読み取りのみ。push だけで反映される)

## ハマりどころ

このフローを実際に回して踏んだ落とし穴。事前に知っておくと回避できる。

### Pages 設定まわり

- **GitHub Actions ソースの Pages では使えない**: 公開元が「GitHub Actions」(`gh api .../pages` の `build_type` が `workflow`) のリポでは、ブランチに push しても公開されない。この skill は「ブランチに push すれば公開」される legacy/branch ソース専用。§3 で `build_type == "legacy"` を確認し、`workflow` なら「Actions ソースなので対象外」と案内して止める (`source.branch` が `null` で返ることもあるが、判定は文書化された `build_type` を一次に使う)。
- **`source.path` が `/` でないリポがある**: `/docs` 公開のリポでは、ルートに置いた HTML は公開されない。§3 で `.source.path` を確認し、`/docs` ならその配下に置く (§5)。配信 URL はルート扱いなので公開 URL に `/docs` は付かない。
- **push 後すぐは 404**: Pages の反映に 1〜2 分のラグがある。push 直後に 404 でも待てば出る。出続ける場合はファイル名の typo (大文字小文字 / 日本語 / 拡張子) か `source.path` 不一致を疑う。

### worktree まわり

- **既に worktree session 内から呼ばれると `EnterWorktree(path=/tmp/...)` が弾かれる**: `EnterWorktree` は「既に worktree 内にいる状態での path 切替」では、ターゲットが `.claude/worktrees/` 配下であることを要求する。本 skill は意図して `/tmp` に置くため、この状況では path 切替が通らない。先に `ExitWorktree(action="keep")` でメイン作業ツリーに戻ってから起動するか、`EnterWorktree` を諦めて全コマンドを `git -C "$WT"` で worktree に向ける (§4 のフォールバック)。
- **macOS の `/tmp` は `/private/tmp` への symlink**: `git worktree add /tmp/foo` しても `git worktree list` には `/private/tmp/foo` で登録される。`EnterWorktree(path=...)` の path 照合や後の `git worktree remove` がパス不一致で滑る原因になる。§4 のように `WT="$(realpath /tmp)/..."` で最初から実体パスに寄せておけば全段で表記が揃う。removeは念のため `git worktree remove --force "$WT"` で確実に外す (既に消えていてもエラーは無視してよい)。
- **`EnterWorktree(path=...)` は worktree を消さない**: 自分で `git worktree add` した worktree を `path` モードで開いた場合、`ExitWorktree` は session を戻すだけで実体を残す (`action="remove"` を指定しても消えない)。本リポに戻った後に手動で `git worktree remove --force "$WT"` する (§9)。
- **公開ブランチを既存 worktree が握っている**: `git worktree add -B "$PAGES_BRANCH" ...` は、そのブランチが既にどこかの worktree でチェックアウトされていると `'<branch>' is already used by worktree '...'` で失敗する。これは 2 パターンある。(1) 中断で残った自分の `/tmp/pages-publish-*` の残骸 → `git worktree remove --force <path>` で掃除してよい。(2) レビュー用などに常設された正規の worktree (例 `.claude/worktrees/review`) → 消さずに **§4 ケース A で再利用する**。どちらかは path で判断する (`/tmp/pages-publish-*` は自分の残骸、それ以外は他用途)。§4 の `EXIST_WT` チェックでこの分岐は自動で入る。

### 認証まわり

- **active な gh アカウントが途中で変わる**: 別セッションの操作やグローバル設定変更で active アカウントが切り替わり、Pages 設定取得 (§3) や `git push` が `Repository not found` / 403 / 404 になることがある。ネットワークを叩く前 (§2) に `gh auth status --active` を確認するのが確実。
- **switch しても 403 が続く**: そのアカウントが対象リポ (org) にそもそもアクセスできていない。スコープ不足ではなく権限の問題なので、org owner / リポ管理者に確認する。

## 例

```
ユーザー: /publish-html-to-pages docs/2026-05-28-設計レビュー.html
↓
1. ファイル存在 OK、.html OK
   SRC=$(realpath docs/2026-05-28-設計レビュー.html)
2. gh auth status --active → 対象リポに push できるアカウントか確認 (違えば switch)
3. gh api repos/{owner}/{repo}/pages \
     --jq '{branch:.source.branch, path:.source.path, html_url:.html_url, public:.public, build_type:.build_type}'
   → build_type=legacy  PAGES_BRANCH=review  PAGES_BASE_URL=https://xxxx.pages.github.io/  public=false
   (build_type=workflow や branch=null なら対象外として停止)
4. review を握る worktree を探す: EXIST_WT=$(git worktree list --porcelain ... )
   ・既存あり (例 .claude/worktrees/review): WT=それ; fetch + merge --ff-only で同期確認; OWN_WT=0 (消さない)
   ・既存なし: WT="$(realpath /tmp)/pages-publish-$(date +%s)"; git fetch origin review;
              git worktree add -B review "$WT" origin/review; OWN_WT=1 (後で消す)
   EnterWorktree(path=$WT) で session を切替 (/tmp かつ既に worktree 内なら git -C "$WT" で代替)
   git branch --show-current で review を確認
5. cp -- "$SRC" ./2026-05-28-設計レビュー.html
   # 注: 入力 path は §1 で絶対化済み。worktree 内 CWD では本リポの相対 path は解決不能
6. git ls-files --error-unmatch -- 2026-05-28-設計レビュー.html で追跡済みか判定 (= 上書きなら告知)
7. git add 2026-05-28-設計レビュー.html
   git -c commit.gpgsign=false commit -m "publish: 2026-05-28-設計レビュー.html"
   git push origin review
8. 公開: https://xxxx.pages.github.io/2026-05-28-設計レビュー.html  (private なら要ログイン)
9. ExitWorktree(action="keep") → 本リポ側に戻ったあと、OWN_WT=1 のときだけ git worktree remove --force "$WT"
   (既存 worktree を再利用した OWN_WT=0 の場合は残す)
```
