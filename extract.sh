#!/usr/bin/env bash
# AlphaExtractor: pull sound assets out of a launcher's asset folder.
# Only needs bash + grep/sed/sort. Works on Linux, macOS (stock bash 3.2) and Windows via Git Bash.
set -u

# Windows (Git Bash / MSYS / Cygwin): %APPDATA% and C:\paths need translating
if command -v cygpath >/dev/null 2>&1; then
  ON_WINDOWS=1
else
  ON_WINDOWS=0
fi

# Turn a Windows path (C:\Users\me\x) into one bash understands (/c/Users/me/x)
to_unix_path() {
  if (( ON_WINDOWS )); then cygpath -u -- "$1"; else printf '%s\n' "$1"; fi
}

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

# macOS
OFFICIAL_DIRS+=("$HOME/Library/Application Support/minecraft")
PRISM_DIRS+=("$HOME/Library/Application Support/PrismLauncher")

if (( ON_WINDOWS )); then
  APPDATA_U="$(to_unix_path "${APPDATA:-$USERPROFILE/AppData/Roaming}")"
  LOCALAPPDATA_U="$(to_unix_path "${LOCALAPPDATA:-$USERPROFILE/AppData/Local}")"
  OFFICIAL_DIRS+=("$APPDATA_U/.minecraft")
  PRISM_DIRS+=("$APPDATA_U/PrismLauncher" "$LOCALAPPDATA_U/PrismLauncher")
fi

# Folders the Alpha ports use (everything else in the old index gets skipped)
ALPHA_DIRS="music|newmusic|newsound|sound|sound3|streaming"

die() { echo "$*" >&2; exit 1; }

# blank line + heading so each step stands out
step() { echo; echo "--- $* ---"; echo; }


# natural version sort (older macOS sort may lack -V, fall back to plain sort)
vsort() { sort -V 2>/dev/null || sort; }


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
    ASSETS="${ASSETS%\"}"; ASSETS="${ASSETS#\"}"   # drop quotes from drag&drop / copy as path
    ASSETS="${ASSETS%\'}"; ASSETS="${ASSETS#\'}"
    ASSETS="$(printf '%s' "$ASSETS" | sed -E 's/\\(.)/\1/g')"   # terminal drag&drop escapes spaces as "\ "
    ASSETS="${ASSETS%/}"
    case "$ASSETS" in "~"|"~/"*) ASSETS="$HOME${ASSETS#\~}" ;; esac
    ASSETS="$(to_unix_path "$ASSETS")"
    # allow pointing at the launcher folder (the one containing assets/)
    if [[ ! -d "$ASSETS/indexes" && -d "$ASSETS/assets/indexes" ]]; then
      GAME_ROOT="$ASSETS"
      ASSETS="$ASSETS/assets"
    fi
  else
    GAME_ROOT="${roots[$((choice-1))]}"
    ASSETS="$GAME_ROOT/assets"
  fi

  [[ -d "$ASSETS" ]] || die "'$ASSETS' doesn't exist."
  [[ -d "$ASSETS/indexes" && -d "$ASSETS/objects" ]] \
    || die "'$ASSETS' needs both an 'indexes' and an 'objects' folder."
}


# ---------- step 2: what versions are in there? ----------

# Fills in parallel arrays (bash 3.2 has no associative arrays):
#   IDS[i] / COUNTS[i] / VERS[i]   asset index id, file count, newest version using it
#   NAMES[j] / NAME_IDS[j]         menu entries (display order) and the index each maps to
find_versions() {
  IDS=(); COUNTS=(); VERS=(); NAMES=(); NAME_IDS=()
  local f id i row ver

  for f in "$ASSETS"/indexes/*.json; do
    [[ -f "$f" ]] || continue
    IDS+=("$(basename "$f" .json)")
    COUNTS+=("$(list_objects "$f" | wc -l | tr -d ' ')")
    VERS+=("")
  done
  (( ${#IDS[@]} )) || die "No asset indexes found."

  # Match versions to indexes. Going oldest -> newest means the newest
  # version ends up as the name for each index.
  if [[ -n "$GAME_ROOT" ]]; then
    # Prism keeps them in meta/net.minecraft, the official launcher in versions/<ver>/
    while IFS=$'\t' read -r ver f; do
      id="$(version_asset_index "$f")"
      [[ -n "$id" ]] || continue
      for i in "${!IDS[@]}"; do
        [[ "${IDS[$i]}" == "$id" ]] && VERS[$i]="$ver"
      done
    done < <(
      for f in "$GAME_ROOT"/meta/net.minecraft/*.json "$GAME_ROOT"/versions/*/*.json; do
        [[ -f "$f" ]] && printf '%s\t%s\n' "$(basename "$f" .json)" "$f"
      done | vsort -k1,1
    )
  fi

  # All the a1.x / b1.x / 1.0-1.5 versions share one index, so show it once.
  # Modern ones first (version sorted), "Pre 1.6" last.
  local pre=-1
  while IFS=$'\t' read -r row i; do
    [[ -n "$row" ]] || continue
    NAMES+=("$row"); NAME_IDS+=("$i")
  done < <(
    for i in "${!IDS[@]}"; do
      [[ "${IDS[$i]}" == "pre-1.6" ]] && continue
      printf '%s\t%s\n' "${VERS[$i]:-${IDS[$i]}}" "$i"   # no known version? show the index id
    done | vsort -k1,1
  )
  for i in "${!IDS[@]}"; do
    [[ "${IDS[$i]}" == "pre-1.6" ]] && { NAMES+=("Pre 1.6"); NAME_IDS+=("$i"); }
  done
  (( ${#NAMES[@]} )) || die "No asset indexes found."
}

choose_version() {
  local i pick
  step "2/3  Version"
  for i in "${!NAMES[@]}"; do
    printf "  %3d) %-16s (%s files)\n" $((i+1)) "${NAMES[$i]}" "${COUNTS[${NAME_IDS[$i]}]}"
  done

  read -r -p "Extract which one? [1-${#NAMES[@]}]: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#NAMES[@]} )) || die "Invalid choice."

  VERSION="${NAMES[$((pick-1))]}"
  INDEX_ID="${IDS[${NAME_IDS[$((pick-1))]}]}"
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

  local alpha_re="^($ALPHA_DIRS)$"
  grep -qE '"map_to_resources"[[:space:]]*:[[:space:]]*true' "$index_file" && legacy=1

  while IFS=$'\t' read -r rel hash; do
    # no icons or realms needed
    [[ "$rel" == icons/* || "$rel" == realms/* ]] && continue
    # everything left lives in minecraft/, so move it up a level
    rel="${rel#minecraft/}"
    # old index also has junk, only keep the Alpha folders
    (( legacy )) && [[ ! "${rel%%/*}" =~ $alpha_re ]] && continue
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
