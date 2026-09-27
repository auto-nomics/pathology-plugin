set -eu

# Assembles the PATHOLOGY_IHC_SETTINGS JSON blob the baked runner reads from
# the flat env channel declared in the manifest. roi_label is optional: when
# the operator omits it, the key is left out entirely so the runner falls
# back to the smallest mask label. (The legacy Rust wrapper serialized the
# absent Option as JSON null, which the runner cannot parse -- int(None) --
# so this key-omit form is the semantic the runner always intended.)
SETTINGS="{"
if [ -n "$PATHOLOGY_IHC_ROI_LABEL" ]; then
  SETTINGS="${SETTINGS}\"roi_label\":${PATHOLOGY_IHC_ROI_LABEL},"
fi
SETTINGS="${SETTINGS}\"mask_downsample\":${PATHOLOGY_IHC_MASK_DOWNSAMPLE}"
SETTINGS="${SETTINGS},\"dab_weak_threshold\":${PATHOLOGY_IHC_DAB_WEAK_THRESHOLD}"
SETTINGS="${SETTINGS},\"dab_strong_threshold\":${PATHOLOGY_IHC_DAB_STRONG_THRESHOLD}"
SETTINGS="${SETTINGS},\"max_downsample\":${PATHOLOGY_IHC_MAX_DOWNSAMPLE}"
SETTINGS="${SETTINGS},\"tile_size\":${PATHOLOGY_IHC_TILE_SIZE}"
SETTINGS="${SETTINGS},\"max_tiles\":${PATHOLOGY_IHC_MAX_TILES}}"
export PATHOLOGY_IHC_SETTINGS="$SETTINGS"

exec python /opt/pathology/pathology_runner.py ihc-quant
