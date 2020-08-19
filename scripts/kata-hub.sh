#!/bin/bash

# Copyright (c) 2020 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

[ -n "${DEBUG:-}" ] && set -o xtrace

script_name=${0##*/}

#---------------------------------------------------------------------

die()
{
    echo >&2 "$*"
    exit 1
}

usage()
{
    cat <<EOT
Usage: $script_name [command] [arguments]

Description: Utility to expand the abilities of the GitHub hub(1) tool.

Command descriptions:

  add-issue              Add an issue to a project.
  list-columns           List project board columns.
  list-issue-linked-prs  List all PRs with linked issues.
  list-issue-projects    List projects an issue is part of.
  list-issues            List issues in a project.
  list-milestone         List issues in a milestone.
  list-milestones        List milestones.
  list-pr-linked-issues  List all issues with linked PRs.
  list-projects          List projects.
  move-issue             Move an issue card to another project column.

Commands and arguments:

  add-issue            <issue> <project> <project-type> [<column-name>]
  list-columns         <project> <project-type>
  list-issue-linked-prs
  list-issue-projects  <issue>
  list-issues          <project> <project-type>
  list-milestone       <milestone>
  list-milestones
  list-pr-linked-issues
  list-projects        <project-type>
  move-issue           <issue> <project> <project-type> <project-column>

Options:

 -h : Show this help statement.

Examples:

- List issues in a top-level (organisation-level) project

  $ $script_name list-issues top-level-project org

- Add issue 123 to the 'Foo Bar' repo-level project:

  $ $script_name add-issue 123 'Foo Bar' repo

- Move issue 99 in the 'Issue backlog' project to the 'In progress' column:

  $ $script_name move-issue 99 'Issue backlog' repo 'In progress'

Notes:

- Adding an issue to a project moves it into the first (left-hand) column.

- GitHub requires that an issue be in a project before it can be moved,
  so you must call "add-issue" before you can call "move-issue".

EOT
}

# Make a GitHub API call.
#
# For "extensions" ("previews"), see:
#
#   https://developer.github.com/v3/previews/
#
# Examples:
#
#   inertia-preview : Projects.
#   starfox-preview : Project card details.
github_api()
{
    local preview='application/vnd.github.inertia-preview+json'

    hub api -H "accept: ${preview}" "$@"
}

# Convert an API url to a human-readable HTML one.
#
# Example:
#
# Input API URL:
#
#     https://api.github.com/repos/${org}/${repo}/issues/${issue}
#
# Output HTML URL:
#
#     https://github.com/${org}/${repo}/issues/${issue}
#
github_api_url_to_html_url()
{
        local api_url="${1:-}"

        [ -z "$api_url" ] && die "need API url"

        echo "$api_url" |\
                sed \
                -e 's/api.github.com/github.com/g' \
                -e 's!/repos!!g'
}

get_repo_url()
{
    git config --get remote.origin.url
}

get_repo_slug()
{
    local repo_url=$(get_repo_url || true)

    [ -z "$repo_url" ] && die "cannot determine repo URL"

    echo "$repo_url" | awk -F\/ '{print $4, $5}' | tr ' ' '/'
}

get_project_url_from_type()
{
    local project_type="${1:-}"

    [ -z "$project_type" ] && die "need project type"

    local project_url

    # XXX: Note that the official API documentation *appears* to be wrong:
    #
    # - It states that "user" projects should specify "{username}", but only
    #   "{owner}" works!
    #
    # - It states that "org" projects should specify "{org}", but only
    #   "{owner}" works!
    #
    # See:
    #
    # https://developer.github.com/v3/projects/

    case "$project_type" in
        org) project_url="orgs/{owner}/projects" ;;
        repo) project_url="repos/{owner}/{repo}/projects" ;;
        user) project_url="users/{owner}/projects" ;;
        *) die "invalid project type: '$project_type'" ;;
    esac

    echo "$project_url"
}

