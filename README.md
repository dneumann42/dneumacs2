# Emacs configuration

A GNU Emacs 30 configuration, organised as a set of modules under `lisp/`.

## Layout

```
early-init.el     Startup policy: GC tuning, frame parameters
init.el           Loads the modules below, in dependency order
lisp/             The modules
themes/           Local themes, including the generated Wallust palette
snippets/         YASnippet templates
lsp-servers/      Language servers downloaded on demand (untracked)
```

Every module is named `init-*.el`, so none of them can shadow a built-in
or third-party library, and each provides the feature matching its file
name. `init.el` lists them in load order and nothing else.

| Module | What it owns |
| --- | --- |
| `init-lib` | Shared helpers: file writes, PATH, project roots, popups |
| `init-persist` | Variable state restored early at startup |
| `init-packages` | Package archives and the `use-package` bootstrap |
| `init-keys` | Every key sequence bound to a command defined here |
| `init-pulldown` | Themed, buffer-based replacements for the native menus |
| `init-toolbar` | Header-line toolbar API, and the global toolbar bar |
| `init-theme` | Font installation and discovery, theme selection |
| `init-frame` | Frame chrome, transparency, menu bar, mode line |
| `init-editor` | Editing defaults and general-purpose packages |
| `init-completion` | Vertico, Corfu, Consult, Embark, YASnippet, which-key |
| `init-bookmarks` | Visible per-file bookmarks (bm) |
| `init-compile` | The run/build panel and per-project commands |
| `init-projects` | Projectile, Magit, search, the project panel, sessions |
| `init-treemacs` | The file tree |
| `init-docs` | PDF, EWW and Markdown |
| `init-org-sync` | Git synchronisation of the Org repository |
| `init-org` | Org mode |
| `init-ide` | Language servers and the shared IDE command layer |
| `init-lang-eglot` | C/C++, Lua, Rust, OCaml, Python, Ruby, RON |
| `init-lang-jvm` | Kotlin and Java, their servers and Gradle |
| `init-lang-lisp` | Emacs Lisp, Scheme (Geiser), Common Lisp (SLY) |
| `init-lang-nim` | Nim, including the documentation browser |
| `init-lang-dsl` | The Owl and Nest major modes |
| `init-cheatsheet` | The cheatsheet framework and the guides themselves |

## Conventions

- **Symbols** defined here are prefixed `init/`, except the self-contained
  libraries that carry their own namespace (`pulldown-menu-`,
  `cheatsheet-`) and the major modes (`owl-`, `nest-`).
- **Keys** for commands defined here are named as `bind/…` constants in
  `init-keys.el`, so the whole keymap can be read and rebound in one
  place. Keys for third-party commands stay in the `use-package` `:bind`
  form of the package that owns them.
- **Comments** explain why, not what. A comment that restates the code it
  sits above does not belong here.
- **Docstrings** are mandatory, on every function, variable, face and
  custom option.

## The IDE layer

Each IDE concept — run, test, hover, format, go to definition — is one
command bound once in `init/ide-mode-map` (see `init-ide.el`). Running it
calls the buffer-local `init/ide-NAME-function` when the language module
set one, otherwise a shared default, usually Eglot.

So <kbd>M-RET</kbd> always means "code actions" and <kbd>f5</kbd> always
means "run", whatever the language, and a language module only has to
declare where it differs. `C-c g` opens the cheatsheets, which look their
key sequences up live and therefore cannot go stale.

Most languages name a server in `init-ide.el` and are done. Kotlin and
Java are the exception (`init-lang-jvm.el`): their servers are downloaded
on first use rather than assumed installed, and each server is rooted at
the *build* a file belongs to — the nearest `settings.gradle.kts` — so a
component of a Gradle composite build is indexed on its own instead of
dragging in the umbrella above it. That root is applied through a
buffer-local `project-find-functions` entry, so nothing else changes how
projects resolve.

## Startup and shutdown

Opening and closing are treated as a budget. Three rules keep them quick,
and each is implemented in the module that owns the feature.

**A session records what was on screen, nothing else** (`init-projects`).
Restoring a file buffer runs its major mode, tree-sitter, the fringe and
colour overlays, a Git diff, and for code a language server, so the cost
is roughly linear in buffers restored. Sessions therefore persist the
buffers displayed in a window — plus `*scratch*` — and skip remote files
and anything above `init/session-max-file-size`, either of which can stall
startup on its own. Everything not restored is still a keypress away
through `recentf` and `consult-buffer`. Set
`easysession-buffer-list-function` to `buffer-list` to go back to
persisting every live buffer. The session load reports its buffer count
and elapsed time in the echo area, so a slow startup can be attributed
rather than guessed at.

**State files are written with `prin1`, not `pp`** (`init-lib`). Saved
places and bm's bookmark repository both pretty-print their whole data
structure on the way out, which has poor algorithmic complexity and lands
squarely in the shutdown path. They are read back with `read`, so
`init/write-state-file-fast` drops the reindentation as `:around` advice
and the data is unchanged.

**Nothing stats the world at either end** (`init-editor`). Saved places no
longer check every recorded file for readability before writing, `recentf`
prunes its list on an idle timer rather than while the mode is starting,
and `confirm-kill-processes` is off — with a project open there is always a
language server alive, so that prompt fired on every exit without ever
saying anything useful. Unsaved buffers are still prompted for.

## Discovering it from inside Emacs

| Key | |
| --- | --- |
| `C-c g` | Open a cheatsheet |
| `C-c T` | Toggle the global toolbar |
| `C-c M` | Show or hide the menu bar |
| `<f10>` | Open the menus from the keyboard |
| `C-c r` | Reload the whole configuration |
