#!/bin/bash
#
# Copyright (c) 2020 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

script_name=${0##*/}

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

[ -n "${DEBUG:-}" ] && set -o xtrace

die()
{
	echo >&2 "::error::$*"
	exit 1
}

usage()
{
	cat <<EOT
Usage: $script_name [options] <pr> <repo-slug>

Description: Check the specified PR to ensure it is labelled with
  the correct porting labels.

Options:

 -h       : Show this help statement.

Notes:

- Designed to be called as a GitHub action.
- Must be run from inside a Git(1) checkout.

EOT
}

setup()
{
	local cmd

	for cmd in git hub jq
	do
		command -v "$cmd" &>/dev/null || \
			die "need command: $cmd"
	done

	git config --get remote.origin.url &>/dev/null || \
		die "not a git checkout"
}

handle_args()
{
	[ "${1:-}" = '-h' ] && usage && exit 0

	local pr="${1:-}"
	local repo="${2:-}"

	[ -z "$pr" ] && die "need PR number"
	[ -z "$repo" ] && die "need repository"

	# Most PRs must have two porting labels before they can be merged.
	#
	# This is to required to ensure it is clear that a reviewer has
	# considered both porting directions.
	#
	# The exception are PRs for an actual backport or forward port which
	# only need one of these labels to be applied since by definition they
	# can only apply to one porting direction.
	local backport_labels=("needs-backport" "no-backport-needed" "backport")
	local forward_port_labels=("needs-forward-port" "no-forward-port-needed" "forward-port")

	# If a PR is labelled with one of these labels, ignore all further
	# checks (since the PR is not yet "ready").
	local ignore_labels=("do-not-merge" "rfc" "wip")

	local labels=$(hub issue labels)

	local label

	# Note: no validation done on ignore_labels as they are not actually
	# porting labels, and so are not essential.
	for label in ${backport_labels[@]} ${forward_port_labels[@]}
	do
		local ret

		{ echo "$labels" | egrep -q "^${label}$"; ret=$?; } || true

		[ $ret -eq 0 ] || die "Expected label '$label' not available in repository $repo"
	done

	local pr_details=$(hub pr list -f '%I;%L%n' | grep "^${pr}" || true)

	[ -z "$pr_details" ] && die "Cannot determine details for PR $pr"

	local pr_labels=$(echo "$pr_details" |\
		cut -d';' -f2 |\
		sed 's/, /,/g' |\
		tr ',' '\n')

	[ -z "$pr_labels" ] && {
		printf "::error::PR %s does not have required porting labels (expected one of '%s' and one of '%s')\n" \
		"$pr" \
		$(echo "${backport_labels[@]}" | tr ' ' ',') \
		$(echo "${forward_port_labels[@]}" | tr ' ' ',')
		exit 1
	}

	local ignore_labels_found=()

	for label in ${ignore_labels[@]}
	do
		echo "$pr_labels" | egrep -q "^${label}$" \
			&& ignore_labels_found+=("$label")
	done

	[ "${#ignore_labels_found[@]}" -gt 0 ] && {
		printf "::debug::Ignoring porting checks as PR %s contains the following special labels: '%s'" \
		"$pr" \
		$(echo "${ignore_labels_found[@]}" | tr ' ' ',')
		exit 0
	}

	local backport_labels_found=()
	local forward_port_labels_found=()

	for label in ${backport_labels[@]}
	do
		echo "$pr_labels" | egrep -q "^${label}$" \
			&& backport_labels_found+=("$label")
	done

	local backport_pr="false"
	local forward_port_pr="false"

	for label in ${forward_port_labels[@]}
	do
		echo "$pr_labels" | egrep -q "^${label}$" \
			&& forward_port_labels_found+=("$label")
	done

	[ "${#backport_labels_found[@]}" -eq 1 ] && \
		[ "$backport_labels_found" = 'backport' ] && \
		backport_pr="true"

	[ "${#forward_port_labels_found[@]}" -eq 1 ] && \
		[ "$forward_port_labels_found" = 'forward-port' ] && \
		forward_port_pr="true"

	# If a PR isn't a forward port PR, it should have atleast one backport
	# label.
	[ "$forward_port_pr" = false ] && [ "${#backport_labels_found[@]}" -eq 0 ] && {
		printf "::error::PR %s missing a backport label (expected one of '%s')\n" \
		"$pr" \
		$(echo "${backport_labels[@]}" | tr ' ' ',')
		exit 1
	}

	[ "$forward_port_pr" = true ] && [ "${#backport_labels_found[@]}" -gt 0 ] && {
		printf "::error::Forward port labelled PR %s cannot have backport labels (backport labels found '%s')\n" \
		"$pr" \
		$(echo "${backport_labels_found[@]}" | tr ' ' ',')
		exit 1
	}

	[ "${#backport_labels_found[@]}" -gt 1 ] && {
		printf "::error::PR %s has too many backport labels (expected one of '%s', found '%s')\n" \
		"$pr" \
		$(echo "${backport_labels[@]}" | tr ' ' ',') \
		$(echo "${backport_labels_found[@]}" | tr ' ' ',')
		exit 1
	}

	# If a PR isn't a backport PR, it should have atleast one forward port
	# label.
	[ "$backport_pr" = false ] && [ "${#forward_port_labels_found[@]}" -eq 0 ] && {
		printf "::error::PR %s missing a forward port label (expected one of '%s')\n" \
		"$pr" \
		$(echo "${forward_port_labels[@]}" | tr ' ' ',')
		exit 1
	}

	[ "$backport_pr" = true ] && [ "${#forward_port_labels_found[@]}" -gt 0 ] && {
		printf "::error::Backport labelled PR %s cannot have forward port labels (forward port labels found '%s')\n" \
		"$pr" \
		$(echo "${forward_port_labels_found[@]}" | tr ' ' ',')
		exit 1
	}

	[ "${#forward_port_labels_found[@]}" -gt 1 ] && {
		printf "::error::PR %s has too many forward port labels (expected one of '%s', found '%s')\n" \
		"$pr" \
		$(echo "${forward_port_labels[@]}" | tr ' ' ',') \
		$(echo "${forward_port_labels_found[@]}" | tr ' ' ',')
		exit 1
	}

	[ "$backport_pr" = true ] && [ "$forward_port_pr" = true ] && {
		printf "::error::PR %s cannot be labelled as both backport ('%s') and forward port ('%s')\n" \
		"$pr" \
		"${backport_labels_found[@]}" \
		"${forward_port_labels_found[@]}"
		exit 1
	}

	printf "::debug::PR %s has required porting labels (backport label '%s', forward port label '%s')\n" \
		"$pr" \
		"${backport_labels_found[@]}" \
		"${forward_port_labels_found[@]}"
}

main()
{
	setup

	handle_args "$@"
}

main "$@"
