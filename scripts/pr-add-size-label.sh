#!/bin/bash

# Copyright (c) 2022 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

readonly description=$(cat <<EOT
Script to add a "size" label to a PR. The size is
calculated as the sum of changes (total additions and deletions).
The size total is then looked up in the size_ranges tables to
determine the appropriate GitHub label to apply to the PR.
EOT
)

readonly script_name=${0##*/}

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

[ -n "${DEBUG:-}" ] && set -o xtrace

# Since this script relies on the output of various commands,
# protect against the future possibility of those commands being
# internationalised.
export LC_ALL="C"
export LANG="C"

readonly label_prefix="size/"

# Ranges that are used to determine which sizing label should be
# applied to a PR.
#
# The range value must be in one of the following formats:
#
# - "<maximum" (value less than the specified maximum).
# - "minimum-maximum" (open interval value between the specified bounds).
# - ">minimum" (value greater than the specified minimum).
#
# Notes:
#
# - The values specified here are arbitrary and may need tweaking
#   (or overriding with the appropriate environment variable).
# - The ranges must not overlap.
readonly default_tiny_range='<10'
readonly default_small_range='10-49'
readonly default_medium_range='50-100'
readonly default_large_range='101-500'
readonly default_huge_range='>500'

# Allow the default ranges to be overriden by environment variables.
KATA_PR_SIZE_RANGE_TINY="${KATA_PR_SIZE_RANGE_TINY:-$default_tiny_range}"
KATA_PR_SIZE_RANGE_SMALL="${KATA_PR_SIZE_RANGE_SMALL:-$default_small_range}"
KATA_PR_SIZE_RANGE_MEDIUM="${KATA_PR_SIZE_RANGE_MEDIUM:-$default_medium_range}"
KATA_PR_SIZE_RANGE_LARGE="${KATA_PR_SIZE_RANGE_LARGE:-$default_large_range}"
KATA_PR_SIZE_RANGE_HUGE="${KATA_PR_SIZE_RANGE_HUGE:-$default_huge_range}"

typeset -A size_ranges

# Hash of labels and ranges uses to determine which label
# should be applied to a PR.
#
# key: Label suffix to add to PR if it matches the "size" specified
#  by the value.
# value: Size range.
size_ranges=(
    [tiny]="$KATA_PR_SIZE_RANGE_TINY"
    [small]="$KATA_PR_SIZE_RANGE_SMALL"
    [medium]="$KATA_PR_SIZE_RANGE_MEDIUM"
    [large]="$KATA_PR_SIZE_RANGE_LARGE"
    [huge]="$KATA_PR_SIZE_RANGE_HUGE"
)

info()
{
    echo "INFO: $*"
}

die()
{
    echo >&2 "ERROR: $*"
    exit 1
}

setup()
{
    local cmds=()

    cmds+=("diffstat")
    cmds+=("filterdiff")

    # https://github.com/cli/cli
    cmds+=("gh")

    local cmd

    local ret

    for cmd in "${cmds[@]}"
    do
        { command -v "$cmd" &>/dev/null; ret=$?; } || true
        [ "$ret" -eq 0 ] || die "need command '$cmd'"
    done

    local vars=()

    vars+=("GITHUB_TOKEN")

    local var

    for var in "${vars[@]}"
    do
        local value

        value=$(printenv "$var" || true)

        [ -n "${value}" ] || die "need to set '$var'"
    done

    # Force non interactive mode
    gh config set prompt disabled
}

# Return an integer representing the "size" of a PR,
# calculated as the sum of additions and deletions
# (the amount of change).
#
# Note: This function attempts to exclude:
#
# - Vendored code changes (pristine upstream files) since vendored code,
#   by definition, should be treated as "read only" and those changes
#   result as a _side effect_ of the actual change (which tends to be a
#   version bump in a configuration file (which causes the pristine vendor
#   code to be updated).
#
# - Auto-generated code.
#
# - generated lock/status files for languages like golang and rust.
get_pr_size()
{
    local pr="${1:-}"
    [ -z "$pr" ] && die "need PR number"

    local stats

    # Determine the amount of change for the specified PR.
    #
    # Notes:
    #
    # - The exclusions specified here should be similar to the logic in:
    #
    #   https://github.com/kata-containers/tests/blob/main/.ci/static-checks.sh
    #
    # - Example output showing the diffstat(1) formats:
    #
    #     "99 files changed, 12345 insertions(+), 987 deletions(-)"
    #     "1 file changed, 1 insertion(+)"
    #     "1 file changed, 2 deletions(-)"
    stats=$(gh pr diff "$pr" |\
            filterdiff \
                --exclude='Cargo.lock' \
                --exclude='go.mod' \
                --exclude='go.sum' \
                --exclude='*.pb.go' \
                --exclude='*.pb_test.go' \
                --exclude='*/src/libs/protocols/src/*.rs' \
                --exclude='*/vendor/*' \
                --exclude='*/virtcontainers/pkg/cloud-hypervisor/client' \
                --exclude='*/virtcontainers/pkg/firecracker/client' \
                |\
            diffstat -s)

    local additions
    local deletions

    additions=$(echo "$stats" |\
        grep -Eo '[0-9]+ insertions?' |\
        awk '{print $1}' \
        || echo '0')

    deletions=$(echo "$stats" |\
        grep -Eo '[0-9]+ deletions?' |\
        awk '{print $1}' \
        || echo '0')

    local total
    total=$(( additions + deletions ))

    echo "$total"
}

# Determine which label to add based on the specified PR size
get_label_to_add()
{
    local size="${1:-}"
    [ -z "$size" ] && die "need size value"

    local label

    for label in "${!size_ranges[@]}"
    do
        local range

        range="${size_ranges[$label]}"

        local value

        if grep -Eq '^<[0-9]+$' <<< "$range"
        then
            # Handle maximum bound
            value=$(echo "$range"|sed 's/^<//g')

            (( size < value )) && \
            printf "%s%s" "$label_prefix" "$label" && \
            return 0
        elif grep -Eq '^>[0-9]+$' <<< "$range"
        then
            # Handle minimum bound
            value=$(echo "$range"|sed 's/^>//g')

            (( size > value )) && \
            printf "%s%s" "$label_prefix" "$label" && \
            return 0
        elif grep -Eq '^[0-9]+-[0-9]+$' <<< "$range"
        then
            # Handle range
            local from
            local to

            from=$(echo "$range"|cut -d'-' -f1)
            to=$(echo "$range"|cut -d'-' -f2)

            (( from > to )) && die "invalid from/to range: '$range'"

            (( size > from )) && \
            (( size < to )) && \
            printf "%s%s" "$label_prefix" "$label" && \
            return 0
        else
            die "invalid range format: '$range'"
        fi
    done
}

# Add the specified label to the specified PR.
#
# Note that the function handles the following sizing label scenarios:
#
# - the PR is already labelled correctly.
# - the PR is mis-labelled (has >0 existing size labels set).
handle_pr_labels()
{
    local pr="${1:-}"
    [ -z "$pr" ] && die "need PR number"

    local label="${2:-}"
    [ -z "$label" ] && die "need label to add"

    existing_size_labels=$(gh pr view "$pr" |\
        grep '^labels:' |\
        cut -d: -f2- |\
        tr -d '\t' |\
        tr ',' '\n' |\
        sed 's/^ *//g' |\
        grep "^${label_prefix}" \
        || true)

    local existing

    local add_label_args=""
    local rm_label_args=""

    add_label_args="--add-label '$label'"

    for existing in $existing_size_labels
    do
        # The PR already has the correct label, so ignore that one.
        [ "$existing" = "$label" ] && add_label_args="" && continue

        rm_label_args+=" --remove-label '$existing'"
    done

    # The PR is already labeled correctly and has no additional sizing
    # labels.
    [ -z "$add_label_args" ] && \
    [ -z "$rm_label_args" ] && \
    echo "::debug::PR $pr already labeled" && \
    return 0

    local pr_url

    # Update the PR to remove any old sizing labels and add the
    # correct new one.
    pr_url=$(eval gh pr edit \
        "$pr" \
        "$add_label_args" \
        "$rm_label_args")

    echo "::debug::Added label '$label' to PR $pr ($pr_url)"
}

handle_pr()
{
    local dry_run="${1:-}"
    [ -z "$dry_run" ] && die "need dry run value"

    local pr="${2:-}"
    [ -z "$pr" ] && die "need PR number"

    local size
    local label

    size=$(get_pr_size "$pr")

    echo "::debug::Size of PR $pr: $size"

    label=$(get_label_to_add "$size")

    echo "::debug::Label to add to PR $pr: '$label'"

    [ "$dry_run" = 'true' ] && \
            echo '::debug::Not changing PR (dry-run mode)' && \
            return 0

    handle_pr_labels "$pr" "$label"
}

usage()
{
    cat <<EOT
Usage: $script_name [options] [<pr>]

Description: $description

Options:

 -h       : Show this help statement.
 -n       : Dry run mode (does not modify PR).
 -p <pr>  : Specify PR number.

Examples:

- Add the appropriate sizing label to the specified PR:

  $ $script_name 123

- As above:

  $ $script_name -p 123

- Show details of what the script would would do:

  $ $script_name -p 123 -n

EOT
}

handle_args()
{
    local pr=""
    local dry_run='false'

    local opt

    while getopts "hnp:" opt "$@"
    do
        case "$opt" in
            h) usage && exit 0 ;;
            n) dry_run='true' ;;
            p) pr="$OPTARG" ;;
        esac
    done

    shift $[$OPTIND-1]

    [ -z "$pr" ] && die "need PR number"

    setup

    handle_pr "$dry_run" "$pr"
}

main()
{
    handle_args "$@"
}

main "$@"
