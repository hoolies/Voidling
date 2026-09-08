# Working with an AI assistant (token-efficient)

## Key fact

**Cloning repos to disk does not reduce tokens by itself.** Tokens are consumed when **text enters the model context** (tool reads, huge pastes, very broad `@` folder attachments).

## Efficient patterns

1. **Keep these `docs/` files updated** — short, stable summaries + **links** to upstream. In new chats, attach `@Voidling/docs/README.md` or the single file that matters.
2. **Clone upstream repos locally** — then ask for **specific paths** (“explain `…/Containerfile` only”) instead of pasting logs or whole trees.
3. **Avoid** “read the entire void-packages / fedora tree” in one request — use search and narrow files.
4. **Optional:** add a root **`AGENTS.md`** later (1–2 screens) with invariants and repo layout once the codebase exists.

## What to paste vs what to link

- **Paste:** error snippets, diffs you are working on, one focused config block.
- **Link:** handbooks, long GitHub threads, full manuals.

## Cursor habit

Use `@Voidling/docs/30-upstream-reading-map.md` when orientation is needed; use `@Voidling/docs/00-context-and-goals.md` when scope creep is a risk.
