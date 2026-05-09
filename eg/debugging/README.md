# Debugging Examples

This directory contains standalone scripts that demonstrate and inspect
Brocken's debug information systems.

## Prerequisites

All scripts assume you've run `perl brocken.pl --debug=2` first to
generate `brocken_out.exe` (Windows) or `brocken_out` (Linux).

## Scripts

### `dump_eh_frame.pl`

Reads a binary (ELF or PE) and dumps the `.eh_frame` section contents:
CIE version, augmentation, FDE encoding, and per-function FDE entries
with PC-relative addresses.

```bash
perl eg/debugging/dump_eh_frame.pl brocken_out
```

### `dump_pdata.pl`

Reads a PE executable and dumps the SEH `.pdata` / `.xdata` tables:
all `RUNTIME_FUNCTION` entries and the shared `UNWIND_INFO`.

```bash
perl eg/debugging/dump_pdata.pl brocken_out.exe
```

### `simple_dwarf.pl`

Demonstrates building DWARF debug sections programmatically using
`Brocken::Format::DWARF` without running the full compiler pipeline.

```bash
perl eg/debugging/simple_dwarf.pl
```

## Notes

- ELF binaries are the primary target for `.eh_frame` inspection
- PE binaries use SEH (`.pdata`/`.xdata`) for unwind, not `.eh_frame`
- The DWARF dumper will show `.debug_frame` in both formats
