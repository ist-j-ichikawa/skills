---
name: publish-html-to-pages
description: 単体 HTML ドキュメントを、実行リポジトリの GitHub Pages 公開ブランチ (`review` / `gh-pages` 等、Pages 設定で決まる) 経由で GitHub Pages に公開する skill。push を伴う外向き操作のため自動起動はせず、ユーザーが明示的に `/publish-html-to-pages` を呼んだときだけ動く。公開ブランチと URL は `gh api .../pages` から動的取得し、対象 HTML 1 ファイルを別 worktree から commit + push する。push のたびに公開ブランチ上の全 HTML を走査してルートの `index.html` (公開済みドキュメントへの動線=ランディングページ) を自動再生成し、同じ commit に含める。本リポの worktree や他ブランチの history は触らない。
disable-model-invocation: true
---

# publish-html-to-pages

単体 HTML ドキュメント (レビュー資料 / 設計書 HTML 等) を、実行リポジトリの GitHub Pages 公開ブランチ経由で Pages に公開する skill。対象 HTML を **1 ファイルだけ** 足したうえで、公開ブランチ上の全 HTML を走査してルートの `index.html` (公開済みドキュメント一覧=ランディングページ) を再生成し、同じ commit で push する。

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

また、HTML を 1 枚ずつ公開しても**それらを横断する入口 (動線) がない**と、URL を都度共有しないと辿れない。そこで push のたびに公開ブランチ上の全 HTML を列挙し、ルートの `index.html` を「公開済みドキュメント一覧」として再生成する (§7)。これで Pages のルート URL がそのままランディングページになり、過去に publish した資料へも index から辿れる。

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
- `basename` (例: `2026-05-28-foo.html`) を抽出しておく。`index.html` は予約名なので、対象ファイルの basename が `index.html` だったら「ランディングページ用に自動生成する名前なので、別名にしてください」と案内して止める (§7 で再生成する index と衝突するため)

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

どのアカウントを使うかが個人 CLAUDE.md / メモリで「この org ならこのアカウント」と決まっていればそれに従う。判断に迷ったらそのまま進めて、§3 や §8 が 403/404 で落ちたら switch して再試行する。

### 3. Pages 設定の取得

実行リポジトリの Pages 設定を取得する (`{owner}`/`{repo}` は gh が現リポに自動解決する):

```bash
gh api repos/{owner}/{repo}/pages \
  --jq '{branch: .source.branch, path: .source.path, html_url: .html_url, public: .public, build_type: .build_type}'
```

ここから変数を確定する:

- `PAGES_BRANCH` = `.source.branch` (例: `review`、`gh-pages` 等)。以降このブランチに push する
- `PAGES_BASE_URL` = `.html_url` (例: `https://xxxx.pages.github.io/`)。公開 URL のベース。**末尾 `/` だけ叩けばランディング (§7 の index.html) が開く**

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

`OWN_WT=0` (自分が作った worktree ではない) として覚えておき、§10 では **消さない**。

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

`OWN_WT=1` として覚えておき、§10 で `git worktree remove` する。

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

サブディレクトリに置かない (公開 URL を `<PAGES_BASE_URL><basename>` に揃えるため)。Pages の `source.path` が `/docs` 等の場合のみ、その配下 (例 `./docs/<basename>`) に置く。`/docs` 公開でも配信 URL はルート扱い (URL に `/docs` は付かない) なので、公開 URL の組み方 (§9) は変わらない。

以降、index も対象 HTML も置く「公開ディレクトリ」を `PUB_DIR` と呼ぶ (`source.path` が `/` なら `.`、`/docs` なら `./docs`)。

### 6. 上書き告知 (同名ファイルが既にあるとき)

「対象ファイルが既に公開ブランチに追跡されているか」で上書きかどうかを判定する。`git add` (§8) の **前**に走るので、`git ls-files` で素直に見るのが確実。

