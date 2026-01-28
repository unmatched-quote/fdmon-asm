# fdmon

File-descriptor monitor utility. I wanted something quick, here it is. Screenshot says more than words

![fdmon screenshot](fdmon.png)

## What it does

Shows open file descriptors per process, showing 32 processes with most file descriptors open.

## How it does it

Enumerates `/proc/*/fd/` every second - counts open FD's per process and renders them. Also shows system fd limits from `/proc/sys/fs/`. Useful for spotting fd leaks or resource-hungry processes at a glance (I'm looking at you JetBrains products).

## Install

Requires `nasm` and a GNU linker on x86_64 Linux:

```bash
sudo apt install nasm    # Debian/Ubuntu
sudo pacman -S nasm      # Arch
sudo dnf install nasm    # Fedora
```

## Build & run

```bash
make
./fdmon
```

## Keys

| Key | Action |
|-----|--------|
| `F` | Sort by FD count (default) |
| `P` | Sort by PID |
| `M` | Toggle memory column (RSS) |
| `Q` | Quit |

## System limits

The bottom of the display shows three values read from procfs:

- **Kernel handles** — allocated file handles across all processes, read from `/proc/sys/fs/file-nr` (first field). The number after `/` is the system-wide max from `/proc/sys/fs/file-max`.
- **Per-process max** — the hard ceiling on how many fds a single process can open, from `/proc/sys/fs/nr_open`.

To change the system-wide max:

```bash
sudo sysctl fs.file-max=2097152
```

To change the per-process ceiling:

```bash
sudo sysctl fs.nr_open=2097152
```

Note that `nr_open` is just the upper bound for `RLIMIT_NOFILE`. Individual processes are still limited by their ulimit, which you can check with `ulimit -n` and raise with `ulimit -n 1048576` or permanently in `/etc/security/limits.conf`.

## License

Public domain
