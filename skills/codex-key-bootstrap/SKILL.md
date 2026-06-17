---
name: codex-key-bootstrap
description: Set up or audit a macOS repository so Claude Code with codex-plugin-cc and the Codex CLI safely use a client-provided OpenAI API key through macOS Keychain, direnv, a repo-scoped CODEX_HOME, and the OpenAI US endpoint. Use when configuring team members, arbitrary local repo paths, multiple client keys on one machine, per-repository OpenAI API usage, or checking that no raw key is written.
metadata:
  short-description: Safely configure repo-scoped client OpenAI key usage
---

# Client OpenAI Key Setup

Use this skill to configure a local macOS repository so the Codex CLI and Claude Code's official
`codex-plugin-cc` use a client-provided OpenAI API key safely and automatically. The skill writes the
files inline, so there is no need to copy the repo's `templates/` directory (those templates are the
canonical reference for the same content).

## Goals

- Work for any local repo path (not just ghq layouts).
- Keep the raw API key only in macOS Keychain.
- Scope Codex config to one repo via `CODEX_HOME=<repo>/.codex-client`.
- Use the OpenAI US endpoint `https://us.api.openai.com/v1`.
- Support Claude Code by relying on `codex-plugin-cc` inheriting the local environment and Codex config.
- Support multiple clients on one machine via distinct Keychain service names.

## Never Do

- Never paste, print, log, commit, or write the raw API key.
- Never put a raw key in `.env`, `.envrc`, TOML, JSON, YAML, shell scripts, docs, tests, or fixtures.
- Never write the literal placeholder `__ABSOLUTE_REPO_ROOT__` (or `<...>`) into `config.toml` — always
  substitute the real absolute path from `pwd -P`.
- Never add provider settings to the child repo's `.codex/config.toml`; Codex ignores `model_provider`
  and `model_providers` in project-local config by design.
- Never solve this with shell aliases, zsh functions, or a `codex` wrapper.
- Never change `~/.codex/config.toml` to select the client provider globally unless the user explicitly
  wants every repo to use it.

## Prerequisite check

Confirm the user has the plugin and tools (do not block on it, but mention any gap):

- `codex` CLI on PATH (`command -v codex`); install with `npm install -g @openai/codex` if missing.
- `direnv` on PATH and hooked into the shell (`eval "$(direnv hook zsh)"` in `~/.zshrc`).
- In Claude Code: `/plugin install codex@openai-codex` from marketplace `openai/codex-plugin-cc`.

## Setup Workflow

1. **Confirm the target repo root and client slug.**
   - Use `pwd -P` from the repo root. Store it: `REPO_ROOT="$(pwd -P)"`.
   - Ask whether this is for a specific client. If yes, pick a slug and set the service name
     accordingly, e.g. `CLIENT_KEY_SERVICE="client-openai-api-key-acme"`. Otherwise use the default
     `client-openai-api-key`.

2. **Confirm Keychain has the key without revealing it.**

   ```sh
   security find-generic-password -a "$USER" -s "$CLIENT_KEY_SERVICE" -w >/dev/null
   ```

   If missing, instruct the user to add it (they run this; do not run it for them):

   ```sh
   printf 'Client OpenAI API key (input hidden): '
   read -rs OPENAI_KEY; echo
   security add-generic-password -U -a "$USER" -s "$CLIENT_KEY_SERVICE" -w "$OPENAI_KEY"
   unset OPENAI_KEY
   ```