```bash
if git ls-files --error-unmatch -- "<basename>" >/dev/null 2>&1; then
  echo "上書き: <basename> は既に $PAGES_BRANCH にあり、今回の push で上書きされます"
fi
```

> なぜ `git status --porcelain` の文字コードで判定しないか: porcelain の 2 文字は `XY` (X=staged 側 / Y=worktree 側)。§8 の `git add` より前の時点では、既存ファイルを `cp` で上書きしただけの状態は ` M` (先頭スペース + M = 未 staged の modified)、新規ファイルは `??` で出る。`M ` (M + スペース = staged 済み modified) とは位置が逆なので、`M ` を照合すると上書きケースを取りこぼし、告知が出ないまま黙って上書き push される。`git ls-files --error-unmatch` は「追跡対象に既にあるか」を直接見るので、コード位置やタイミングに依存しない。

- **上書きに当たるとき**: 黙って push せず、`AskUserQuestion` で一拍置いて確認する (例: 「`<basename>` は既に公開ブランチ `$PAGES_BRANCH` にあり、今回の push で上書きされます。続けますか？」)。上書き自体は Pages 的には想定内の挙動だが、既存資料を差し替える向きの操作なので明示同意を取る。止められたらここで終了し、§10 の後始末 (worktree 片付け) へ進む。
- **新規 (未追跡) のとき**: 確認は挟まずそのまま続行する (新しく足すだけで既存を壊さないため)。

> 確認の対象は**ユーザーの対象 HTML だけ**。§7 で再生成する `index.html` は毎回上書きされるが、これは「動線を最新に保つ」ための想定内の挙動なので確認は挟まない (毎回確認を出すとノイズになる)。

### 7. index.html (ランディングページ) を再生成

公開ディレクトリ直下の全 HTML (`index.html` 自身は除く) を列挙し、各ファイルの `<title>` を見出しにしたリンク一覧 `index.html` を生成する。§5 で対象 HTML を `cp` 済みなので、**新規公開分もこの時点で列挙対象に入る** (まだ git に追跡されていなくてもファイルとして存在するため、`git ls-files` でなくファイルシステムを列挙する)。

```bash
cd "$PUB_DIR"   # 公開ディレクトリ直下で作業 (source.path が /docs ならその中)
INDEX="index.html"

# 公開ディレクトリ直下の *.html を列挙 (index.html 自身は除外)。
# macOS の find は -printf 非対応なので使わない。先頭 ./ を削ってファイル名降順
# (= 日付プレフィックスが新しい順) に並べる。
FILES=$(find . -maxdepth 1 -name '*.html' ! -name 'index.html' | sed 's#^\./##' | LC_ALL=C sort -r)

{
  cat <<'HEAD'
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>公開ドキュメント一覧</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, -apple-system, "Hiragino Sans", "Noto Sans JP", sans-serif;
         max-width: 760px; margin: 3rem auto; padding: 0 1.2rem; line-height: 1.6; }
  h1 { font-size: 1.5rem; border-bottom: 1px solid currentColor; padding-bottom: .4rem; }
  ul.docs { list-style: none; padding: 0; }
  ul.docs li { padding: .6rem 0; border-bottom: 1px solid color-mix(in srgb, currentColor 15%, transparent); }
  ul.docs a { text-decoration: none; font-size: 1.05rem; }
  ul.docs a:hover { text-decoration: underline; }
  .fname { display: block; font-size: .8rem; opacity: .6; margin-top: .15rem; }
  footer { margin-top: 2rem; font-size: .8rem; opacity: .6; }
</style>
</head>
<body>
<h1>公開ドキュメント</h1>
<ul class="docs">
HEAD

  # ファイルが 1 つも無いこと自体は起きない (§5 で必ず 1 つ cp 済み)。
  printf '%s\n' "$FILES" | while IFS= read -r f; do
    [ -z "$f" ] && continue
    # <title> 抽出: 改行を空白に潰してから素朴に取り出す。タグは大小どちらも拾えるよう
    # [Tt] 文字クラスで書く (BSD/GNU 両対応。sed の I フラグは macOS で不可なため使わない)。
    # 取れなければファイル名にフォールバック。前後空白は trim。
    title=$(tr '\n' ' ' < "$f" | sed -n 's/.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\(.*\)<\/[Tt][Ii][Tt][Ll][Ee]>.*/\1/p' | head -1)
    title=$(printf '%s' "$title" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$title" ] && title="$f"
    # 見出しテキストは HTML エスケープして注入 (& を先に)。href はファイル名を percent-encode。
    esc=$(printf '%s' "$title" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    href=$(jq -rn --arg s "$f" '$s|@uri')
    printf '  <li><a href="%s">%s</a><span class="fname">%s</span></li>\n' "$href" "$esc" "$f"
  done

  cat <<'FOOT'
</ul>
<footer>このページは publish-html-to-pages skill が公開のたびに自動生成しています。</footer>
</body>
</html>
FOOT
} > "$INDEX"

cd - >/dev/null   # 元の worktree ルートに戻る (§8 の git add を相対パスで揃えるため)
```