# Returns the URL that is used to query the individual columns
# for a project board.
get_project_columns_url()
{
    local project="${1:-}"
    local project_url="${2:-}"

    [ -z "$project" ] && die "need project name"
    [ -z "$project_url" ] && die "need project URL"

    local columns_url

    columns_url="$(github_api \
        -XGET "${project_url}" \
        -f state="open" |\
        jq -r '.[] |
        select((.name | ascii_downcase)
            == ($project_name | ascii_downcase))
            | .columns_url' \
        --arg project_name "$project")"

    echo "$columns_url"
}

get_project_name_by_id()
{
    local project_id="${1:-}"

    [ -z "$project_id" ] && die "need project ID"

    github_api -XGET "/projects/${project_id}" |\
        jq -r '.name'
}

list_projects_for_issue()
{
    local issue="${1:-}"

    [ -z "$issue" ] && die "need issue"

    local fields

    echo "# Issue $issue is in the following projects"
    echo "#"
    echo "# Fields: project-name;project-url;column-name;card-id;card-url"

    # Note that all events are always available to query. There is no
    # timestamp, but they are ordered, first to last. Hence, only consider the
    # last event (array index '-1') as it shows the current status.
    hub api \
        -H 'accept: application/vnd.github.starfox-preview+json' \
        -XGET "/repos/{owner}/{repo}/issues/${issue}/events" |\
        jq -r '.[-1] |
        select (.project_card != null) .project_card |
            join("|")' |\
        while read fields
        do
            local card_id=$(echo "$fields"|cut -d\| -f1)
            local card_url=$(echo "$fields"|cut -d\| -f2)
            local project_id=$(echo "$fields"|cut -d\| -f3)

            local project_name=$(get_project_name_by_id "$project_id")

            local project_url=$(echo "$fields"|cut -d\| -f4)
            local column_name=$(echo "$fields"|cut -d\| -f5)

            printf "%s;%s;%s;%s;%s\n" \
                "$project_name" \
                "$project_url" \
                "$column_name" \
                "$card_id" \
                "$card_url"
        done
}

# Determine if the specified issue is in the specified project. If it is,
# return the project column name, card id and card URL, else return "".
issue_is_in_project()
{
    local issue="${1:-}"
    local project="${2:-}"

    [ -z "$issue" ] && die "need issue"
    [ -z "$project" ] && die "need project"

    local fields=$(list_projects_for_issue "$issue"|grep -v "^\#"|grep -i "^${project};")
    [ -z "$fields" ] && \
        die "cannot determine project fields for issue $issue in project $project"

    local column_name=$(echo "$fields"|cut -d';' -f3)
    local card_id=$(echo "$fields"|cut -d';' -f4)
    local card_url=$(echo "$fields"|cut -d';' -f5)

    echo "${column_name};${card_id};${card_url}"
}

find_git_checkout()
{
    local repo_slug="${1:-}"

    [ -z "$repo_slug" ] && die "need repo slug"

    local repo_name=$(echo "$repo_slug"|cut -d\/ -f2)

    # List of directories to look for the specified repo
    local -a dirs

    # Check the parent directory first
    dirs+=("$PWD/../${repo_name}")

    # Check GOPATH in case it's a golang project.
    [ -z "${GOPATH:-}" ] && GOPATH=$(go env GOPATH 2>/dev/null || true)
    [ -n "${GOPATH:-}" ] && dirs+=("$GOPATH/src/github.com/${repo_slug}")

    local dir

    for dir in "${dirs[@]}"
    do
        [ -d "$dir" ] && readlink -e "$dir" && return
    done

    echo ""
}

list_project_columns()
{
    local project="${1:-}"
    local project_type="${2:-}"

    [ -z "$project" ] && die "need project name"
    [ -z "$project_type" ] && die "need project type"

    local project_url
    project_url=$(get_project_url_from_type "$project_type")
    [ -z "$project_url" ] && die "cannot determine project URL"

    local columns_url
    columns_url=$(get_project_columns_url "$project" "$project_url")
    [ -z "$columns_url" ] && die "cannot determine column URL for project '$project'"

    echo "# Columns for '$project_type' project '$project' (url: $project_url)"

    local column_details
    local column_index=0

    echo "# (index; column_url; column_id; column_name)"

    github_api "$columns_url" |\
            jq -r '.[] | join("|")' |\
            while read column_details
    do
        local column_url=$(echo "$column_details"|cut -d'|' -f1)
        local column_cards_url=$(echo "$column_details"|cut -d'|' -f3)
        local column_id=$(echo "$column_details"|cut -d'|' -f4)
        local column_name=$(echo "$column_details"|cut -d'|' -f6)

        printf "%d;%s;%s;%s\n" \
            "$column_index" \
            "$column_url" \
            "$column_id" \
            "$column_name"

        column_index=$((column_index +1))
    done
}

