if [ $TERM != "screen-256color" ] && [  $TERM != "screen" ]; then
	if which tmux &>/dev/null; then
		TERM=xterm-256color exec zsh -c 'tmux attach || tmux new'
	else
		alias vi='vim'
	fi
else
  # tmux is running, define tmux-specific utilities
  tmw() {
    tmux split-window -dh "$*"
  }

  ssh() {
		# TODO match the host against a list of hosts known to be running tmux
		tmux set status off
		tmux set prefix ^o
		ssh-add -l || ssh-add && { command ssh "$@" }
		tmux set -u prefix
		tmux set -u status
  }

	# unregister from the shm server
	_shm_unregister() {
    local socket_path="/tmp/tmux-zsh-vim-shm/socket"
		if zsocket $socket_path > /dev/null 2>&1; then
      echo "EXIT|||$_shm_client_id" >&$REPLY
			exec {REPLY}>&-
		fi
	}

	# register to the shm server
	_shm_register() {
		local REPLY=
		local tmux_vim_socket_dir="/tmp/tmux-zsh-vim-shm"
    local socket_path="$tmux_vim_socket_dir/socket"
		# ensure the shared memory daemon is running:
		# - try to acquire the daemon lock, if succeeds:
		#	  - start a subshell
		#   - replace the subshell with a new, disowned shell
		#   - the new shell invokes start_shared_memory to finish
		#     the daemonization process and do the rest of the job
		if mkdir "$tmux_vim_socket_dir" > /dev/null 2>&1; then
			(
			exec zsh "$ZDOTDIR/tmux.d/shm_daemon.zsh" $tmux_vim_socket_dir &!
			)
		fi
		# now try to connect with the daemon, up to 5 times, increasing the poll
		# interval with each iteration
		local interval=
		for i in 1 2 3 4 5; do
			if zsocket $socket_path > /dev/null 2>&1; then
				break
			fi
			interval=$((i * 0.5))
			sleep $interval
		done
		if [ -z $REPLY ]; then
			echo "Error registering with the shared memory daemon" >&2
			local daemon_pid=
			if [ -r "$tmux_vim_socket_dir/pid" ]; then
				daemon_pid=`cat "$tmux_vim_socket_dir/pid"`
			fi
			if [ -z $daemon_pid ] || ! ps -p $daemon_pid; then
				local msg=
				msg=(
				"The process pointed by the daemon pid was"
				"not running, will delete the directory"
				"'$tmux_vim_socket_dir'"
				)
				echo "$msg" >&2
				rm -rf "$tmux_vim_socket_dir"
			fi
			return 1
		fi
		_shm_client_id=`uuidgen`
		echo "ENTER|||$_shm_client_id" >&$REPLY
		exec {REPLY}>&-
	}

	source "$ZDOTDIR/tmux.d/common.zsh"

  vi() {
    local sid=`tmux display-message -p '#S'`
    # Get session/window ids
    # Lets see if we are in a project
    local dir="`pwd`"
    local vim_id_pattern=""
    while [ -n "$dir" ] ; do
			# Only work with svn 1.7 +
      [[ -d "$dir/.git" ||\
        -d "$dir/.svn" ||\
        -d "$dir/.hg"  ||\
        -d "$dir/.bzr" ]] && break
      # go up one level
      dir=${dir%/*}
    done
    # vim servernames are case-insensitive, so we cant use directory
		# names as parts of the servername(it would generate ambiguities
		# with names which differ only in case), so each directory/sid 
		# pair is mapped to a unique id, which will be used as servername
		#
		# since the directory->uuid mapping is global(not specific to a
		# zsh instance) the data will be stored in the shared memory
		# daemon, which will also synchronize access to the data.
		local default=`uuidgen`
		# convert to uppercase since thats how vim display the servers
		default=${default:u}
		# append the session id to the key, because vim instances are
		# session-specific
		local dir_id=`_shm_get "$dir:$sid" $default`
    vim_id_pattern=":${dir_id}:"
    local vim_id=`vim --serverlist | grep -F "$vim_id_pattern"`
    if [ -z $vim_id ]; then
      # vim is not running, so start a new instance 
      #
      # Before we can send commands to the new instance, it must be fully
      # started, so we need to syncronize the startup with this function using a
      # unique named pipe, which will also allow us to get the new pane id
      local fifo="/tmp/tmux-vim-pane-$RANDOM"
      while ! mkfifo $fifo > /dev/null 2>&1; do
        fifo="/tmp/tmux-vim-pane-$RANDOM"
      done
      # g:project_dir can be used by vim scripts that need to know the project
      # root directory
      tmux split-window -d -p 70 "vim \
				-c \"cd $dir\" \
        -c \"let g:project_dir='$dir'\" \
        -c vim -c ':silent !echo \$TMUX_PANE >> $fifo'\
				--servername \":$dir_id:\${TMUX_PANE#*\%}\""
      local pane_id=`cat $fifo`
      # will only get here after vim has started
      pane_id=${pane_id#*\%}
			rm $fifo
      vim_id=":$dir_id:$pane_id"
			# now we associate the two panes in shared memory, so we can more easily
			# break/join them toguether
			_shm_set "$pane_id" "${TMUX_PANE#*\%}:bottom"
			_shm_set "${TMUX_PANE#*\%}" "${pane_id}:top"
    fi
    # open all files
    vim --servername "$vim_id" --remote-send "<ESC>"
    while [ $# -ne 0 ]; do
			vim --servername "$vim_id" --remote-send ":e ${(q)1:a}<CR>"
      shift
    done
    # extract the unique pane id from vim_id and navigate to it
		local pane_uid="%${vim_id#\:$dir_id\:}"
		local window_uid="`tmux display-message -pt \"$pane_uid\" '#{window_id}'`"
    tmux select-window -t "$window_uid"
    tmux select-pane -t "$pane_uid"
  }
	alias e=vi

	trap _shm_unregister EXIT
	_shm_register
fi