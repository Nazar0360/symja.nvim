# Symja.nvim

A Neovim integration for [Symja](https://github.com/axkr/symja_android_library), with a persistent Java evaluator, native Symja and Mathematica-compatible syntax, parser diagnostics, symbol completion, LSP hover documentation, and optional LaTeX image output.

The plugin targets Symja **3.1.1**. Its Mathematica-compatible parser is not the complete Wolfram Language, so some Wolfram Language features may not be supported.

## Disclaimer

This project is written **ENTIRELY** by AI including all but this section of the `README.md`, so I deserve no credit for this.

I wanted to find a convenient way (and by that I mean having code highlighting, completion, documentation, and execution) to write and edit Mathematica or Mathematica-like code but the only thing I found is [CalcES](https://play.google.com/store/apps/details?id=advanced.scientific.calculator.calc991.plus) which does include Symja, and is genuinely really good but it's, well, an Android app. Writing it myself would've taken me way too much time and effort, considering that I have no experience with any of this, just for me to use it, like, once for a dumb idea. It's scary how little effort was required from me to guide the AI, considering that I wasn't even using the payed version. I was only testing the plugin and telling the machine what I wanted it to have and each time it worked in a first couple of tries. Future is looking grim indeed.

Feel free to do (or not do) whatever you want with this. You can also contribute, but since I had written none of this, I'm not sure that I would be able to maintain it myself. Forking it might be a better idea.

## Features

- Persistent evaluator: definitions and variables are shared across files, syntax modes, and the REPL.
- `.symja` files use native/relaxed Symja syntax; `.mma`, `.wl`, and `.wls` use Mathematica-compatible syntax.
- `:SymjaRun` and `:SymjaEval` evaluate source as text. Their `Latex` variants render evaluated results to an image.
- Interactive REPL with `:SymjaReplExit`, `Ctrl-D`, and `:q` exit support. Closing the REPL does not stop the shared evaluator.
- Syntax diagnostics from Symja's parser, without evaluating code or changing evaluator state.
- Optional `nvim-cmp` source for built-in and user-defined symbols.
- Hover documentation through a small LSP server. Existing `vim.lsp.buf.hover()` mappings continue to work; this plugin does not define a `K` mapping.
- Optional integrations for Comment.nvim, vim-closer, and `3rd/image.nvim`.

## Requirements

- Neovim **0.10 or newer**.
- Java **17 or newer** at runtime.
- A Java **17+ JDK** to build the bridge (a Java 17+ runtime is sufficient after building).
- Maven **3.8 or newer** to resolve the bridge's support libraries and, by default, the Symja dependency.
- Internet access on the first Maven build.

The project compiles for Java 17 bytecode. By default, Maven resolves `org.matheclipse:matheclipse-core:3.1.1` and the bridge's Jackson/Log4j libraries. You can instead build against an extracted local Symja application bundle; see below.

### Choosing a Symja version or source

The default build uses `org.matheclipse:matheclipse-core:3.1.1` from Maven Central. The build entry point is `./backend/build.sh`.

To select another Maven release, set the environment variable before starting Neovim:

```bash
export SYMJA_VERSION=3.2.0
nvim
```

To use a different Maven repository or coordinates, set `SYMJA_REPOSITORY_URL`, `SYMJA_GROUP_ID`, or `SYMJA_ARTIFACT_ID` in the same way. For example:

```bash
export SYMJA_VERSION=3.2.0
export SYMJA_REPOSITORY_URL=https://repo.example.com/releases
nvim
```

Maven repository credentials belong in `~/.m2/settings.xml` under the server ID `custom-symja-repository`. `SYMJA_REPOSITORY_URL` is a Maven artifact repository URL, not a Git checkout.

#### Use a locally downloaded Symja application bundle

You can use the standalone application bundle published alongside Symja releases instead of resolving the Symja library from Maven. For example, download the matching [Symja 3.1.1 apps bundle](https://github.com/axkr/symja_android_library/releases/tag/v3.1.1-apps), extract it, and point `SYMJA_HOME` to the extracted directory. The bundle root must contain a `lib/` directory with the Symja and dependency JARs.

```bash
export SYMJA_HOME="$HOME/opt/symja-3.1.1"
nvim
```

`./backend/build.sh` detects `SYMJA_HOME`, compiles the bridge against every JAR in `$SYMJA_HOME/lib/`, and asks Maven to fetch only the bridge's Jackson/Log4j support libraries (so Maven and network access are still needed for those support libraries). It records the local library path in the build output, so the runtime uses that same Symja distribution automatically. You do not need to set `symja_home` again in Lua unless you want to override the recorded path.

If the JARs are not under a `lib/` subdirectory, set `SYMJA_LIB_DIR` to the directory that contains them instead:

```bash
export SYMJA_LIB_DIR="$HOME/opt/symja-libs"
nvim
```

`SYMJA_HOME` and `SYMJA_LIB_DIR` are build-time and runtime environment variables. You can also configure the paths explicitly:

```lua
symja.setup({
  symja_home = vim.fn.expand("~/opt/symja-3.1.1"),
  -- Or use symja_lib_dir = "/absolute/path/to/lib".
  symja_version = "3.1.1", -- documentation version; keep it aligned with the local bundle
})
```

The configured version controls documentation lookup; the actual evaluator version is determined by the local bundle you build against. Use a matching documentation version. Local-bundle mode and `SYMJA_REPOSITORY_URL` are mutually exclusive.

For an externally built bridge, `symja.setup()` also accepts `bridge_jar` and `bridge_lib_dir`; these refer to the symja.nvim bridge JAR and its Jackson/Log4j runtime dependency directory, not to Symja's standalone application bundle. `java` can select a non-default Java executable.

## Installation with lazy.nvim

```lua
return {
  {
    "Nazar0360/symja.nvim",
    name = "symja.nvim",
    lazy = false,
    build = "./backend/build.sh",
    config = function()
      local symja = require("symja")
      symja.setup({
        symja_version = vim.env.SYMJA_VERSION or "3.1.1",
        symja_home = vim.env.SYMJA_HOME,
        symja_lib_dir = vim.env.SYMJA_LIB_DIR,
      })
      if pcall(require, "cmp") then
        symja.register_cmp()
      end
    end,
  },
}
```

The build script selects Maven mode or local-bundle mode from the environment variables described above.

## Syntax modes

| Extension | Neovim filetype | Syntax sent to Symja |
|---|---|---|
| `.symja` | `symja` | Native / relaxed syntax, e.g. `f(x)` |
| `.mma`, `.wl`, `.wls` | `symja_mma` | Mathematica-compatible syntax, e.g. `f[x]` |

Example native file:

```mathematica
(* Native Symja syntax *)
a = 10;
square(x_) := x^2;
square(a + 2)
```

Equivalent Mathematica-compatible file:

```mathematica
(* Mathematica-compatible syntax *)
a = 10;
square[x_] := x^2;
square[a + 2]
```

Both evaluate to `144` on the final expression. The syntax mode belongs to each request, not to the Java process, so buffers using both modes can share the same evaluator state.

Use `:SymjaMode native` or `:SymjaMode mma` to change the current buffer's mode. `wolfram` and `mathematica` are accepted aliases for `mma`.

## Commands

| Command | Purpose |
|---|---|
| `:SymjaRun` | Evaluate the current buffer and show text output. |
| `:SymjaEval` | Evaluate the current line, visual selection, or supplied expression. |
| `:SymjaRunLatex` | Evaluate the current buffer and render the result as LaTeX. |
| `:SymjaEvalLatex` | Evaluate a line, selection, or supplied expression and render LaTeX. |
| `:SymjaRepl [native\|mma]` | Open the persistent interactive REPL. |
| `:SymjaReplExit` | Close and wipe the REPL buffer; keep evaluator state. |
| `:SymjaReset` | Reset the shared evaluator and clear definitions/variables. |
| `:SymjaPing` | Check that the Java bridge responds. |
| `:SymjaMode [native\|mma]` | Show or change the current buffer's syntax mode. |
| `:SymjaCheck` | Run a syntax check immediately. |
| `:SymjaCheckToggle` | Toggle automatic syntax checking. |
| `:SymjaDoc [symbol]` | Open the original Symja Markdown reference for a symbol. |
| `:SymjaLspInfo` | Show LSP attachment and hover capability information. |
| `:SymjaBridgeInfo` | Show bridge process and runtime paths. |
| `:SymjaBridgeError` | Open the detailed Java bridge error report. |
| `:SymjaLatexError` | Open the latest LaTeX renderer error report. |

The REPL accepts input on its last line. Press `Enter` to evaluate it. Exit it with `:SymjaReplExit`, `Ctrl-D` in Normal mode, `Ctrl-D` on an empty Insert-mode prompt, or `:q`. These actions close the REPL interface only; the Java evaluator remains alive so definitions are still available to normal buffers.

## Default mappings

The plugin adds buffer-local mappings only when the mapping is not already defined:

- `<leader>rr` — run the buffer and show text.
- `<leader>rl` — run the buffer and render LaTeX.
- Visual `<leader>r` — evaluate the selection as text.
- Visual `<leader>rl` — evaluate the selection and render LaTeX.
- `<leader>ri` — open the REPL.
- `<leader>rd` — open documentation for the symbol under the cursor.
- `<leader>rc` — check syntax in the current buffer.

Disable plugin mappings with:

```lua
require("symja").setup({ keymaps = false })
```

The plugin does not install or change a `K` mapping. Use your existing `vim.lsp.buf.hover()` mapping for documentation popups.

## Syntax diagnostics

Syntax checking uses Symja's parser through the persistent Java bridge. It does not evaluate the buffer or modify variables/definitions. `.symja` uses Symja's relaxed parser; Mathematica-compatible filetypes use its MMA parser. Diagnostics are published through Neovim's `vim.diagnostic` API.

Automatic checks run after edits with a default 500 ms debounce and on save. This is parser-level checking, not semantic analysis: it does not report undefined variables, unsupported functions, type errors, or expressions that parse successfully but fail during evaluation. An incomplete expression can be reported while it is still being typed.

Configuration example:

```lua
require("symja").setup({
  syntax_check = true,
  syntax_check_debounce_ms = 500,
})
```

## nvim-cmp completion

The included `lua/cmp_symja.lua` source provides built-in Symja symbols and names defined during the current evaluator session. Selecting a completion item loads its original Symja Markdown reference into nvim-cmp's documentation window when a reference page exists.

There is no hard dependency on nvim-cmp. The provided Lazy spec attempts to load it and registers the source only when it is installed. For a different setup, register it with:

```lua
require("symja").register_cmp()
```

Or see [`contrib/nvim-cmp.lua`](contrib/nvim-cmp.lua).

## LSP hover and documentation

The plugin starts a small LSP server for `.symja`, `.mma`, `.wl`, and `.wls` buffers. It implements `textDocument/hover` and returns Symja's original function-reference Markdown. It does not provide LSP completion or diagnostics; those are handled separately by the plugin's completion source and parser checker.

Documentation lookup checks a configured local `docs_dir`, then supported local Symja source/bundle layouts, then the documentation for the configured `symja_version` online. The plugin does not generate or rewrite documentation. The default raw documentation URL uses the upstream `v<symja_version>` tag. `curl` is preferred when available so configured proxy and CA settings are respected; Java's HTTP client is used as a fallback.

Set `docs_dir` or `docs_raw_base_url` in `require("symja").setup({...})` to customize documentation lookup. Set `lsp = false` to disable the LSP client. Some built-in symbols do not have an upstream reference page and therefore have no hover result. Run `:SymjaLspInfo` in a Symja buffer to check the attachment.

## Optional integrations

### LaTeX images in Kitty

`:SymjaRunLatex` and `:SymjaEvalLatex` evaluate expressions first, convert the evaluated result with Symja's `TeXUtilities`, compile the TeX to a transparent PNG, and display it with `3rd/image.nvim` using Kitty's graphics protocol. Long expressions are split across multiple display-math lines using the LaTeX `breqn` package. Normal text evaluation skips TeX conversion and image generation.

This integration is optional. It requires:

- Kitty with its graphics protocol enabled.
- [`3rd/image.nvim`](https://github.com/3rd/image.nvim) version 1.4.0 or newer.
- `pdflatex`, `pdftocairo`, and ImageMagick's `magick` command.

On Arch Linux:

```bash
sudo pacman -S texlive-latexextra poppler imagemagick
```

Add the following as a separate Lazy spec, or merge the options into your existing `image.nvim` spec. Do not declare it as a hard dependency of Symja.nvim:

```lua
{
  "3rd/image.nvim",
  build = false,
  opts = {
    backend = "kitty",
    processor = "magick_cli",
    integrations = {
      markdown = { enabled = false },
      asciidoc = { enabled = false },
      typst = { enabled = false },
      neorg = { enabled = false },
      syslang = { enabled = false },
      html = { enabled = false },
      css = { enabled = false },
      org = { enabled = false },
    },
  },
}
```

Image rendering can be disabled with `require("symja").setup({ latex = false })`. The default rasterization resolution is 240 DPI; configure `latex_dpi` in the range 96–600. `latex_cell_width_px` controls the estimated terminal cell width used when wrapping long formulas. On failure, run `:SymjaLatexError` to inspect the retained `.tex` source and LaTeX log; the report prints their diagnostic directory. Set `vim.g.symja_debug = true` to show additional diagnostics.

### Comment.nvim

Symja buffers use the Wolfram comment delimiters `(* ... *)`. If Comment.nvim is installed, the plugin registers the `symja` and `symja_mma` filetypes and handles an existing `pre_hook` without changing its behavior for other filetypes. No Symja Tree-sitter parser is required.

```lua
{ "numToStr/Comment.nvim", opts = {} }
```

### vim-closer

The provided `after/ftplugin/` files set `b:closer_flags` to `([{` for both Symja filetypes, enabling vim-closer's existing bracket expansion for `(`, `[`, and `{`. It does not add a competing Enter mapping. Semicolons are intentionally excluded because they separate expressions in Mathematica syntax.

These integrations are optional. Symja.nvim does not require Comment.nvim, vim-closer, Tree-sitter, nvim-cmp, or image.nvim to evaluate expressions.

## Manual installation (without lazy.nvim)

The repository includes an optional `install.sh` for users who do not use lazy.nvim. It also installs the `after/ftplugin` integration files:

```bash
./install.sh
```

It copies the plugin files into Neovim's config/data directories and builds the Java backend. Do not use this installer together with the Lazy.nvim route; choose one installation method.

The installer accepts the same environment overrides as `./backend/build.sh`: `SYMJA_VERSION`, `SYMJA_GROUP_ID`, `SYMJA_ARTIFACT_ID`, `SYMJA_REPOSITORY_URL`, `SYMJA_HOME`, and `SYMJA_LIB_DIR`. For example:

```bash
SYMJA_HOME="$HOME/opt/symja-3.1.1" ./install.sh
```

When using a non-default release, set the matching `symja_version` in `symja.setup()` so documentation lookup follows that version.

## Development and tests

Build the Java bridge from the repository root (Maven dependency mode or local bundle mode depending on the environment):

```bash
./backend/build.sh
```

Run the backend smoke tests:

```bash
./tests/smoke.sh
./tests/lsp-smoke.sh
```

The evaluator smoke test covers both syntax modes, shared state, reset, completion, syntax checking, and LaTeX conversion. The LSP test checks hover documentation and verifies that local Markdown takes precedence over network fallback. `./tests/latex-render-smoke.sh` additionally checks formula wrapping and the renderer's DPI validation; it requires TeX Live, Poppler, and ImageMagick to be installed.

GitHub Actions runs the Java build and the evaluator/LSP smoke tests on pushes and pull requests.

## Troubleshooting

- **Bridge JAR missing:** run `:Lazy build symja.nvim` or `:Lazy sync`; confirm `backend/target/symja-nvim.jar` and `backend/target/lib/` exist inside the plugin directory.
- **Local Symja classes missing at runtime:** confirm `SYMJA_HOME` still points to the extracted bundle and that its `lib/` directory contains JARs. Run `:SymjaBridgeInfo` to see the local library path. Rebuild with `SYMJA_HOME=/path/to/symja ./backend/build.sh` if the bundle was moved.
- **Java not found:** install a Java 17+ runtime and ensure `java` is on `PATH`.
- **Maven build fails:** confirm Maven is installed and that Maven Central is reachable; retry `:Lazy build symja.nvim` after resolving network/build errors.
- **Bridge exits unexpectedly:** run `:SymjaBridgeError` for the captured Java exception and stderr report; `:SymjaBridgeInfo` shows the process and classpath details.
- **LaTeX output is unavailable:** check the optional image.nvim/Kitty setup and confirm `pdflatex`, `pdftocairo`, and `magick` are executable. Run `:SymjaLatexError` for the compiler report.

For additional diagnostics, set `vim.g.symja_debug = true` before the plugin loads.

## License

Symja.nvim's integration code is released under the [MIT License](LICENSE). Symja and its transitive dependencies are separate upstream projects and remain under their respective licenses.