> 設計メモ:
> - **列挙はファイルシステム (`find`) で行う**。§5 で `cp` したばかりの新規 HTML はまだ git に追跡されていないので、`git ls-files` だと初回公開分が一覧から漏れる。「今ある HTML 全部」を素直に見るためファイルを列挙する。
> - **`<title>` 抽出は素朴版**。`tr` で改行を潰すので複数行に跨る title も拾えるが、1 ファイルに `<title>` が複数ある異常系では最後までを greedy に拾う。実害が出るような HTML はまず無いので、その場合は basename フォールバックに任せる。
> - **エスケープの順序は `&` が先**。元 title に既に `&amp;` 等の実体参照が入っていると二重エスケープ (`&amp;amp;`) になりうるが、未エスケープの `<` `>` を流して一覧 HTML を壊すよりは安全側に倒している。
> - **見た目は外部依存ゼロのインライン CSS**に固定 (再現性重視。CDN もフォント読み込みもしない)。凝った装飾は意図的に避けている。

### 8. commit + push

`git add` は **対象 HTML と `index.html` の 2 ファイルだけ**。`git add .` や `git add -A` は禁止 (公開ブランチに無関係なファイルを混ぜないため)。`PUB_DIR` が `/docs` 等なら、その prefix を付けた相対パスで add する (例 `docs/<basename>` と `docs/index.html`)。

push の直前に、どこへ publish するかを一言告げる (`$PAGES_BRANCH` はリポによって `review` / `gh-pages` / `main` 等まちまちなので、ユーザーが意図と違うブランチへの push に気付けるように)。例: 「公開ブランチ `review` に `<basename>` と index.html を push します」。Pages の公開元は GitHub 側で 1 つに確定しているため選択肢を出す必要はないが、確定先を明示してから進む。

```bash
git add -- "<basename>" "index.html"
git -c commit.gpgsign=false commit -m "<commit message>"
git push origin "$PAGES_BRANCH"
```

commit message は引数で指定が無ければ `publish: <basename>` を使う。

差分が空 (まったく同じ HTML を再 push し、index も変化なし) の場合は commit が空になるので、`git diff --cached --quiet` で事前検出して、その場合は push をスキップして「変更なし、Pages 側は既に最新です」と案内する。

push 時に remote から dependabot の脆弱性警告行 (`GitHub found N vulnerabilities ...`) が出ることがあるが、これはリポ全体の依存関係に対する GitHub 側の通知で、本 skill の push 内容 (HTML + index) とは無関係。push 失敗と誤解しないこと。

### 9. 公開 URL を表示

push 完了後、以下を **目立つ 2 行** で出す (`PAGES_BASE_URL` は末尾 `/` 付きなので basename をそのまま連結。ルート URL がそのままランディング=index.html):

