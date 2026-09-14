# uiFDMA external dependency

`uiFDMA.v` is intentionally excluded from this repository and is not licensed or redistributed by the XingShu project.

## Integration policy

- Production synthesis must obtain `uiFDMA.v` from an authorized external source.
- The file must remain outside the Git working tree.
- Set `UIFDMA_ROOT` to the directory containing the external source.
- Simulation may use a testbench-only behavioral model under `tb/models/`.
- The behavioral model must never be included in a synthesis file list.
- CI must remain usable without the external implementation.

Example on Windows:

```powershell
$env:UIFDMA_ROOT = 'D:\path\to\uiFDMA'
```

A future adapter will live at `rtl/vendor/xilinx/ui_fdma_adapter.sv`. The Pango competition target will use an HMIC-facing adapter rather than depending on the Xilinx-specific external module.