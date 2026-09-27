# pathology plugin

Whole-slide-image Stage-A/B tooling for the chordoma protocol, migrated from
the hardcoded wrapper
`crates/node-bundles/nodes-io/src/pathology_container.rs` to a manifest
plugin. One image, seven `[[nodes]]` entries, one runner
(`pathology_runner.py`) whose subcommands read their knobs from a single
`PATHOLOGY_*_SETTINGS` JSON environment variable.

## Layout

```text
pathology/
├── manifest.toml            # family image + the seven node contracts
├── scripts/
│   └── ihc_quant.sh         # the one variant whose wrapper injected logic
├── Dockerfile               # CPU image (built and smoke-tested locally)
├── Dockerfile.cuda          # CUDA image for production GPU hosts
├── pathology_runner.py      # baked runner (argv subcommands)
└── test_pathology_smoke.sh  # synthetic-slide end-to-end run of all commands
```

## Variant map

| Kind (manifest) | Legacy kind (wrapper) | Runner subcommand | Inputs | Outputs | Timeout | GPU |
| --- | --- | --- | --- | --- | --- | --- |
| `pathology_wsi_ingest` | `pathology_wsi_ingest_container` | `wsi-ingest` | 0: WSI | thumbnail.png, slide_meta.json | 3600 | no |
| `pathology_wsi_qc` | `pathology_wsi_qc_container` | `wsi-qc` | 0: WSI | tile_qc.parquet, qc_summary.json | 3600 | no |
| `pathology_patch_sample` | `pathology_patch_sample_container` | `patch-sample` | 0: WSI | patches.parquet, tissue_mask.png, patch_meta.json | 3600 | no |
| `pathology_wsi_embed` | `pathology_wsi_embed_container` | `wsi-embed` | 0: WSI, 1: patch table, 2: model bundle | embeddings.h5, embed_meta.json | 7200 | yes (`gpus = "all"`) |
| `pathology_domain_check` | `pathology_domain_check_container` | `domain-check` | 0: reference h5, 1: comparison h5 | domain_metrics.parquet, domain_meta.json | 3600 | no |
| `pathology_ihc_quant` | `pathology_ihc_quant_container` | `ihc-quant` | 0: WSI, 1: ROI mask image | tile_ihc.parquet, ihc_summary.json | 3600 | no |
| `pathology_qupath_import` | `pathology_qupath_import_container` | `qupath-import` | 0: label mask, 1: reference WSI | annotations.geojson, geojson_meta.json | 3600 | no |

Paths follow the standard container contract (`AUTONOMICS_INPUT{n}`,
`AUTONOMICS_OUTPUT{n}`). Patch coordinates are level-0 top-left pixels with
`read_region` semantics; the same seed always yields the same patch set on
the same slide.

## Image variants and GPU notes

- `Dockerfile` — CPU variant (torch 2.3.1 CPU wheel on the digest-pinned
  python:3.11.11-slim base). Built and smoke-tested locally; the published
  digest in `manifest.toml` (`cpu-r1`) is this image.
- `Dockerfile.cuda` — CUDA variant (`pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime`
  base) for production GPU hosts. Rootless Podman needs the
  nvidia-container-toolkit CDI spec (`nvidia-ctk cdi generate`). Both
  variants share `pathology_runner.py` and the same runner contract.

Only `pathology_wsi_embed` requests GPUs: `[nodes.resources] gpus = "all"`.
The legacy wrapper made GPU passthrough a spec param (`gpus`, default
`"all"`, `null` to opt out on hosts without the CDI spec); the plugin DSL
pins resources per kind, so the request is static. `device` remains a
parameter (`auto`/`cpu`/`cuda`) and still governs torch-side execution, so
the node keeps working on CPU-only hosts wherever the runtime can satisfy
the container request; the `gpus: null` escape hatch is gone — hosts that
cannot honor `--gpus all` must run the CPU image under a runtime profile
that ignores the request, or use a manifest without the resources entry.

## Settings-JSON mapping (parity notes)

The legacy wrapper serialized each Spec struct (minus `artifact_prefix` and
`timeout_secs`) into one `PATHOLOGY_*_SETTINGS` env value with compact
`serde_json`, and the runner parses it with `json.loads` + per-key
defaults. The plugin keeps that contract, not a flat-flag redesign:

