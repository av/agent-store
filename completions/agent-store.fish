# fish completion for agent-store
#
# Install: copy this file to ~/.config/fish/completions/agent-store.fish

# Erase any previously loaded completions for this command.
complete -c agent-store -e

set -l seen_no_sub "not __fish_seen_subcommand_from init create cr find ls get set unset rm link unlink links ctx context hook"

# Global options
complete -c agent-store -l json -d 'Print structured JSON for command output'
complete -c agent-store -s h -l help -d 'Print help'
complete -c agent-store -s V -l version -d 'Print version'

# Subcommands
complete -c agent-store -f -n $seen_no_sub -a init -d 'Initialize a project-local store'
complete -c agent-store -f -n $seen_no_sub -a create -d 'Create a record'
complete -c agent-store -f -n $seen_no_sub -a cr -d 'Create a record (alias)'
complete -c agent-store -f -n $seen_no_sub -a find -d 'Find records by query'
complete -c agent-store -f -n $seen_no_sub -a ls -d 'Find records by query (alias)'
complete -c agent-store -f -n $seen_no_sub -a get -d 'Print a record by ID'
complete -c agent-store -f -n $seen_no_sub -a set -d 'Update fields on a record by ID'
complete -c agent-store -f -n $seen_no_sub -a unset -d 'Remove fields from a record by ID'
complete -c agent-store -f -n $seen_no_sub -a rm -d 'Delete a record by ID'
complete -c agent-store -f -n $seen_no_sub -a link -d 'Create a directional link between records'
complete -c agent-store -f -n $seen_no_sub -a unlink -d 'Remove a directional link between records'
complete -c agent-store -f -n $seen_no_sub -a links -d 'Print incoming and outgoing links for a record'
complete -c agent-store -f -n $seen_no_sub -a ctx -d 'Print a compact Quick Context summary'
complete -c agent-store -f -n $seen_no_sub -a context -d 'Print a compact Quick Context summary (alias)'
complete -c agent-store -f -n $seen_no_sub -a hook -d 'Manage stored hooks'

# create / cr
complete -c agent-store -f -n '__fish_seen_subcommand_from create cr' -l stdin -d 'Bulk-import JSONL from stdin'

# find / ls
complete -c agent-store -f -n '__fish_seen_subcommand_from find ls' -l timestamps -d 'Append created_at and updated_at to each line'
complete -c agent-store -x -n '__fish_seen_subcommand_from find ls' -l sort -a 'created_at updated_at kind id' -d 'Sort by a field'
complete -c agent-store -f -n '__fish_seen_subcommand_from find ls' -l desc -d 'Reverse the listing order'
complete -c agent-store -x -n '__fish_seen_subcommand_from find ls' -l limit -d 'Output at most N records'
complete -c agent-store -f -n '__fish_seen_subcommand_from find ls' -l count -d 'Print only the number of matching records'

# get
complete -c agent-store -f -n '__fish_seen_subcommand_from get' -l timestamps -d 'Append created_at and updated_at'

# hook subcommands
set -l hook_no_sub '__fish_seen_subcommand_from hook; and not __fish_seen_subcommand_from add ls rm runs'
complete -c agent-store -f -n $hook_no_sub -a add -d 'Add a hook'
complete -c agent-store -f -n $hook_no_sub -a ls -d 'List hooks'
complete -c agent-store -f -n $hook_no_sub -a rm -d 'Remove a hook by ID'
complete -c agent-store -f -n $hook_no_sub -a runs -d 'List recent hook runs'

# hook add <event>
complete -c agent-store -f -n '__fish_seen_subcommand_from hook; and __fish_seen_subcommand_from add' \
    -a 'create set unset rm link unlink' -d 'Hook event'

# hook runs
complete -c agent-store -x -n '__fish_seen_subcommand_from hook; and __fish_seen_subcommand_from runs' \
    -l limit -d 'List at most N runs'
