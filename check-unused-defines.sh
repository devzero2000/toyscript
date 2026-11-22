#!/bin/sh
# check-unused-defines.sh - report config-header symbols and AC_SUBST
# variables that nothing in the source tree references.
#
# Usage: check-unused-defines.sh <srcdir>
#   srcdir  top of a git checkout containing configure.ac
#
# Requires: git, autoconf (used only for --trace, nothing is generated).
#
# A symbol is reported when its only occurrences are:
#   - its own "#undef SYM" line in a config-header template
#   - configure / configure.ac / aclocal.m4 / build/*.m4 / ChangeLogs
# Symbols used only by test programs inside configure.ac are tagged,
# since they may still steer configure logic.

set -eu

srcdir=${1:?usage: $0 <srcdir>}
cd "$srcdir"

# Config-header templates declared in configure.ac (e.g. include/portable.h).
templates=$(autoconf --trace='AC_CONFIG_HEADERS:$1' configure.ac 2>/dev/null |
    tr ' ' '\n' | sed 's/:.*//; /^$/d' | while read -r h; do
        [ -f "$h.in" ] && echo "$h.in" || { [ -f "${h%.h}.hin" ] && echo "${h%.h}.hin"; }
    done | sort -u)
[ -n "$templates" ] || { echo "nessun AC_CONFIG_HEADERS trovato" >&2; exit 1; }

gen=":(exclude)configure :(exclude)configure.ac :(exclude)aclocal.m4 \
:(exclude)build/*.m4 :(exclude)*ChangeLog* :(exclude)CHANGES"

echo "Template analizzati: $(echo "$templates" | tr '\n' ' ')"
echo
echo "== Simboli del config header mai usati =="
# shellcheck disable=SC2086
sed -n 's/^#[[:space:]]*undef[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' \
    $templates | sort -u | while read -r sym; do
    # Every occurrence outside generated/autoconf files...
    # shellcheck disable=SC2086
    hits=$(git grep -h -w -e "$sym" -- . $gen || true)
    # ...minus the bare "#undef SYM" lines in templates.
    real=$(printf '%s\n' "$hits" |
        grep -v -E "^#[[:space:]]*undef[[:space:]]+$sym([[:space:]]|\$)" |
        grep -c . || true)
    if [ "$real" -eq 0 ]; then
        if grep -q -w -e "$sym" configure.ac 2>/dev/null &&
           grep -w -e "$sym" configure.ac | grep -v -q -E 'AC_DEFINE|AH_TEMPLATE'; then
            echo "$sym  [usato solo nei test di configure.ac]"
        else
            echo "$sym"
        fi
    fi
done

echo
echo "== Variabili AC_SUBST mai usate come @VAR@ =="
autoconf --trace='AC_SUBST:$1' configure.ac 2>/dev/null | sort -u |
while read -r var; do
    # shellcheck disable=SC2086
    git grep -q -F -e "@${var}@" -- . $gen || echo "$var"
done