```
公開: <PAGES_BASE_URL><basename>
動線 (一覧): <PAGES_BASE_URL>
```

private Pages (`public: false`) なら「ログイン済みブラウザでのみ閲覧可」を 1 行添える。Pages の反映には 1〜2 分のタイムラグがあることも添える。

basename に日本語など非 ASCII が含まれる場合、上記の素朴連結 URL はブラウザの直打ちでは通るが、Slack やチケットに貼ると壊れることがある。その時は percent-encode 版 (例: `jq -rn --arg s "<basename>" '$s|@uri'` で basename をエンコードして連結) も併記すると貼り付け先で確実に開ける。

### 10. ExitWorktree + `git worktree remove` で畳む

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
- 複数の対象ファイルの一括公開 (1 回 1 ファイル。複数あるなら skill を複数回呼ぶ。ただし index は毎回「公開ブランチ上の全 HTML」を一覧するので、過去分も自動で動線に載る)
- index に対象 HTML 以外の中身を勝手に書く (index は公開済み HTML へのリンク一覧に徹する。説明文や手書きセクションは持たせない)
- 本リポ側 (メイン作業ツリー) でのファイル操作
- 自分が作っていない worktree の削除 (常設の `.claude/worktrees/*` 等は §4 ケース A で再利用するだけ。消すのは自分が切った `/tmp` のものだけ)
- `git push --force` (公開ブランチは単純 fast-forward 前提。最新は §4 の `fetch` + `-B` で揃える)
- Pages 設定の変更 (読み取りのみ。push だけで反映される)

## ハマりどころ

このフローを実際に回して踏んだ落とし穴。事前に知っておくと回避できる。

### Pages 設定まわり

- **GitHub Actions ソースの Pages では使えない**: 公開元が「GitHub Actions」(`gh api .../pages` の `build_type` が `workflow`) のリポでは、ブランチに push しても公開されない。この skill は「ブランチに push すれば公開」される legacy/branch ソース専用。§3 で `build_type == "legacy"` を確認し、`workflow` なら「Actions ソースなので対象外」と案内して止める (`source.branch` が `null` で返ることもあるが、判定は文書化された `build_type` を一次に使う)。
- **`source.path` が `/` でないリポがある**: `/docs` 公開のリポでは、ルートに置いた HTML は公開されない。§3 で `.source.path` を確認し、`/docs` ならその配下に置く (§5)。index.html もその配下 (`docs/index.html`) に生成する。配信 URL はルート扱いなので公開 URL に `/docs` は付かない。
- **push 後すぐは 404**: Pages の反映に 1〜2 分のラグがある。push 直後に 404 でも待てば出る。出続ける場合はファイル名の typo (大文字小文字 / 日本語 / 拡張子) か `source.path` 不一致を疑う。

### index 生成まわり

- **初回公開分が一覧から漏れる罠**: §5 で `cp` したばかりの新規 HTML はまだ git に追跡されていない。一覧を `git ls-files` で作ると初回公開ファイルが index に載らない。§7 は意図して `find` (ファイルシステム) で列挙している。
- **`<title>` が複数行 / 無い HTML**: §7 は `tr` で改行を潰してから抽出するので複数行 title も拾えるが、title が無い HTML はファイル名にフォールバックする。一覧の見出しが basename のままなら「その HTML に `<title>` が無い」と判断できる。
- **macOS の `find` は `-printf` 非対応**: worktree 操作はローカル (darwin) で走る。GNU 専用の `find -printf` や `sed` の `I` フラグ (大小無視) は使わず、`sed 's#^\./##'` と `[Tt]` 文字クラスで代替している。書き換えるときも GNU 専用機能を持ち込まないこと。

### worktree まわり

