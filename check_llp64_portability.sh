#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ==============================================================================
# Script Name   : check_llp64_portability.sh
# Description   : Scans a C codebase (tuned for git/git) for LP64/LLP64 64-bit
#                 portability issues (e.g. 'unsigned long' truncation to 32-bit
#                 on Win64) and summarises 64-to-32 bit truncations.
# Author        : Elia Pinto <elia.pinto@cyberactors.it>
# License       : GNU General Public License v3.0 or later (GPL-3.0-or-later)
# ==============================================================================
#
# Copyright (C) 2026 Elia Pinto
#
# The full license text is in the LICENSE file and at
# <https://www.gnu.org/licenses/gpl-3.0.html>.
# ==============================================================================
#
# Usage:
#   check_llp64_portability.sh [SRC_DIR] [BUILD_DIR]
#
#   SRC_DIR    root of the source tree (default: .)
#   BUILD_DIR  directory containing compile_commands.json (default: SRC_DIR)
#
# Environment:
#   TARGET_TRIPLE  if set (e.g. x86_64-w64-mingw32), forces this target on
#                  every TU. Leave EMPTY when compile_commands.json already
#                  comes from a Windows (MinGW) configuration -- recommended.
#   CHECKS         clang-tidy checks (default: truncation-focused set below)
#   JOBS           parallel jobs (default: number of CPUs)
#   REPORT_DIR     output directory (default: ./portability_reports)
#   SKIP_CPPCHECK  set to 1 to skip cppcheck
#   EXCLUDE_REGEX  TUs whose path matches are dropped (default: /subprojects/,
#                  i.e. bundled zlib/OpenSSL in a Meson build; '' keeps all)
#
# Generating compile_commands.json for git:
#   - Best: a Windows/MinGW configuration, e.g. a Meson cross build using
#     clang --target=x86_64-w64-mingw32 (compile_commands.json is written to
#     the build dir at setup time; build once so generated headers exist).
#   - Quick, less accurate: native Linux build with
#       make CC=clang GENERATE_COMPILATION_DATABASE=yes
#     then run with TARGET_TRIPLE=x86_64-w64-mingw32 (needs mingw-w64 headers;
#     Linux-specific defines may break some TUs -- the script reports them).

set -eu

SRC_DIR=${1:-.}
BUILD_DIR=${2:-$SRC_DIR}
REPORT_DIR=${REPORT_DIR:-./portability_reports}
TARGET_TRIPLE=${TARGET_TRIPLE:-}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
SKIP_CPPCHECK=${SKIP_CPPCHECK:-0}
EXCLUDE_REGEX=${EXCLUDE_REGEX-/subprojects/}

# Compiler diagnostics must be whitelisted explicitly as clang-diagnostic-*,
# otherwise '-*' silently drops -Wshorten-64-to-32 output. Keep at least one
# real (non clang-diagnostic-*) check, or clang-tidy aborts with
# "no checks enabled".
CHECKS=${CHECKS:-'-*,clang-diagnostic-shorten-64-to-32,clang-diagnostic-format,bugprone-implicit-widening-of-multiplication-result,bugprone-misplaced-widening-cast,bugprone-too-small-loop-variable,bugprone-sizeof-expression'}

# Colours only when writing to a terminal
if [ -t 1 ]; then
	RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
	BLUE='\033[0;34m'; NC='\033[0m'
else
	RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_err()  { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }
log_succ() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		log_err "Required command '$1' is not installed or not in PATH."
		exit 1
	}
}

# --- 1. PRECONDITIONS ---------------------------------------------------------
require_cmd run-clang-tidy
require_cmd clang-tidy
[ "$SKIP_CPPCHECK" = 1 ] || require_cmd cppcheck

SRC_ABS=$(cd "$SRC_DIR" && pwd)
BUILD_ABS=$(cd "$BUILD_DIR" && pwd)
DB="$BUILD_ABS/compile_commands.json"

if [ ! -s "$DB" ]; then
	log_err "No compile_commands.json in $BUILD_ABS (see header for how to generate it)."
	exit 1
fi