- **Six of seven nodes** rebuild the exact same compact JSON through an env
  template (`PATHOLOGY_WSI_SETTINGS = '{"max_thumbnail_width":{{ ... }}}'`).
  With manifest defaults the compiled env value is **byte-identical** to the
  legacy one (same key order as the struct, same serde_json number
  spelling — float defaults are written `16.0` in TOML so they render as
  `16.0`, not `16`). With submitted values the runner sees the same numbers
  after `json.loads`; only non-canonical spellings of submitted JSON (e.g.
  `16` instead of `16.0` for a float field) survive verbatim instead of
  being renormalized by serde.
- **`pathology_wsi_embed`** keeps `"gpus":"all"` inside the blob (hardcoded
  to match `[nodes.resources].gpus`) for byte parity; the runner reads only
  `batch_size`, `device`, and `amp` and ignores the key.
- **`pathology_ihc_quant`** is the one node whose wrapper injected logic, so
  it gets a script (`scripts/ihc_quant.sh`). Its `roi_label` is a true
  optional (`Option<u32>`, no default): the legacy serializer emitted
  `"roi_label":null` when omitted, which the runner cannot parse
  (`int(None)`); the script omits the key instead, so the runner's own
  smallest-label default finally engages. Deliberate semantic fix over
  byte parity; with `roi_label` submitted the assembled blob is
  byte-identical to the legacy value.
- **`label_names`** (qupath-import) has no object param type in the v0 DSL,
  so it is a `string` param whose value is a JSON object literal, embedded
  verbatim into the blob. Submit it compact (`{"1":"Tumor"}`) for byte
  parity; any valid JSON object parses identically.

### Validation deltas

Per-param bounds from the wrapper's `validate` functions now live in the
manifest (`min`/`max`/`exclusive_min`/`exclusive_max`), checked at compile
time. Cross-field checks the v0 DSL cannot express moved to (or stay with)
the runner: `dab_weak < dab_strong` is enforced in-container; the
`value_floor < value_ceiling` check for wsi-qc/patch-sample has no runner
equivalent and is lost (degenerate inputs produce an all-background mask
rather than a spec error); `device` is no longer enum-validated at compile
time (the runner fails on an unsupported torch device). Legacy per-field
validation of the artifact prefix and timeout is subsumed by manifest
validation.

### Other parity notes

- Kinds drop the legacy `_container` suffix; DAG specs referencing the old
  kinds must be regenerated.
- The legacy node sorted its inputs by port index before execution
  (0=WSI, 1=table/mask, 2=weights, independent of edge insertion order);
  manifest factories do not reorder, so wire input ports in order.
- Input ports compile as `file` (the v0 port vocabulary); the legacy
  `Any`/`FileSet` port types narrow accordingly, and output ports gain
  labels derived from the output file names where the wrapper had none.
- Network stays `isolated`, rootfs read-only, pull policy `missing` — the
  hardened defaults, exactly as the wrapper pinned them.

## Model weights are never downloaded

`wsi-embed` takes the model as input port 2: an optional `model_config.json`
(`{"arch": ..., "img_size": ..., "timm_kwargs": {...}}`) plus exactly one
`.pth`/`.pt`/`.safetensors` checkpoint. The default config targets UNI-style
`vit_large_patch16_224` with `init_values=1e-5`.

UNI (and other foundation-model checkpoints like CONCH, Virchow, GigaPath)
are **license-gated on Hugging Face under research-only terms**. The runner
contains no download path by design. The operator must:

1. accept the model license on the Hugging Face model page,
2. download the checkpoint with an authenticated account,
3. stage it into the DAG as an input file set (or a catalog panel).

Every embedding h5 records the checkpoint sha256 in its attributes and in
`embed_meta.json`, so provenance survives the license boundary.

## Local build and smoke test

```bash
podman build -t localhost/pathology:cpu -f Dockerfile .
./test_pathology_smoke.sh   # synthetic-slide end-to-end run of all commands
```

The smoke test generates a synthetic pyramid TIFF with tissue-like blobs,
then exercises all seven commands on the CPU image. For `wsi-embed` it uses
a tiny random-weight `vit_tiny_patch16_224` checkpoint so no gated download
is needed; the production UNI checkpoint follows the staging flow above.

## Publish

```bash
podman tag localhost/pathology:cpu ghcr.io/auto-nomics/autonomics/pathology:<tag>
podman push ghcr.io/auto-nomics/autonomics/pathology:<tag>
# then update image.reference in manifest.toml with the post-push manifest
# digest and bump the tag line:
#
# Current digest: sha256:a0edcb6cca25f009f669723406207651284960425f7255891be5b91b29b63f2f (cpu-r1)
```

Publish the plugin itself per `docs/plugin-node-migration.md` Step 3: git
repository, `rev` pinned to a commit SHA in `plugins.toml`.
