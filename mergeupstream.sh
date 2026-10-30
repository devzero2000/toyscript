#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# mergeupstream.sh - keep a fork's master branch in sync with upstream
#
# Copyright (C) 2026 Elia Pinto <gitter.spiros@gmail.com>
#
# Author:  Elia Pinto <gitter.spiros@gmail.com>
# Version: 1.0
# License: GNU General Public License v2.0 only (GPL-2.0-only)
#
# Description:
#   Aligns the "master" branch of a personal fork ("origin") with the
#   "master" branch of the canonical repository ("upstream"), allowing
#   fast-forward updates only:
#
#     1. fetch "upstream" and "origin";
#     2. refuse to continue if origin/master contains commits that are
#        not in upstream/master (i.e. the fork has diverged);
#     3. fast-forward the local master to upstream/master; when master
#        is checked out the working tree must be clean, otherwise the
#        ref is updated in place without touching the working tree;
#     4. push master to "origin" without --force, so the remote rejects
#        anything that is not a fast-forward.
#
#   Nothing is ever rewritten: any divergence aborts the script and has
#   to be resolved by hand.
#
# Usage:
#   mergeupstream.sh [-n | --dry-run] [-h | --help]
#
#     -n, --dry-run   fetch and fast-forward the local master, but run
#                     "git push" with --dry-run (nothing is sent)
#     -h, --help      show this help and exit
#
# Configuration:
#   The remote and branch names are global variables, set at the top of
#   the script. Each one can be overridden from the environment without
#   editing the script:
#
#     MERGEUPSTREAM_UPSTREAM  canonical remote    (default: upstream)
#     MERGEUPSTREAM_ORIGIN    the fork's remote   (default: origin)
#     MERGEUPSTREAM_BRANCH    branch to align     (default: master)
#
#   Example, for a fork whose main branch is "main":
#
#     MERGEUPSTREAM_BRANCH=main mergeupstream.sh
#
# Requirements:
#   POSIX sh, git, and the two remotes above configured in the
#   repository the script is run from.
#
# Exit status:
#   0 on success, 1 on error, 2 on wrong usage.
#
# ChangeLog:
#   2026-10-30  Elia Pinto <gitter.spiros@gmail.com>
#     * 1.0: initial version.
#

set -eu

# Global configuration: the remote that holds the canonical history,
# the remote of the personal fork to update, and the branch to align.
# Defaults can be overridden from the environment (see "Configuration"
# in the header above).
UPSTREAM=${MERGEUPSTREAM_UPSTREAM:-upstream}
ORIGIN=${MERGEUPSTREAM_ORIGIN:-origin}
BRANCH=${MERGEUPSTREAM_BRANCH:-master}

usage () {
	sed -n '/^# Usage:/,/^# Requirements:/{/^# Requirements:/d;s/^# \{0,1\}//;p;}' "$0"
}

die () {
	echo "error: $*" >&2
	exit 1
}

dry_run=
case "${1-}" in
-n|--dry-run) dry_run=--dry-run ;;
-h|--help) usage; exit 0 ;;
"") ;;
*) usage >&2; exit 2 ;;
esac

toplevel=$(git rev-parse --show-toplevel)
cd "${toplevel}"

echo "==> fetching ${UPSTREAM} and ${ORIGIN}"
git fetch --prune "${UPSTREAM}"
git fetch --prune "${ORIGIN}"

up="refs/remotes/${UPSTREAM}/${BRANCH}"
or="refs/remotes/${ORIGIN}/${BRANCH}"
loc="refs/heads/${BRANCH}"

git rev-parse --verify -q "${up}" >/dev/null || die "${up} not found"

# origin must not have commits that upstream does not have
if git rev-parse --verify -q "${or}" >/dev/null &&
   ! git merge-base --is-ancestor "${or}" "${up}"
then
	die "${ORIGIN}/${BRANCH} has diverged from ${UPSTREAM}/${BRANCH}; fix it by hand"
fi

# fast-forward local master
head=$(git symbolic-ref -q HEAD) || head=
if test "${head}" = "${loc}"
then
	if ! git diff --quiet || ! git diff --cached --quiet
	then
		die "uncommitted changes on ${BRANCH}; commit or stash them first"
	fi
	echo "==> fast-forwarding ${BRANCH} (checked out)"
	git merge --ff-only "${up}"
else
	echo "==> fast-forwarding ${BRANCH} (not checked out)"
	# "git fetch ." refuses non-fast-forward updates by itself
	git fetch . "${up}:${loc}" ||
		die "local ${BRANCH} has diverged from ${UPSTREAM}/${BRANCH}"
fi

echo "==> pushing ${BRANCH} to ${ORIGIN}"
git push ${dry_run:+"${dry_run}"} "${ORIGIN}" "${loc}:${loc}"

short=$(git rev-parse --short "${loc}")
subject=$(git log -1 --format=%s "${loc}")
echo "==> done: ${BRANCH} = ${short} ${subject}"