mkdir -p "$REPORT_DIR"
REPORT_DIR=$(cd "$REPORT_DIR" && pwd)
REPORT_CLANG="$REPORT_DIR/clang_tidy_raw.txt"
REPORT_CLANG_ERR="$REPORT_DIR/clang_tidy_stderr.txt"
REPORT_CPPCHECK="$REPORT_DIR/cppcheck_report.txt"
DIAG_UNIQ="$REPORT_DIR/diagnostics_unique.txt"
SUMMARY_FILE="$REPORT_DIR/truncation_summary.txt"

log_info "Source tree : $SRC_ABS"
log_info "Compile DB  : $DB"

# Precompiled headers are built for the host target: once the target is
# forced, clang rejects them and drops the whole TU. Work on a filtered copy
# of the DB without explicit -include-pch, and list the PCH files the driver
# would pick up implicitly for '-include foo.h' (foo.h.gch / foo.h.pch).
require_cmd python3
WORK_DB_DIR="$REPORT_DIR/db"
mkdir -p "$WORK_DB_DIR"
PCH_FOUND=$(python3 -I - "$DB" "$WORK_DB_DIR/compile_commands.json" "$EXCLUDE_REGEX" <<'EOF'
import json, os, re, shlex, sys

src, dst, excl = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    db = json.load(f)

pch = set()

def filt(args, directory):
    out, skip = [], False
    for i, a in enumerate(args):
        if skip:
            skip = False
            continue
        if a == "-include-pch":
            skip = True
            continue
        if a.startswith("-include-pch"):
            continue
        if a == "-include" and i + 1 < len(args):
            hdr = os.path.join(directory, args[i + 1])
            for ext in (".gch", ".pch"):
                if os.path.exists(hdr + ext):
                    pch.add(os.path.normpath(hdr + ext))
        out.append(a)
    return out

if excl:
    rx = re.compile(excl)
    db = [e for e in db
          if not rx.search(os.path.join(e.get("directory", "."), e["file"]))]

for e in db:
    d = e.get("directory", ".")
    if "arguments" in e:
        e["arguments"] = filt(e["arguments"], d)
    elif "command" in e:
        e["command"] = shlex.join(filt(shlex.split(e["command"]), d))

with open(dst, "w") as f:
    json.dump(db, f, indent=1)

print("\n".join(sorted(pch)))
EOF
)
DB="$WORK_DB_DIR/compile_commands.json"
log_info "TUs to analyse: $(grep -c '"file"' "$DB" || true)${EXCLUDE_REGEX:+ (excluding paths matching $EXCLUDE_REGEX)}"

if [ -n "$TARGET_TRIPLE" ] && [ -n "$PCH_FOUND" ]; then
	log_err "Precompiled headers built for the host target would break every TU:"
	printf '%s\n' "$PCH_FOUND" >&2
	log_err "Move them aside for the analysis, e.g.:  mv FILE FILE.off"
	exit 1
fi
if [ -n "$TARGET_TRIPLE" ]; then
	log_info "Target      : $TARGET_TRIPLE (forced)"
else
	log_info "Target      : as recorded in compile_commands.json"
fi

# --- 2. CLANG-TIDY ------------------------------------------------------------
log_info "[1/2] Running clang-tidy on all TUs ($JOBS jobs)..."

# Each flag must be its own -extra-arg; a single quoted string would be
# passed to the compiler as one bogus argument.
set -- -extra-arg=-Wshorten-64-to-32 -extra-arg=-Wno-error
if [ -n "$TARGET_TRIPLE" ]; then
	set -- "$@" "-extra-arg=--target=$TARGET_TRIPLE"
fi

# Only report diagnostics in this tree (skip system/third-party headers).
HEADER_FILTER="^$SRC_ABS/"

run-clang-tidy \
	-p "$WORK_DB_DIR" \
	-j "$JOBS" \
	-quiet \
	-checks="$CHECKS" \
	-header-filter="$HEADER_FILTER" \
	"$@" \
	"^$SRC_ABS/" \
	>"$REPORT_CLANG" 2>"$REPORT_CLANG_ERR" || true

# Headers are reported once per including TU: keep unique diagnostics only.
grep -E '^[^ ]+:[0-9]+:[0-9]+: (warning|error): .*\[[^]]+\]$' "$REPORT_CLANG" |
	sort -u >"$DIAG_UNIQ" || true

