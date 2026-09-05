# SCShell

> Embeddable Windows terminal component for Delphi applications

**Languages:** [한국어](README.md) | **English**

---

## Overview

**SCShell** is a full-featured Windows terminal component for embedding into Delphi applications. A Rust DLL hosts a real shell (cmd, PowerShell, pwsh, WSL, etc.) via ConPTY, with [alacritty_terminal](https://crates.io/crates/alacritty_terminal) providing battle-tested VT100/xterm handling. On the Delphi side, the `TSCRataShell` component (a `TWinControl` descendant) drops onto a form like any other VCL control.

## Features

- **Full ConPTY integration** — Windows 10 1903+ `CreatePseudoConsole` API
- **alacritty-powered VT processing** — alt screen, scrollback, SGR (incl. 24-bit truecolor), cursor save/restore, insert/delete, scroll regions, bracketed paste, and more
- **Complete Korean IME support** — composition window position auto-anchored, cell-aligned font matching, jamo decomposition / composition cancel work correctly
- **Standard `TWinControl` component** — Align, Anchors, Font, TabOrder, etc.
- **Automatic child process cleanup** — Job Object's `KILL_ON_JOB_CLOSE` flag prevents shell-tree leaks on host exit
- **Panic isolation** — `catch_unwind` at the FFI boundary keeps Rust panics from propagating into the host
- **Single-DLL deployment** — statically linked CRT, no transitive DLL dependencies
- **Both 32-bit and 64-bit** — one name, `sc_shell.dll`; the folder tells them apart (`bin/`, `bin/win32/`)

## Requirements

- **Rust** 1.80+ (to build the DLL)
- **Delphi** 13 (Studio 37.0)
- **Windows** 10 1903+ (stable ConPTY)

## Project Layout

```
SHELL/
├── docs/design/             # Design documents
├── rata_shell/              # Rust DLL crate
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── ffi.rs           # C ABI exports
│       ├── session.rs       # Session lifecycle
│       ├── pty/             # ConPTY + Job Object
│       ├── io.rs            # Reader/Writer threads
│       ├── term.rs          # alacritty Term wrapper
│       ├── render/          # Cell grid snapshot + diff
│       ├── keymap.rs        # Win32 VK → VT sequences
│       └── log.rs           # Direct file logger
├── delphi/
│   ├── src/
│   │   ├── SCShell.pas         # FFI bindings
│   │   ├── SCShell.Painter.pas # GDI painter
│   │   ├── SCShell.Ctrl.pas    # TSCRataShell component
│   │   └── SCShell.Reg.pas     # Design-time registration
│   └── packages/
│       ├── SCShell_RT.dpk      # Runtime package
│       └── SCShell_DT.dpk      # Design-time package
├── demo/
│   ├── DemoShell.dpr           # Demo EXE project
│   ├── DemoMain.pas
│   └── DemoMain.dfm
├── tools/
│   └── build.ps1               # Unified build script
└── bin/                        # Build outputs (.dll, .exe)
```

## Build

```powershell
# Full build (Rust DLL 32+64 + Delphi demo)
.\tools\build.ps1 -All

# Rust DLLs only (both architectures)
.\tools\build.ps1 -Rust

# Single architecture
.\tools\build.ps1 -Rust64
.\tools\build.ps1 -Rust32

# Delphi demo only
.\tools\build.ps1 -Delphi
```

Artifacts:
- `bin/sc_shell.dll` — Rust DLL (x86_64)
- `bin/win32/sc_shell.dll` — Rust DLL (i686, same name)
- `bin/DemoShell.exe` — Demo application

## Usage Example (Delphi)

```pascal
uses
  SCShell.Ctrl;

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FShell := TSCRataShell.Create(Self);
  FShell.Parent := Self;
  FShell.Align := alClient;
  FShell.ShellPath := 'C:\Windows\System32\cmd.exe';
  FShell.OnExit := HandleShellExit;
  FShell.Start;
end;

procedure TFormMain.HandleShellExit(Sender: TObject; AExitCode: Integer);
begin
  StatusBar.Caption := Format('Exited: %d', [AExitCode]);
end;
```

## Key Properties / Methods

| Member | Description |
|--------|-------------|
| `ShellPath: string` | Shell executable path |
| `ShellArgs: string` | Shell arguments |
| `WorkingDir: string` | Working directory for the child |
| `Environment: TStrings` | Environment entries (`KEY=VALUE`) |
| `AutoStart: Boolean` | Auto-start on `Loaded` |
| `ScrollbackLines: Integer` | Scrollback line count (default 10000) |
| `Start` | Spawn the shell |
| `Stop(timeout)` | Terminate the shell |
| `Restart` | Stop + Start |
| `SendText(text)` | Send UTF-16 text (transcoded to UTF-8) to the PTY |
| `OnExit` | Child process exit event |
| `OnTitleChange` | Title (`OSC 0/2`) change event |
| `OnBell` | BEL received |

## Architecture

```
+----------------------------------------------------+
|                Delphi Host Process                  |
|  +---------------+    +----------------------+     |
|  | TSCRataShell  |---→| SCShell.pas (FFI)    |     |
|  | (TWinControl) |←---| Dynamic DLL bindings |     |
|  +---------------+    +----------▲-----------+     |
|                                  | C ABI           |
+----------------------------------|-----------------+
                                   ▼
+----------------------------------------------------+
|              sc_shell.dll (Rust)                   |
|  +-------+   +---------+   +----------+            |
|  | FFI   |←→ | Session |←→ | TermHost |            |
|  +-------+   +----┬────+   +----┬─────+            |
|                   ▼              ▼                  |
|              +-------+   +-----------------+        |
|              |  PTY  |   | alacritty Term  |        |
|              +---┬---+   |  + Processor    |        |
|                  |       +-----------------+        |
+------------------|---------------------------------+
                   ▼
            +-------------+
            | ConPTY API  |
            +------┬------+
                   ▼
          +-----------------+
          |  cmd / pwsh /   |
          |   wsl / ...     |
          +-----------------+
```

## License

MIT — complies with dependency licenses (`alacritty_terminal`: MIT, etc.)