list_issues_in_project()
{
    local project="${1:-}"
    local project_type="${2:-}"

    [ -z "$project" ] && die "need project name"
    [ -z "$project_type" ] && die "need project type"

    local project_url
    project_url=$(get_project_url_from_type "$project_type")
    [ -z "$project_url" ] && die "cannot determine project URL"

    local columns_url
    columns_url=$(get_project_columns_url "$project" "$project_url")
    [ -z "$columns_url" ] && die "cannot determine column URL for project '$project'"

    local current_repo_url=$(get_repo_url)
    [ -z "$current_repo_url" ] && die "cannot determine current repo URL"

    local current_repo_slug=$(echo "$current_repo_url"|awk -F\/ '{print $4, $5}'|tr ' ' '/')

    local column_details
    github_api "$columns_url" |\
            jq -r '.[] | join("|")' |\
            while read column_details
    do
        local column_url=$(echo "$column_details"|cut -d'|' -f1)
        local column_cards_url=$(echo "$column_details"|cut -d'|' -f3)
        local column_id=$(echo "$column_details"|cut -d'|' -f4)
        local column_name=$(echo "$column_details"|cut -d'|' -f6)

        printf "# $column_name (id: $column_id, url: $column_url)\n"

        local fields

        printf "#\n# Fields: issue;title;issue-url;card-id;card-url\n"

        github_api "$column_cards_url" |\
            jq -r '.[] |
            [.id, .url, .content_url] |
            join("|")' |\
            while read fields
        do
            [ "$fields" = null ] && continue
            [ -z "$fields" ] && continue

            local card_id=$(echo "$fields"|cut -d'|' -f1)
            local card_url=$(echo "$fields"|cut -d'|' -f2)
            local issue_url=$(echo "$fields"|cut -d'|' -f3)

            local issue=""
            local issue_repo=""
            local issue_title=""

            # Project cards don't have to be linked to an issue - they can be
            # just some text, so only do the issue processing if required.
            if [ -n "$issue_url" ]
            then
                issue=$(echo "$issue_url"|awk -F\/ '{print $NF}')

                issue_repo=$(echo "$issue_url"|awk -F\/ '{print $6}')

                # "username/repo" or "org-name/repo"
                issue_repo_slug=$(echo "$issue_url"|awk -F\/ '{print $5, $6}'|tr ' ' '/')

                # We are sitting in a git checkout for some repo 'x'. If the
                # project we are querying is a top-level 'org' or 'user' project,
                # it may contain issues from *other* repos. Check by comparing the
                # repo slug for the current git checkout with the issues repo
                # slug.
                #
                # XXX: Since hub(1) only works in the current repo, so to query
                # XXX: another repos issues, you need to be sitting in that repos
                # XXX: directory!
                if [ "$issue_repo_slug" = "$current_repo_slug" ]
                then
                    issue_title=$(hub issue show -f "%t" "$issue")
                else
                    local issue_repo_dir=$(find_git_checkout "$issue_repo_slug" || true)

                    if [ -n "$issue_repo_dir" ]
                    then
                        pushd "$issue_repo_dir" &>/dev/null
                        issue_title=$(hub issue show -f "%t" "$issue")
                        popd &>/dev/null
                    fi
                fi
            else
                issue="card"
            fi

            printf "%s;%s;%s;%s;%s\n" \
                "$issue" \
                "$issue_title" \
                "$issue_url" \
                "$card_id" \
                "$card_url"
        done

        echo
    done
}