# Parse failures mean incomplete results: never let them pass silently.
# Some errors (e.g. PCH mismatch) carry no 'file:line:' prefix, and clang-tidy
# prints one 'Error while processing <file>' line per failed TU.
PARSE_ERRORS=$(cat "$REPORT_CLANG" "$REPORT_CLANG_ERR" |
	grep -c -E '(^|: )(fatal )?error: ' || true)
FAILED_TUS=$(cat "$REPORT_CLANG" "$REPORT_CLANG_ERR" |
	grep -c '^Error while processing ' || true)
if [ "$PARSE_ERRORS" -gt 0 ] || [ "$FAILED_TUS" -gt 0 ]; then
	log_warn "$FAILED_TUS TUs failed ($PARSE_ERRORS compiler errors): results are incomplete."
	log_warn "Top causes:"
	cat "$REPORT_CLANG" "$REPORT_CLANG_ERR" |
		grep -E '(^|: )(fatal )?error: ' | sed 's/.*error: //' |
		sort | uniq -c | sort -rn | head -n 5 >&2
fi

# --- 3. CPPCHECK (printf format / pointer-to-integer under win64 sizes) ------
if [ "$SKIP_CPPCHECK" != 1 ]; then
	log_info "[2/2] Running cppcheck --platform=win64..."
	cppcheck \
		--project="$DB" \
		--platform=win64 \
		--enable=warning,portability \
		--inline-suppr \
		--quiet \
		-j "$JOBS" \
		--template='{file}:{line}:{column}: {severity}: {message} [{id}]' \
		2>"$REPORT_CPPCHECK" >/dev/null || true
else
	: >"$REPORT_CPPCHECK"
fi

# --- 4. SUMMARY ---------------------------------------------------------------
TRUNC_COUNT=$(grep -c 'shorten-64-to-32' "$DIAG_UNIQ" || true)
TIDY_COUNT=$(grep -c . "$DIAG_UNIQ" || true)
CPP_COUNT=$(grep -c . "$REPORT_CPPCHECK" || true)

{
	printf '======================================================================\n'
	printf '  LLP64 PORTABILITY SUMMARY\n'
	printf '  Generated : %s\n' "$(date)"
	printf '  Tree      : %s\n' "$SRC_ABS"
	printf '======================================================================\n\n'

	printf 'clang-tidy unique diagnostics : %s\n' "$TIDY_COUNT"
	printf '  of which 64->32 truncations : %s\n' "$TRUNC_COUNT"
	printf 'cppcheck diagnostics          : %s\n' "$CPP_COUNT"
	printf 'TUs failed to parse           : %s (%s compiler errors)\n\n' "$FAILED_TUS" "$PARSE_ERRORS"

	printf -- '--- clang-tidy: by check ---\n'
	sed -n 's/.*\[\([^]]*\)\]$/\1/p' "$DIAG_UNIQ" | sort | uniq -c | sort -rn
	printf '\n--- clang-tidy: top 25 files ---\n'
	cut -d: -f1 "$DIAG_UNIQ" | sed "s|^$SRC_ABS/||" | sort | uniq -c | sort -rn | head -n 25

	printf '\n--- cppcheck: by id ---\n'
	sed -n 's/.*\[\([^]]*\)\]$/\1/p' "$REPORT_CPPCHECK" | sort | uniq -c | sort -rn

	printf '\n--- 64->32 truncations (unique) ---\n'
	grep 'shorten-64-to-32' "$DIAG_UNIQ" | sed "s|^$SRC_ABS/||" || true
} >"$SUMMARY_FILE"

printf '\n'
log_info "Reports in $REPORT_DIR"
log_info "  clang-tidy raw     : $REPORT_CLANG"
log_info "  clang-tidy unique  : $DIAG_UNIQ"
log_info "  cppcheck           : $REPORT_CPPCHECK"
log_info "  summary            : $SUMMARY_FILE"

if [ "$TIDY_COUNT" -gt 0 ] || [ "$CPP_COUNT" -gt 0 ]; then
	printf "${RED}[!] %s clang-tidy (%s truncations) + %s cppcheck findings${NC}\n" \
		"$TIDY_COUNT" "$TRUNC_COUNT" "$CPP_COUNT"
	exit 2
fi

if [ "$PARSE_ERRORS" -gt 0 ] || [ "$FAILED_TUS" -gt 0 ]; then
	log_warn "No findings, but analysis was incomplete."
	exit 3
fi

log_succ "No 64-to-32 bit truncations detected."
