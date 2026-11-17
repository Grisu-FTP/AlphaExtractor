#!/usr/bin/env bash
# AlphaExtractor: pull sound assets out of a launcher's asset folder.
# Only needs bash + grep/sed/sort.
set -u

OUT_BASE="${OUT_BASE:-$PWD}"   # extracted folders land where you run the script

OFFICIAL_DIRS=(
  "$HOME/.minecraft"
  "$HOME/.var/app/com.mojang.Minecraft/.minecraft"
  "$HOME/snap/mc-installer/current/.minecraft"
)
PRISM_DIRS=(
  "$HOME/.local/share/PrismLauncher"
  "$HOME/.local/share/prismlauncher"
  "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher"
)

# Folders the Alpha ports use (everything else in the old index gets skipped)
ALPHA_DIRS="music|newmusic|newsound|sound|sound3|streaming"

die() { echo "$*" >&2; exit 1; }

# blank line + heading so each step stands out
step() { echo; echo "--- $* ---"; echo; }


# ---------- json helpers ----------
# The index files are simple enough that grep/sed does the job.

# index file -> "path<TAB>hash" per line
list_objects() {
  tr -d '\r\n' < "$1" \
    | grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*\{[[:space:]]*"hash"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{40}"' \
    | sed -E 's/^"([^"]+)".*"([0-9a-fA-F]{40})"$/\1\t\2/'
}

# version json -> id of the asset index it uses
version_asset_index() {
  tr -d '\r\n' < "$1" \
    | grep -oE '"assetIndex"[[:space:]]*:[[:space:]]*\{[^}]*"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/' \
    | head -n1
}


# ---------- step 1: where are the assets? ----------

# first dir in the list that has assets/indexes
find_launcher() {
  local dir
  for dir in "$@"; do
    [[ -d "$dir/assets/indexes" ]] && { echo "$dir"; return 0; }
  done
  return 1
}

choose_source() {
  local official prism choice n=1
  official="$(find_launcher "${OFFICIAL_DIRS[@]}")" || official=""
  prism="$(find_launcher "${PRISM_DIRS[@]}")" || prism=""

  echo "=== AlphaExtractor ==="
  step "1/3  Source"
  echo "  1) Provide path to asset folder (needs 'indexes' and 'objects')"

  local roots=("")   # roots[n-1] = launcher dir for option n
  if [[ -n "$official" ]]; then
    n=$((n+1)); roots+=("$official")
    echo "  $n) Official Minecraft Launcher  ($official)"
  fi
  if [[ -n "$prism" ]]; then
    n=$((n+1)); roots+=("$prism")
    echo "  $n) Prism Launcher               ($prism)"
  fi

  read -r -p "Choice [1-$n]: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )) || die "Invalid choice."

  if (( choice == 1 )); then
    GAME_ROOT=""
    read -r -e -p "Asset folder path: " ASSETS
    ASSETS="${ASSETS/#\~/$HOME}"
  else
    GAME_ROOT="${roots[$((choice-1))]}"
    ASSETS="$GAME_ROOT/assets"
  fi

  [[ -d "$ASSETS/indexes" && -d "$ASSETS/objects" ]] \
    || die "'$ASSETS' needs both an 'indexes' and an 'objects' folder."
}


# ---------- step 2: what versions are in there? ----------

# Fills in:
#   NAMES          menu entries, in display order
#   INDEX_OF[name] asset index behind each entry
#   COUNT[index]   file count per index
find_versions() {
  declare -gA INDEX_OF=() COUNT=()
  declare -A newest_version=()
  local f id

  for f in "$ASSETS"/indexes/*.json; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f" .json)"
    COUNT[$id]="$(list_objects "$f" | wc -l)"
  done

  # Match versions to indexes. Going oldest -> newest means the newest
  # version ends up as the name for each index.
  if [[ -n "$GAME_ROOT" ]]; then
    local row ver
    # Prism keeps them in meta/net.minecraft, the official launcher in versions/<ver>/
    while IFS=$'\t' read -r ver f; do
      id="$(version_asset_index "$f")"
      [[ -n "$id" && -n "${COUNT[$id]:-}" ]] && newest_version[$id]="$ver"
    done < <(
      for f in "$GAME_ROOT"/meta/net.minecraft/*.json "$GAME_ROOT"/versions/*/*.json; do
        [[ -f "$f" ]] && printf '%s\t%s\n' "$(basename "$f" .json)" "$f"
      done | sort -V -k1,1
    )
  fi

  # All the a1.x / b1.x / 1.0-1.5 versions share one index, so show it once
  local name modern=()
  for id in "${!COUNT[@]}"; do
    if [[ "$id" == "pre-1.6" ]]; then
      name="Pre 1.6"
    else
      name="${newest_version[$id]:-$id}"   # no known version? show the index id
      modern+=("$name")
    fi
    INDEX_OF[$name]="$id"
  done

  mapfile -t NAMES < <(printf '%s\n' "${modern[@]}" | sort -V)
  [[ -n "${INDEX_OF[Pre 1.6]:-}" ]] && NAMES+=("Pre 1.6")
  (( ${#NAMES[@]} )) || die "No asset indexes found."
}

choose_version() {
  local i pick
  step "2/3  Version"
  for i in "${!NAMES[@]}"; do
    printf "  %3d) %-16s (%s files)\n" $((i+1)) "${NAMES[$i]}" "${COUNT[${INDEX_OF[${NAMES[$i]}]}]}"
  done

  read -r -p "Extract which one? [1-${#NAMES[@]}]: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#NAMES[@]} )) || die "Invalid choice."

  VERSION="${NAMES[$((pick-1))]}"
  INDEX_ID="${INDEX_OF[$VERSION]}"
}


# ---------- step 3: copy the files ----------

extract() {
  local folder="${VERSION}Re" index_file="$ASSETS/indexes/$INDEX_ID.json"
  local rel hash src dst ok=0 missing=0 legacy=0 yn

  [[ "$VERSION" == "Pre 1.6" ]] && folder="p1.6Re"
  step "3/3  Extract"
  OUT="$OUT_BASE/$folder"

  if [[ -e "$OUT" ]]; then
    read -r -p "'$OUT' already exists, merge into it? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || die "Aborted."
  fi
  mkdir -p "$OUT"

  grep -qE '"map_to_resources"[[:space:]]*:[[:space:]]*true' "$index_file" && legacy=1

  while IFS=$'\t' read -r rel hash; do
    # no icons or realms needed
    [[ "$rel" == icons/* || "$rel" == realms/* ]] && continue
    # everything left lives in minecraft/, so move it up a level
    rel="${rel#minecraft/}"
    # old index also has junk, only keep the Alpha folders
    (( legacy )) && [[ ! "${rel%%/*}" =~ ^($ALPHA_DIRS)$ ]] && continue
    # don't let a weird path escape the output folder
    case "/$rel/" in */../*|//*) continue ;; esac

    src="$ASSETS/objects/${hash:0:2}/$hash"
    [[ -f "$src" ]] || { missing=$((missing+1)); continue; }

    dst="$OUT/$rel"
    mkdir -p "${dst%/*}"
    cp -- "$src" "$dst" && ok=$((ok+1))
  done < <(list_objects "$index_file")

  echo "Extracted $ok files"
  echo
  (( missing )) && echo "Warning: $missing files are in the index but missing from objects/"
  echo "Done -> $OUT"
}


# ---------- go ----------
choose_source
find_versions
choose_version
extract