add_issue_to_project()
{
    local issue="${1:-}"
    local project="${2:-}"
    local project_type="${3:-}"

    [ -z "$issue" ] && die "need issue"
    [ -z "$project" ] && die "need project"
    [ -z "$project_type" ] && die "need project type"

    # Issues are implicity repo-level entities
    local issue_id="$(github_api "repos/{owner}/{repo}/issues/${issue}" |\
            jq -r '.id')"
    [ -z "$issue_id" ] && die "cannot determine issue id for issue $issue"

    local project_url
    project_url=$(get_project_url_from_type "$project_type")
    [ -z "$project_url" ] && die "cannot determine project URL"

    # Find the project by name
    local columns_url
    columns_url=$(get_project_columns_url "$project" "$project_url")
    [ -z "$columns_url" ] && die "cannot determine column URL for project '$project'"

    local issue_in_project=$(issue_is_in_project "$issue" "$project")

    if [ -n "$issue_in_project" ]
    then
        local issue_column=$(echo "$issue_is_in_project"|cut -d';' -f1)
        echo \
        "Issue ${issue} already added to project '$project' column '$issue_column' (try moving instead of adding it)"
        return 0
    fi

    # Find out cards endpoint for a project's first column
    local cards_url="$(github_api "$columns_url" |\
            jq -r '.[0].cards_url')"

    [ -z "$cards_url" ] && die "cannot determine cards URL for project '$project'"

    # Add a card
    local ret
    { github_api "$cards_url" -F content_id="$issue_id" -f content_type="Issue" >/dev/null; ret=$?; } || true

    [ "$ret" -eq 0 ] || die "Failed to add issue ${issue} to project $project_type '$project'"

    echo "Added issue ${issue} to project $project_type '$project'"
}

move_issue_project_column()
{
    local issue="${1:-}"
    local project="${2:-}"
    local project_type="${3:-}"
    local project_column="${4:-}"

    [ -z "$issue" ] && die "need issue"
    [ -z "$project" ] && die "need project"
    [ -z "$project_type" ] && die "need project type"
    [ -z "$project_column" ] && die "need project column name"

    local project_columns=$(list_project_columns "$project" "$project_type")

    # Issues are implicity repo-level entities
    local issue_id="$(github_api "repos/{owner}/{repo}/issues/${issue}" |\
            jq -r '.id')"
    [ -z "$issue_id" ] && die "cannot determine issue id for issue $issue"

    local project_url
    project_url=$(get_project_url_from_type "$project_type")
    [ -z "$project_url" ] && die "cannot determine project URL"

    # Find the project by name
    local columns_url
    columns_url=$(get_project_columns_url "$project" "$project_url")
    [ -z "$columns_url" ] && die "cannot determine column URL for project '$project'"

    local issue_in_project=$(issue_is_in_project "$issue" "$project")

    [ -z "$issue_in_project" ] && \
        die "issue $issue not in project (add it first)"

    local existing_column=$(echo "$issue_in_project"|cut -d';' -f1)

    [ "$existing_column" = "$project_column" ] && \
        echo "issue already in column '$project_column'" && \
        return 0

    local card_id=$(echo "$issue_in_project"|cut -d';' -f2)
    [ -z "$card_id" ] && \
        die "cannot determine cards ID for project '$project' column $project_column"

    local new_column_id=$(list_project_columns "$project" "$project_type" |\
        grep ";${project_column}$" |\
        cut -d';' -f3 || true)

    [ -z "$new_column_id" ] && die "cannot determine column ID for column '$project_column'"

    # Move the card
    local move_url="/projects/columns/cards/${card_id}/moves"

    local ret
    { github_api "$move_url" \
        -F column_id="$new_column_id" \
        -F position="top"; \
        ret=$?; } || true

    [ "$ret" -eq 0 ] || die "Failed to move issue ${issue} to project $project_type '$project' column '$project_column'"

    echo "Moved issue $issue to column $project_column in project $project_type '$project'"
}

list_projects()
{
    local project_type="${1:-}"

    [ -z "$project_type" ] && die "need project type"

    printf "# %s type projects\n\n" "$project_type"

    local project_url=$(get_project_url_from_type "$project_type")

    local fields

    github_api "$project_url" | jq -r '.[] |
        [.name, .html_url] |
        join ("|")' |\
    while read fields
    do
        local project_name=$(echo "$fields"|cut -d'|' -f1)
        local project_url=$(echo "$fields"|cut -d'|' -f2)

        printf "\"%s\" %s\n" "$project_name" "$project_url"
    done | sort -k1,1

    echo
}

