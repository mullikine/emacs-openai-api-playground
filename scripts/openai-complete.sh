#!/bin/bash
export TTY

# TODO Implement LM_COMPLETE_CACHE

sn="$(basename "$0")"

yq() {
    command yq "$@" 2>/dev/null
}

stdin_exists() {
    ! [ -t 0 ] && ! test "$(readlink /proc/$$/fd/0)" = /dev/null
}

get_stop_sequences() {
    yq -r "(.\"stop-sequences\"[] |= @base64) .\"stop-sequences\"[] // empty" |
        wrlp -E "base64 -d | uq | qne"
}

# exec 3>&2

# Keep at top
oargs=("$@")

while [ $# -gt 0 ]; do opt="$1"; case "$opt" in
    "") { shift; }; ;;
    -cmode) {
        # This will create a readline REPL
        USE_CONVERSATION_MODE=y
        shift
    }
    ;;

    -nc) {
        NOCACHE=y
        shift
    }
    ;;

    -pp) {
        PRETTY_PRINT=y
        shift
    }
    ;;

    -s) {
        silence=y
        # exec 2>/dev/null
        shift
    }
    ;;

    *) break;
esac; done

export PRETTY_PRINT

# set -xv

: "${NOCACHE:="n"}"

if ! test "$sn" = lm-complete; then
    prompt_fp="$sn"
    prompt_fp="$(p "$prompt_fp" | sed 's/^oai-//')"
elif test -n "$1"; then
    prompt_fp="$1"
    shift
fi

if stdin_exists; then
    # The stdin can be the first argument
    set -- "$@" "$(cat | pen-chomp)"
fi

if ! pl "$prompt_fp" | grep -q -P '\.prompt$'; then
    prompt_fp="${prompt_fp}.prompt"
fi

if ! test -f "$prompt_fp"; then
    if test -f "$MYGIT/semiosis/prompts/prompts/$prompt_fp"; then
        cd "$MYGIT/semiosis/prompts/prompts/"
    fi
fi

test -f "$prompt_fp" || exit

# set -f; IFS='|' data=($(curl '......' | jq -r '.data |
#     map([.absoluteNumber, .airedEpisodeNumber, .episodeName, .overview] |
#     join("|")) | join("\n")')); set +f

# https://stackoverflow.com/questions/44111831/bash-read-multi-line-string-into-multiple-variables

# Can only be a single character, so use something rare
delim="¬"
IFS="$delim" read -r -d$'\1' prompt rlprompt conversation_mode repeater first_stop_sequence haspreprocessors temperature engine preferred_openai_engine max_tokens top_p postprocessor prettifier < <(
cat "$prompt_fp" | yq -r '[.prompt,.rlprompt,."conversation-mode",.repeater,."stop-sequences"[0],.preprocessors[0],.temperature,.engine,."preferred-openai-engine",."max-tokens",."top-p",.postprocessor,.prettifier] | join("'$delim'")')

inputargpos="$(( $# + 1 ))"
repeater="$(p "$repeater" | sed "s/{}/<${inputargpos}>/g")"

if test "$conversation_mode" = "true"; then
    # Turn this into a normal prompt by joining the repeater with the main prompt
    prompt+="$repeater"
fi

haspreprocessors="$(printf -- "%s" "$haspreprocessors" | sed -z 's/^\n$//')"
postprocessor="$(printf -- "%s" "$postprocessor" | sed -z 's/^\n$//')"
prettifier="$(printf -- "%s" "$prettifier" | sed -z 's/^\n$//')"

if test "$engine" = myrc; then
    engine="$(myrc .default_openai_api_engine)"
fi

# The preprocessors must be loaded into memory, not simply used because the conversation-mode input may need preprocessing
if test -n "$haspreprocessors"; then
    # yq -r "(.preprocessors[] |= @base64) .preprocessors[] // empty" | awk1
    # | wrlp -E "base64-decode-string"

    # readarray is bash 4
    readarray -t pps < <(cat "$prompt_fp" | yq -r "(.preprocessors[] |= @base64) .preprocessors[] // empty" | awk1)

    # This is slow. I should use a different language
    eval "set -- $(
    i=1
    for pp in "${pps[@]}"
    do
        pp="$(printf -- "%s" "$pp" | base64-decode-string)"
        echo "$pp" | hls blue 1>&2

        eval val="\$$i"

        if ! test "$pp" = "null"; then
            val="$(printf -- "%s" "$val" | eval "$pp")"
        fi

        printf "'%s' " "$(printf %s "$val" | sed "s/'/'\\\\''/g")";
        i="$((i + 1))"
    done | sed 's/ $//'
    )"
