#!/bin/sh
# check-unused-defines.sh - report config-header symbols and AC_SUBST
# variables that nothing in the source tree references.
#
# Usage: check-unused-defines.sh <srcdir>
#   srcdir  top of a git checkout containing configure.ac
#
# Requires: git, autoconf (used only for --trace, nothing is generated).
#
# A config-header symbol is reported when, in the C sources (*.c, *.h,
# *.hin, *.cpp, *.y, *.l), its only occurrences are its own
# "#undef SYM" lines in the config-header templates.  Generated autotools
# files are ignored at any depth (configure, aclocal.m4), as are
# build/*.m4, configure.ac and the ChangeLogs.
# Symbols used only by test programs inside configure.ac are tagged,
# since they may still steer configure logic.
#
# An AC_SUBST variable declared in configure.ac itself (not by autoconf
# or libtool macros) is reported when no file contains @VAR@, or when it
# is only substituted into a make variable ("VAR = @VAR@") that no file
# uses as $(VAR), ${VAR} or $(VAR:...).
#
# Subdirectories with their own configure.ac (separate autotools
# projects, e.g. contrib/ldapc++) are ignored.
#
# What this script cannot see (check by hand before removing a test):
#  - configure reusing the cached result ($ac_cv_...) of a test;
#  - side effects of a test: AC_CHECK_LIB adding -lfoo to LIBS,
#    AC_REPLACE_FUNCS / AC_FUNC_MEMCMP adding objects to LIBOBJS, ...;
#  - symbols built by the preprocessor (## concatenation);
#  - code outside the repository using an installed header.

set -eu

srcdir=${1:?usage: $0 <srcdir>}
cd "$srcdir"

# Config-header templates declared in configure.ac (e.g. include/portable.h).
templates=$(autoconf --trace='AC_CONFIG_HEADERS:$1' configure.ac 2>/dev/null |
    tr ' ' '\n' | sed 's/:.*//; /^$/d' | while read -r h; do
        [ -f "$h.in" ] && echo "$h.in" || { [ -f "${h%.h}.hin" ] && echo "${h%.h}.hin"; }
    done | sort -u)
[ -n "$templates" ] || { echo "nessun AC_CONFIG_HEADERS trovato" >&2; exit 1; }

# Generated or autoconf-only files, at any depth
gen=":(exclude,glob)**/configure :(exclude)configure.ac \
:(exclude,glob)**/aclocal.m4 :(exclude)build/*.m4 \
:(exclude,glob)**/*ChangeLog* :(exclude)CHANGES"
# Separate autotools projects in subdirectories
for sub in $(git ls-files '*/configure.ac'); do
    gen="$gen :(exclude)${sub%/configure.ac}"
done
# C sources: where a config-header symbol can be used
csrc=":(glob)**/*.c :(glob)**/*.h :(glob)**/*.hin :(glob)**/*.cpp \
:(glob)**/*.y :(glob)**/*.l"

echo "Template analizzati: $(echo "$templates" | tr '\n' ' ')"
echo
echo "== Simboli del config header mai usati =="
# shellcheck disable=SC2086
sed -n 's/^#[[:space:]]*undef[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' \
    $templates | sort -u | while read -r sym; do
    # Every occurrence in the C sources...
    # shellcheck disable=SC2086
    hits=$(git grep -h -w -e "$sym" -- $csrc $gen || true)
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
echo "== Variabili AC_SUBST mai usate =="
autoconf --trace='AC_SUBST:$1' configure.ac 2>/dev/null | sort -u |
while read -r var; do
    # only the variables configure.ac declares itself
    grep -q -E "AC_SUBST\(\[?${var}\]?[,)]" configure.ac || continue
    # shellcheck disable=SC2086
    if ! git grep -q -F -e "@${var}@" -- . $gen; then
        echo "$var"
        continue
    fi
    # Substituted only as "VAR = @VAR@": is the make variable used?
    # shellcheck disable=SC2086
    other=$(git grep -h -F -e "@${var}@" -- . $gen |
        grep -v -E "^[[:space:]]*${var}[[:space:]]*=[[:space:]]*@${var}@[[:space:]]*\$" |
        grep -c . || true)
    if [ "$other" -eq 0 ]; then
        # shellcheck disable=SC2086
        git grep -q -E -e "\\\$[({]${var}[):}]" -- . $gen ||
            echo "$var  [sostituita in VAR = @VAR@, ma \$(${var}) mai usata]"
    fi
done