3. **Write the repo-local files.**

   `.envrc` at the repo root (if `CLIENT_KEY_SERVICE` is non-default, set it on the first line before
   the default assignment):

   ```sh
   CLIENT_KEY_SERVICE="${CLIENT_KEY_SERVICE:-client-openai-api-key}"

   if ! _key="$(security find-generic-password -a "$USER" -s "$CLIENT_KEY_SERVICE" -w 2>/dev/null)"; then
     log_error "Keychain service '$CLIENT_KEY_SERVICE' not found. Add the key with:"
     log_error "  security add-generic-password -U -a \"\$USER\" -s $CLIENT_KEY_SERVICE -w <KEY>"
     return 1 2>/dev/null || exit 1
   fi
   if [ -z "$_key" ]; then
     log_error "Keychain service '$CLIENT_KEY_SERVICE' holds an empty value."
     return 1 2>/dev/null || exit 1
   fi

   export OPENAI_API_KEY="$_key"
   unset _key

   export CODEX_HOME="$(pwd -P)/.codex-client"
   mkdir -p "$CODEX_HOME"
   ```

   `.codex-client/config.toml` — write it with a heredoc so the **real absolute path** (output of
   `pwd -P`) is substituted into the `[projects."..."]` key; never leave a literal placeholder. This
   form needs no `sed` and survives paths with `#`, `&`, or spaces:

   ```sh
   mkdir -p .codex-client
   cat > .codex-client/config.toml <<EOF
   model_provider = "openai-us"

   [model_providers.openai-us]
   name = "OpenAI (US)"
   base_url = "https://us.api.openai.com/v1"
   wire_api = "responses"
   env_key = "OPENAI_API_KEY"

   [projects."$(pwd -P)"]
   trust_level = "trusted"
   EOF
   ```

   `.codex-client/AGENTS.md`:

   ```md
   # Client OpenAI API Key Policy

   Use only the client-provided OpenAI API key for OpenAI-backed Codex or codex-plugin-cc work in this repository.

   - Resolve the key via `OPENAI_API_KEY`.
   - The local source of truth is the macOS Keychain service named by `CLIENT_KEY_SERVICE` (default `client-openai-api-key`).
   - `CODEX_HOME` must point to this repository's `.codex-client` directory.
   - Never paste, print, log, commit, or write the raw API key.
   - Use the OpenAI US endpoint `https://us.api.openai.com/v1`.
   - If `OPENAI_API_KEY` or the repo-scoped `CODEX_HOME` is missing, stop before running OpenAI-backed commands.
   ```

4. **Ensure `.codex-client/` and `.direnv/` are git-ignored.**

   ```sh
   printf '\n.codex-client/\n.direnv/\n' >> .gitignore
   ```

5. **Allow direnv.**

   ```sh
   direnv allow
   ```

## Verification

Run from the target repo root. Do not print the key.

```sh
direnv exec . zsh -c 'test -n "$OPENAI_API_KEY" && test "$CODEX_HOME" = "$(pwd -P)/.codex-client" && test -f "$CODEX_HOME/config.toml" && test -f "$CODEX_HOME/AGENTS.md" && echo "client codex setup ok"'
```

To confirm Codex authenticates with the **client key** (not a ChatGPT subscription), run `codex doctor`
from inside the repo and read the auth section:

```sh
codex doctor
```

Key-based (expected) shows `default model provider openai-us`, `provider auth env var OPENAI_API_KEY
(present)`, `provider name OpenAI (US)`, and `reachability mode provider auth`. A subscription instead
shows `stored auth mode chatgpt` / `reachability mode ChatGPT auth`.

For Codex CLI, run `codex`, then `/status`. Expected (base URL shown normalized):

```text
Model provider: OpenAI (US) - https://us.api.openai.com/v1
Agents.md: /path/to/your-repo/.codex-client/AGENTS.md
```

For Claude Code with `codex-plugin-cc`, launch Claude Code from the direnv-loaded repo shell, then run
`/codex:setup`. Output is similar to (exact wording is set by the plugin version):

```text
Status: ready
- codex: ... (Codex CLI detected)
- auth: OpenAI (US) is configured and does not require OpenAI authentication
```

Confirm `Status: ready` and that the `- auth:` line references OpenAI (US) / an API key, not ChatGPT.

## Audit

Check for accidental key material without revealing the real key.

```sh
# Files that should never contain a raw key:
rg -n 'sk-[A-Za-z0-9]' .envrc .codex-client 2>/dev/null
# If the repo is a git repo, also check the index (nothing tracked should match):
git grep -nI 'sk-[A-Za-z0-9]' 2>/dev/null
```

Expected: no hits. (A documentation placeholder such as a bare `sk-` prefix with no key body is fine.)

## Troubleshooting

- `codex-plugin-cc` shows ChatGPT auth instead of the API key: Claude Code was likely launched outside
  the direnv-loaded repo shell. `cd` to the repo, confirm `echo $CODEX_HOME` is set, run `direnv reload`,
  and relaunch Claude Code from that shell (a running Claude Code will not pick up env changes).
- `CODEX_HOME` is empty or wrong: run `direnv allow` in the repo root and reopen the shell. Confirm the
  `direnv hook` line is in `~/.zshrc`.
- `.envrc` reports the Keychain service was not found: the service name in `.envrc`
  (`CLIENT_KEY_SERVICE`) must match the one used in `security add-generic-password -s ...`.
- `Agents.md: <none>`: create `.codex-client/AGENTS.md` and restart Codex.
- Repo moved or renamed: the `[projects."..."]` trust path in `.codex-client/config.toml` is now stale.
  Re-run this skill (or the setup block) to regenerate the files with the new path.
- Project-local config warning: remove provider settings from the child `.codex/config.toml`; keep
  provider settings in `$CODEX_HOME/config.toml`.