fi

: "${engine:="$(myrc .default_openai_api_engine)"}"

: "${preferred_openai_engine:="davinci"}"
: "${engine:="$preferred_openai_engine"}"
: "${engine:="davinci"}"

# This is OK now because I have 'myeval'
first_stop_sequence="$(printf -- "%s" "$first_stop_sequence" | qne)"

# prompt="$(cat "$prompt_fp" | yq -r ".prompt // empty")"
# # stop_sequence="$(cat "$prompt_fp" | yq ".\"stop-sequences\"[0] // empty" | uq | qne)"
stop_sequences="$(cat "$prompt_fp" | get_stop_sequences 2>/dev/null)"
# temperature="$(cat "$prompt_fp" | yq -r ".\"temperature\" // empty")"
# engine="$(cat "$prompt_fp" | yq -r ".\"engine\" // empty")"
# max_tokens="$(cat "$prompt_fp" | yq -r ".\"max-tokens\" // empty")"
# top_p="$(cat "$prompt_fp" | yq -r ".\"top-p\" // empty")"

test -n "$prompt" || exit 0

while [ $# -gt 0 ]; do opt="$1"; case "$opt" in
    "") { shift; }; ;;
    -e) {
        engine="$2"
        shift
        shift
    }
;;

*) break;
esac; done

: "${engine:="ada"}"
: "${temperature:="0.6"}"
: "${max_tokens:="64"}"

: "${sub_completions:="1"}"


ogprompt="$prompt"

prompt_prompt_fp="$(printf -- "%s" "$prompt" | pen-chomp | tf)"

if test "$USE_CONVERSATION_MODE" = "y"; then
    i=1
    for var in "$@"
    do
        # Ensure that nothing is chomped from the arguments
        printf -- "%s" "${var}" | uq -f | IFS= read -r -d '' var
        rlprompt="$(p "$rlprompt" | template -$i "$var")"

        # cmd-nice template -$i "$var"
        ((i++))
    done
fi

