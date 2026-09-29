# Phase 22 — Payload Analysis GUI

Adds the first complete GUI path from a selected timeline range to raw-payload evidence:

1. Select range A on Live Dashboard.
2. Select range B.
3. Open Payload Analysis and choose `019A` or `222012`.
4. Analyze A vs B to see offset-by-offset differential bytes and activity ratio.
5. Inspect the byte-offset × sample heatmap.
6. Click an offset to restrict automatic field expansion to that byte (`u8/s8/u16/s16/u24/u32/s32/bit`, endian variants as applicable).

The view is derived from immutable `commands.raw_response`. It never rewrites raw capture and never assigns Honda-specific semantics to a changing byte. Field expansion is a candidate generator only; correlation and signal verification remain separate steps.