list_milestones()
{
    local fields

    github_api -XGET "/repos/{owner}/{repo}/milestones" |\
        jq -r '.[] |
        [.title, .html_url, .open_issues, .closed_issues] |
        join ("|")' |\
    while read fields
    do
        local milestone_title=$(echo "$fields"|cut -d'|' -f1)
        local milestone_url=$(echo "$fields"|cut -d'|' -f2)
        local open_issues=$(echo "$fields"|cut -d'|' -f3)
        local closed_issues=$(echo "$fields"|cut -d'|' -f4)

        printf "\"%s\" %s %s %s\n" \
            "$milestone_title" \
            "$milestone_url" \
            "$open_issues" \
            "$closed_issues"
    done | sort -k1,1

    echo
}

raw_github_query()
{
    local query="${1:-}"

    [ -z "$query" ] && die "need query"

    curl -sL "https://api.github.com/search/issues?q=${query}"
}

list_issue_linked_prs()
{
    local repo=$(get_repo_slug)
    local query="repo:${repo}+is:pr+is:open+linked:issue"

    echo "# PRs with linked issues"
    echo "#"
    echo "# Fields: pr-url;issue-url"

    local line

    raw_github_query "$query" | jq -r '.items[] |
            [ .url, .html_url] |
            join("|")' | sort -n | while read line
    do
            local issue_api_url=$(echo "$line"|cut -d'|' -f1)
            local pr_url=$(echo "$line"|cut -d'|' -f2)

            local issue_url=$(github_api_url_to_html_url "$issue_api_url")

            printf "%s;%s\n" "$pr_url" "$issue_url"
    done
}

list_pr_linked_issues()
{
    local repo=$(get_repo_slug)
    local query="repo:${repo}+is:issue+is:open+linked:pr"

    echo "# Issues with linked PRs"
    echo "#"
    echo "# Fields: issue-url"

    raw_github_query "$query" | jq -r '.items[].html_url' | sort -n
}

setup()
{
    for cmd in hub jq
    do
        command -v "$cmd" &>/dev/null || die "need command: $cmd"
    done
}

handle_args()
{
    setup

    local cmd="${1:-}"

    case "$cmd" in
        add-issue) ;;
        help|-h|--help|usage) usage && exit 0 ;;
        list-columns) ;;
        list-issue-linked-prs) ;;
        list-issue-projects) ;;
        list-issues) ;;
        list-milestones) ;;
        list-pr-linked-issues) ;;
        list-projects) ;;
        move-issue) ;;

        "") usage && exit 0 ;;
        *) die "invalid command: '$cmd'" ;;
    esac

    # Consume the command name
    shift

    local issue=""
    local project=""
    local project_type=""
    local project_column=""

    case "$cmd" in
        add-issue)
            issue="${1:-}"
            project="${2:-}"
            project_type="${3:-}"

            # Default to repo-level project
            [ -z "$project_type" ] && project_type="repo"

            add_issue_to_project "$issue" "$project" "$project_type"
            ;;

        list-columns)
            project="${1:-}"
            project_type="${2:-}"

            list_project_columns "$project" "$project_type"
            ;;

        list-issue-linked-prs) list_issue_linked_prs ;;

        list-issue-projects)
            issue="${1:-}"

            list_projects_for_issue "$issue"
            ;;

        list-issues)
            project="${1:-}"
            project_type="${2:-}"

            list_issues_in_project "$project" "$project_type"
            ;;

        list-milestones) list_milestones ;;

        list-pr-linked-issues) list_pr_linked_issues ;;

        list-projects)
            project_type="${1:-}"

            list_projects "$project_type"
            ;;

        move-issue)
            issue="${1:-}"
            project="${2:-}"
            project_type="${3:-}"
            project_column="${4:-}"

            move_issue_project_column \
                "$issue" \
                "$project" \
                "$project_type" \
                "$project_column"
            ;;

        *) die "impossible situation: cmd: '$cmd'" ;;
    esac

    exit 0
}

main()
{
    handle_args "$@"
}

main "$@"