repl_run() {

    # Choose to reset after each entry.
    # I should do this by default because of the prompt size.
    # It can't grow beyond a particular length.
    prompt="$ogprompt"

    i=1
    for var in "$@"
    do
        # Ensure that nothing is chomped from the arguments
        printf -- "%s" "${var}" | uq -f | IFS= read -r -d '' var
        prompt="$(p "$prompt" | template -$i "$var")"

        # cmd-nice template -$i "$var"
        ((i++))
    done

    printf -- "%s" "$prompt" | pen-chomp > "$prompt_prompt_fp"

    gen_pos="$(grep "<:pp>" --byte-offset "$prompt_prompt_fp" | cut -d : -f 1)"
    sed -i 's/<:pp>//' "$prompt_prompt_fp"

    # printf -- "%s\n" "$prompt" | tv

    # prompt="$(p "$prompt" | bs '$!' | qne)"

    # qne will break emojis
    # emojis work again

    # Do not escape whitespace for openai api command
    # It's evalled in this bash script. So I'm escaping for that
    # | qne. It breaks unicode
    # can't use unq
    prompt="$(cat "$prompt_prompt_fp" | bs '$`"!')"
    # prompt="$(p "$prompt" | bs '$`"' | sed -z 's/\n/\\n/g')"

    # exit 1

    ## #  Can't cache at this level
    ## * TODO Fix 'ci'. It's breaking lm-complete because it's transforming the '\n' --stop
    ## $SCRIPTS/ci
    ## =cmd-nice= will turn a newline into "\n"
    ## =cmd= will remove the newline entirely
    # myeval
    IFS= read -r -d '' SHCODE <<HEREDOC
openai api \
    completions.create \
    -e "$engine" \
    -t "$temperature" \
    -M "$max_tokens" \
    -n "$sub_completions" \
    $(
        if test -n "$first_stop_sequence"; then
            # printf -- "%s" " --stop $(aqf "$first_stop_sequence")"

            # The newline must go in verbatim, which means it needs
            # to be interpreted in the printf
            # printf -- " --stop \"$first_stop_sequence\""

            printf -- "%s" " --stop $(aqf "$first_stop_sequence")"

            # eval "$(cmd printf -- "%s" " --stop \"$first_stop_sequence\"")"

            # multiple doesn't work

            # printf -- "%s$delim" "$first_stop_sequence" | while IFS="$delim" read -r line; do
                # printf -- "%s" " --stop $(aqf "$line")"
            # done
        fi
    ) \
    -p "$prompt"
HEREDOC

    shfp="$(printf -- "%s\n" "$SHCODE" | sed -z 's/\n\+$//' | sed -z "s/\\n/\\\n/g" | tf sh)"

    # printf -- "%s\n" "$SHCODE" | tv
    # exit 1

    export UPDATE=y

    # response_fp="$(eval "$SHCODE" | uq | s pen-chomp | tf txt)"

    response_fp="$(sh "$shfp" | uq | s pen-chomp | tf txt)"

    # Only record the history if the command actually queried the API
    ( hs "$(basename "$0")" "${oargs[@]}" "#" "<==" "$(ps -o comm= $PPID)" 0</dev/null ) &>/dev/null

    prompt_bytes="$(cat "$prompt_prompt_fp" | wc -c)"
    response_bytes="$(cat "$response_fp" | wc -c)"

    # it may not be a good idea to remove starting whitespace if I want to complete in emacs
    # tail -c +$((prompt_bytes + 1)) "$response_fp" | sed -z 's/^\s\+//;s/^\r\+//;s/^\n\+//'
    # tail -c +$((prompt_bytes + 1)) "$response_fp" | sed -z 's/^\r\+//;s/^\n\+//'
    # Don't remove whitespace at all

    : "${gen_pos:="$((prompt_bytes + 1))"}"

    seddelim=%
    IFS= read -r -d '' stop_sequence_trimmer <<HEREDOC
$(
    printf -- "%s\n" "$stop_sequences" | while IFS=$'\n' read -r s; do
        printf -- "%s" "sed -z 's${seddelim}${s}.*${seddelim}${seddelim}' |"
    done
)
cat
HEREDOC

    # printf -- "%s\n" "$stop_sequence_trimmer" | tv &>/dev/null

    cat "$response_fp" | hc "$(basename "$0")-response" "${oargs[@]}" "#" "<==" "$(ps -o comm= $PPID)" &>/dev/null

    tail -c +$gen_pos "$response_fp" | {
        # This will get slow
        # I should be working in clojure or racket I think

        if ( exec 0</dev/null; cat "$prompt_fp" | yq-test chomp-start; ); then
            # exec 0</dev/null ns hi
            sed -z 's/^\n\+//' | sed -z 's/^\s\+//'
        else
            cat
        fi |
            if ( exec 0</dev/null; cat "$prompt_fp" | yq-test chomp-end; ); then
                sed -z 's/\n\+$//' | sed -z 's/\s\+$//'
            else
                cat
            fi | {
                eval "$stop_sequence_trimmer"
            } | {
                if test -n "$postprocessor"; then
                    # echo "'$postprocessor'" | hls green 1>&2
                    eval "$postprocessor"
                else
                    cat
                fi
            } |
                if test "$PRETTY_PRINT" = y && test -n "$prettifier"; then
                    # echo "'$prettifier'" | hls green 1>&2
                    eval "$prettifier"
                else
                    cat
                fi
    }

    return 0
}

# echo "$@"
# exit

if test "$USE_CONVERSATION_MODE" = y && test "$conversation_mode" = "true"; then
    inputargpos="$(( $# + 1 ))"

    echo -n "$rlprompt> " | hls red 1>&2
    while IFS=$'\n' read -r line; do
        out="$(repl_run "$@" "$line" | awk 1)"
        printf -- "%s\n" "$out"

        prompt+="$out\n$first_stop_sequence\n"
        prompt+="$repeater"
        echo -n "$rlprompt> " | hls red 1>&2
    done
else
    repl_run "$@" | hc "$(basename "$0")" "${oargs[@]}" "#" "<==" "$(ps -o comm= $PPID)" | {
        # exec 3>&2
        pavs
    }
fi

# echo "$prompt_fp"
# echo "$response_fp"

# pl "$SHCODE" | pavs