- **既に worktree session 内から呼ばれると `EnterWorktree(path=/tmp/...)` が弾かれる**: `EnterWorktree` は「既に worktree 内にいる状態での path 切替」では、ターゲットが `.claude/worktrees/` 配下であることを要求する。本 skill は意図して `/tmp` に置くため、この状況では path 切替が通らない。先に `ExitWorktree(action="keep")` でメイン作業ツリーに戻ってから起動するか、`EnterWorktree` を諦めて全コマンドを `git -C "$WT"` で worktree に向ける (§4 のフォールバック)。
- **macOS の `/tmp` は `/private/tmp` への symlink**: `git worktree add /tmp/foo` しても `git worktree list` には `/private/tmp/foo` で登録される。`EnterWorktree(path=...)` の path 照合や後の `git worktree remove` がパス不一致で滑る原因になる。§4 のように `WT="$(realpath /tmp)/..."` で最初から実体パスに寄せておけば全段で表記が揃う。removeは念のため `git worktree remove --force "$WT"` で確実に外す (既に消えていてもエラーは無視してよい)。
- **`EnterWorktree(path=...)` は worktree を消さない**: 自分で `git worktree add` した worktree を `path` モードで開いた場合、`ExitWorktree` は session を戻すだけで実体を残す (`action="remove"` を指定しても消えない)。本リポに戻った後に手動で `git worktree remove --force "$WT"` する (§10)。
- **公開ブランチを既存 worktree が握っている**: `git worktree add -B "$PAGES_BRANCH" ...` は、そのブランチが既にどこかの worktree でチェックアウトされていると `'<branch>' is already used by worktree '...'` で失敗する。これは 2 パターンある。(1) 中断で残った自分の `/tmp/pages-publish-*` の残骸 → `git worktree remove --force <path>` で掃除してよい。(2) レビュー用などに常設された正規の worktree (例 `.claude/worktrees/review`) → 消さずに **§4 ケース A で再利用する**。どちらかは path で判断する (`/tmp/pages-publish-*` は自分の残骸、それ以外は他用途)。§4 の `EXIST_WT` チェックでこの分岐は自動で入る。

### 認証まわり

- **active な gh アカウントが途中で変わる**: 別セッションの操作やグローバル設定変更で active アカウントが切り替わり、Pages 設定取得 (§3) や `git push` が `Repository not found` / 403 / 404 になることがある。ネットワークを叩く前 (§2) に `gh auth status --active` を確認するのが確実。
- **switch しても 403 が続く**: そのアカウントが対象リポ (org) にそもそもアクセスできていない。スコープ不足ではなく権限の問題なので、org owner / リポ管理者に確認する。

## 例

```
ユーザー: /publish-html-to-pages docs/2026-05-28-設計レビュー.html
↓
1. ファイル存在 OK、.html OK、basename が index.html でないこと OK
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
5. cp -- "$SRC" ./2026-05-28-設計レビュー.html   (PUB_DIR=. 。source.path=/docs なら ./docs 配下)
   # 注: 入力 path は §1 で絶対化済み。worktree 内 CWD では本リポの相対 path は解決不能
6. git ls-files --error-unmatch -- 2026-05-28-設計レビュー.html で追跡済みか判定 (= 上書きなら告知・確認)
7. index.html を再生成: find で公開ディレクトリ直下の *.html を列挙 (新規分含む) →
   各 <title> を抽出してリンク一覧 (自己完結テンプレート) を index.html に書き出し
8. git add -- 2026-05-28-設計レビュー.html index.html
   git -c commit.gpgsign=false commit -m "publish: 2026-05-28-設計レビュー.html"
   git push origin review
9. 公開: https://xxxx.pages.github.io/2026-05-28-設計レビュー.html  (private なら要ログイン)
   動線 (一覧): https://xxxx.pages.github.io/
10. ExitWorktree(action="keep") → 本リポ側に戻ったあと、OWN_WT=1 のときだけ git worktree remove --force "$WT"
   (既存 worktree を再利用した OWN_WT=0 の場合は残す)
```
