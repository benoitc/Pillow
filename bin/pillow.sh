#! /bin/sh -e

# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy of
# the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations under
# the License.

BACKGROUND=false
DEFAULT_CONFIG_DIR=/usr/local/etc/pillow/default.d
DEFAULT_CONFIG_FILE=/usr/local/etc/pillow/default.ini
HEART_BEAT_TIMEOUT=11
HEART_COMMAND="/usr/local/bin/pillow -k"
INTERACTIVE=false
KILL=false
LOCAL_CONFIG_DIR=/usr/local/etc/pillow/local.d
LOCAL_CONFIG_FILE=/usr/local/etc/pillow/local.ini
PID_FILE=/usr/local/var/run/pillow/pillow.pid
RECURSED=false
RESET_CONFIG=true
RESPAWN_TIMEOUT=0
SCRIPT_ERROR=1
SCRIPT_OK=0
SHUTDOWN=false
STDERR_FILE=pillow.stderr
STDOUT_FILE=pillow.stdout

print_arguments=""
start_arguments=""
background_start_arguments=""

basename=`basename $0`

display_version () {
    cat << EOF
$basename - Pillow 0.3

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

EOF
}

display_help () {
    cat << EOF
Usage: $basename [OPTION]

The $basename command runs the Pillow server.

Erlang inherits the environment of this command.

The exit status is 0 for success or 1 for failure.

The \`-s' option will exit 0 for running and 1 for not running.

Options:

  -h          display a short help message and exit
  -V          display version information and exit
  -a FILE     add configuration FILE to chain
  -A DIR      add configuration DIR to chain
  -n          reset configuration file chain (including system default)
  -c          print configuration file chain and exit
  -i          use the interactive Erlang shell
  -b          spawn as a background process
  -p FILE     set the background PID FILE (overrides system default)
  -r SECONDS  respawn background process after SECONDS (defaults to no respawn)
  -o FILE     redirect background stdout to FILE (defaults to $STDOUT_FILE)
  -e FILE     redirect background stderr to FILE (defaults to $STDERR_FILE)
  -s          display the status of the background process
  -m          multiply database nodes by resharding
  -f          flip to use the new database nodes directly
  -F          reshard and flip to the new databases
  -k          kill the background process, will respawn if needed
  -d          shutdown the background process

Report bugs at <http://github.com/khellan/pillow/issues>.
EOF
}

display_error () {
    if test -n "$1"; then
        echo $1 >&2
    fi
    echo >&2
    echo "Try \`"$basename" -h' for more information." >&2
    false
}

_get_pid () {
    if test -f $PID_FILE; then
        PID=`cat $PID_FILE`
    fi
    echo $PID
}

_add_config_file () {
    if test -z "$print_arguments"; then
        print_arguments="$1"
    else
        print_arguments="`cat <<EOF
$print_arguments
$1
EOF
`"
    fi
    start_arguments="$start_arguments $1"
    background_start_arguments="$background_start_arguments -a $1"
}

_add_config_dir () {
    for file in `find "$1" -mindepth 1 -maxdepth 1 -type f -name '*.ini'`; do
        _add_config_file $file
    done
}

_load_config () {
    _add_config_file "$DEFAULT_CONFIG_FILE"
    _add_config_dir "$DEFAULT_CONFIG_DIR"
    _add_config_file "$LOCAL_CONFIG_FILE"
    _add_config_dir "$LOCAL_CONFIG_DIR"
}

_reset_config () {
    print_arguments=""
    start_arguments=""
    background_start_arguments="-n"
}

_print_config () {
    cat <<EOF
$print_arguments
EOF
}

check_status () {
    PID=`_get_pid`
    if test -n "$PID"; then
        if kill -0 $PID 2> /dev/null; then
            echo "Pillow is running as process $PID, get comfy."
            return $SCRIPT_OK
        else
            echo >&2 << EOF
Pillow is not running but a stale PID file exists: $PID_FILE"
EOF
        fi
    else
        echo "Pillow is not running." >&2
    fi
    return $SCRIPT_ERROR
}

check_environment () {
    if test "$BACKGROUND" != "true"; then
        return
    fi
    touch $PID_FILE 2> /dev/null || true
    touch $STDOUT_FILE 2> /dev/null || true
    touch $STDERR_FILE 2> /dev/null || true
    message_prefix="Pillow needs write permission on the"
    if test ! -w $PID_FILE; then
        echo "$message_prefix PID file: $PID_FILE" >&2
        false
    fi
    if test ! -w $STDOUT_FILE; then
        echo "$message_prefix STDOUT file: $STDOUT_FILE" >&2
        false
    fi
    if test ! -w $STDERR_FILE; then
        echo "$message_prefix STDERR file: $STDERR_FILE" >&2
        false
    fi
    message_prefix="Pillow needs a regular"
    if test `echo 2> /dev/null >> $PID_FILE; echo $?` -gt 0; then
        echo "$message_prefix PID file: $PID_FILE" >&2
        false
    fi
    if test `echo 2> /dev/null >> $STDOUT_FILE; echo $?` -gt 0; then
        echo "$message_prefix STDOUT file: $STDOUT_FILE" >&2
        false
    fi
    if test `echo 2> /dev/null >> $STDERR_FILE; echo $?` -gt 0; then
        echo "$message_prefix STDERR file: $STDERR_FILE" >&2
        false
    fi
}

start_pillow () {
    if test ! "$RECURSED" = "true"; then
        if check_status 2> /dev/null; then
            exit
        fi
        check_environment
    fi
    interactive_option="+Bd -noinput"
    if test "$INTERACTIVE" = "true"; then
        interactive_option=""
    fi
    if test "$BACKGROUND" = "true"; then
        touch $PID_FILE
        interactive_option="+Bd -noinput"
    fi
    command="/usr/bin/erl -sname pillow $interactive_option -boot start_sasl +K true \
        -pa PILLOW_LIBRARIES -pillow_ini $start_arguments -s pillow"
    if test "$BACKGROUND" = "true" -a "$RECURSED" = "false"; then
        $0 $background_start_arguments -b -r $RESPAWN_TIMEOUT -p $PID_FILE \
            -o $STDOUT_FILE -e $STDERR_FILE -R &
        echo "Pillow has started, get comfy."
    else
        if test "$RECURSED" = "true"; then
            while true; do
                export HEART_COMMAND
                export HEART_BEAT_TIMEOUT
                `eval $command -pidfile $PID_FILE -heart \
                    >> $STDOUT_FILE 2>> $STDERR_FILE` || true
                PID=`_get_pid`
                if test -n "$PID"; then
                    if kill -0 $PID 2> /dev/null; then
                        return $SCRIPT_ERROR
                    fi
                else
                    return $SCRIPT_OK
                fi
                if test "$RESPAWN_TIMEOUT" = "0"; then
                    return $SCRIPT_OK
                fi
                if test "$RESPAWN_TIMEOUT" != "1"; then
                    plural_ending="s"
                fi
                cat << EOF
Pillow crashed, restarting in $RESPAWN_TIMEOUT second$plural_ending.
EOF
                sleep $RESPAWN_TIMEOUT
            done
        else
            eval exec $command
        fi
    fi
}

stop_pillow () {
    PID=`_get_pid`
    if test -n "$PID"; then
        if test "$1" = "false"; then
            echo > $PID_FILE
        fi
        if kill -0 $PID 2> /dev/null; then
            if kill -1 $PID 2> /dev/null; then
                if test "$1" = "false"; then
                    echo "Pillow has been shutdown."
                else
                    echo "Pillow has been killed."
                fi
                return $SCRIPT_OK
            else
                echo "Pillow could not be killed." >&2
                return $SCRIPT_ERROR
            fi
            if test "$1" = "false"; then
                echo "Stale PID file exists but Pillow is not running."
            else
                echo "Stale PID file existed but Pillow is not running."
            fi
        fi
    else
        echo "Pillow is not running."
    fi
}

remote_command() {
    rpc_command=$1
    remote_shell="erl -sname pillow1 -remsh pillow@localhost"
    echo "${rpc_command}" | ${remote_shell}
}

reshard() {
    remote_command "rpc:call(pillow@localhost, pillow, reshard, [])."
}

flip() {
    remote_command "rpc:call(pillow@localhost, pillow, flip, [])."    
}

reshard_and_flip() {
    remote_command "rpc:call(pillow@localhost, pillow, reshard_and_flip, [])."
}

parse_script_option_list () {
    _load_config
    set +e
    options=`getopt hVa:A:ncibp:r:Ro:e:smfFkd $@`
    if test ! $? -eq 0; then
        display_error
    fi
    set -e
    eval set -- $options
    while [ $# -gt 0 ]; do
        case "$1" in
            -h) shift; display_help; exit;;
            -V) shift; display_version; exit;;
            -a) shift; _add_config_file "$1"; shift;;
            -A) shift; _add_config_dir "$1"; shift;;
            -n) shift; _reset_config;;
            -c) shift; _print_config; exit;;
            -i) shift; INTERACTIVE=true;;
            -b) shift; BACKGROUND=true;;
            -r) shift; RESPAWN_TIMEOUT=$1; shift;;
            -R) shift; RECURSED=true;;
            -p) shift; PID_FILE=$1; shift;;
            -o) shift; STDOUT_FILE=$1; shift;;
            -e) shift; STDERR_FILE=$1; shift;;
            -s) shift; check_status; exit;;
            -m) shift; reshard; exit;;
            -f) shift; flip; exit;;
            -F) shift; reshard_and_flip; exit;;
            -k) shift; KILL=true;;
            -d) shift; SHUTDOWN=true;;
            --) shift; break;;
            *) display_error "Unknown option: $1" >&2;;
        esac
    done
    if test "$KILL" = "true" -o "$SHUTDOWN" = "true"; then
        stop_pillow $KILL
    else
        start_pillow
    fi
}

parse_script_option_list $@
