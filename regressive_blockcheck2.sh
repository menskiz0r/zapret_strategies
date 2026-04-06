#!/bin/bash
#
# Regressive multi-domain blockcheck: domain N+1 is tested only with nfqws strategies
# that succeeded on domain N (per protocol: TLS 1.2 / TLS 1.3 / QUIC).
#
# Interactive mode (default): same style as blockcheck2.sh — menus / prompts.
# Non-interactive: set BATCH=1 and the usual blockcheck env (IPVS, ENABLE_*, SCANLEVEL, …).
#
# First domain: TEST=REGRESSIVE_FIRST_TEST (default: standard), unless seed list paths are set.
# Later domains: TEST=custom with lists parsed from the previous "* SUMMARY".
#
# Optional seeds (first domain uses custom lists instead of a full scan):
#   REGRESSIVE_SEED_LIST_TLS12 / _TLS13 / _QUIC
#
# Work directory: REGRESSIVE_WORKDIR (default: ./regressive-blockcheck-work)
#
# Long domain lists: kernel TTY input is limited (~4 KiB per line); multi-line paste can
# split across prompts. Use @/path/to/file or REGRESSIVE_DOMAINS_FILE (see prompt text).
#
# Output: by default blockcheck is streamed live to the terminal, but parser logs are
# hidden temp files deleted after summary extraction. Set REGRESSIVE_SHOW_BLOCKCHECK=0 to
# silence live output. Set REGRESSIVE_KEEP_LOGS=1 to preserve visible round-<n>-<domain>.log.
# After each round and at the end, clean strategy-only files are written for copy/paste:
#   strategies-after-round-<n>-<domain>.txt
#   regressive-final-tls12.txt  regressive-final-tls13.txt  regressive-final-quic.txt
#   regressive-final-strategies.txt

EXEDIR="$(dirname "$0")"
EXEDIR="$(cd "$EXEDIR" && pwd)"
ZAPRET_BASE=${ZAPRET_BASE:-"$EXEDIR"}
ZAPRET_RW=${ZAPRET_RW:-"$ZAPRET_BASE"}
ZAPRET_CONFIG=${ZAPRET_CONFIG:-"$ZAPRET_RW/config"}
ZAPRET_CONFIG_DEFAULT="$ZAPRET_BASE/config.default"
BLOCKCHECK2D="$ZAPRET_BASE/blockcheck2.d"

CURL=${CURL:-curl}

[ -f "$ZAPRET_CONFIG" ] || {
	[ -f "$ZAPRET_CONFIG_DEFAULT" ] && {
		ZAPRET_CONFIG_DIR="$(dirname "$ZAPRET_CONFIG")"
		[ -d "$ZAPRET_CONFIG_DIR" ] || mkdir -p "$ZAPRET_CONFIG_DIR"
		cp "$ZAPRET_CONFIG_DEFAULT" "$ZAPRET_CONFIG"
	}
}
[ -f "$ZAPRET_CONFIG" ] && . "$ZAPRET_CONFIG"
. "$ZAPRET_BASE/common/base.sh"
. "$ZAPRET_BASE/common/dialog.sh"

BLOCKCHECK="$ZAPRET_BASE/blockcheck2.sh"
TEST_DEFAULT=${TEST_DEFAULT:-standard}
DOMAINS_DEFAULT=${DOMAINS_DEFAULT:-rutracker.org}
DOMAINS_FILE_DEFAULT="$EXEDIR/domains"

WORKDIR_DEF=${REGRESSIVE_WORKDIR:-"$EXEDIR/regressive-blockcheck-work"}
FIRST_TEST=${REGRESSIVE_FIRST_TEST:-standard}

# --- curl capability checks (same idea as blockcheck2.sh configure_curl_opt) ---
curl_supports_tls13()
{
	local r
	"$CURL" --tlsv1.3 -Is -o /dev/null --max-time 1 http://127.0.0.1:65535 2>/dev/null
	[ $? = 2 ] && return 1
	"$CURL" --tlsv1.3 --max-time 1 -Is -o /dev/null https://iana.org 2>/dev/null
	r=$?
	[ $r != 4 -a $r != 35 ]
}

curl_supports_tlsmax()
{
	"$CURL" --version | grep -Fq -e OpenSSL -e LibreSSL -e BoringSSL -e GnuTLS -e quictls || return 1
	"$CURL" --tls-max 1.2 -Is -o /dev/null --max-time 1 http://127.0.0.1:65535 2>/dev/null
	[ $? != 2 ]
}

curl_supports_connect_to()
{
	"$CURL" --connect-to 127.0.0.1:: -o /dev/null --max-time 1 http://127.0.0.1:65535 2>/dev/null
	[ "$?" != 2 ]
}

curl_supports_http3()
{
	"$CURL" --connect-to 127.0.0.1:: -o /dev/null --max-time 1 --http3-only http://127.0.0.1:65535 2>/dev/null
	[ "$?" != 2 ]
}

rb_configure_curl_opt()
{
	TLSMAX12=
	TLSMAX13=
	curl_supports_tlsmax && {
		TLSMAX12="--tls-max 1.2"
		TLSMAX13="--tls-max 1.3"
	}
	TLS13=
	curl_supports_tls13 && TLS13=1
	HTTP3=
	curl_supports_http3 && HTTP3=1

	HTTPS_HEAD=-I
	[ "$CURL_HTTPS_GET" = 1 ] && HTTPS_HEAD=
}

rb_exitp()
{
	local continue_prompt
	[ "$BATCH" = 1 ] || {
		echo
		echo press enter to continue
		read -r continue_prompt
	}
	exit "$1"
}

count_domains()
{
	echo "$1" | wc -w | trim
}

normalize_word_list()
{
	printf '%s' "$1" | xargs
}

default_domains_file_is_readable()
{
	[ -f "$DOMAINS_FILE_DEFAULT" ] && [ -r "$DOMAINS_FILE_DEFAULT" ]
}

load_domains_from_file()
{
	local domains_file=$1

	[ -f "$domains_file" ] && [ -r "$domains_file" ] || return 1
	grep -v '^[[:space:]]*#' "$domains_file" | xargs
}

compute_use_seed()
{
	use_seed=0
	[ -n "$REGRESSIVE_SEED_LIST_TLS12" ] && [ -s "$REGRESSIVE_SEED_LIST_TLS12" ] && use_seed=1
	[ -n "$REGRESSIVE_SEED_LIST_TLS13" ] && [ -s "$REGRESSIVE_SEED_LIST_TLS13" ] && use_seed=1
	[ -n "$REGRESSIVE_SEED_LIST_QUIC" ] && [ -s "$REGRESSIVE_SEED_LIST_QUIC" ] && use_seed=1
}

validate_domain_count_or_exitp()
{
	local domains_count

	domains_count=$(count_domains "$REGRESSIVE_DOMAINS")
	[ "$domains_count" -gt 1 ] || {
		echo "regressive mode needs at least 2 domains (or use plain blockcheck2.sh for one host)."
		rb_exitp 1
	}
}

validate_domain_count_or_exit()
{
	DOMAINS_COUNT_CHK=$(count_domains "$REGRESSIVE_DOMAINS")
	[ "$DOMAINS_COUNT_CHK" -ge 2 ] || {
		echo "regressive mode needs at least 2 domains."
		exit 1
	}
}

ensure_default_domains_file()
{
	[ -z "$REGRESSIVE_DOMAINS_FILE" ] && default_domains_file_is_readable && REGRESSIVE_DOMAINS_FILE="$DOMAINS_FILE_DEFAULT"
}

load_domains_from_configured_file_if_needed()
{
	[ -n "$REGRESSIVE_DOMAINS" ] && return 0
	ensure_default_domains_file
	[ -n "$REGRESSIVE_DOMAINS_FILE" ] || return 0
	[ -f "$REGRESSIVE_DOMAINS_FILE" ] && [ -r "$REGRESSIVE_DOMAINS_FILE" ] || return 0
	REGRESSIVE_DOMAINS=$(load_domains_from_file "$REGRESSIVE_DOMAINS_FILE")
}

resolve_prompted_domains()
{
	local domains_answer=$1
	local domains_from_file

	if [ -z "$domains_answer" ]; then
		if default_domains_file_is_readable; then
			REGRESSIVE_DOMAINS=$(load_domains_from_file "$DOMAINS_FILE_DEFAULT")
		else
			REGRESSIVE_DOMAINS=$DOMAINS_DEFAULT
		fi
		return 0
	fi

	if [ "${domains_answer#@}" != "$domains_answer" ] && [ -f "${domains_answer#@}" ] && [ -r "${domains_answer#@}" ]; then
		domains_from_file=$(load_domains_from_file "${domains_answer#@}")
		[ -n "$domains_from_file" ] || {
			echo "no domains found in ${domains_answer#@}"
			rb_exitp 1
		}
		REGRESSIVE_DOMAINS=$domains_from_file
		return 0
	fi

	REGRESSIVE_DOMAINS=$(normalize_word_list "$domains_answer")
	[ -z "$REGRESSIVE_DOMAINS" ] && REGRESSIVE_DOMAINS=$DOMAINS_DEFAULT
}

show_regressive_intro()
{
	echo
	echo NOTE ! this test should be run with zapret or any other bypass software disabled, without VPN
	echo
	echo "--- regressive blockcheck ---"
	echo "Each domain after the first is tested only with strategies that succeeded on the previous domain."
	echo
}

ensure_interactive_prereqs()
{
	curl_supports_connect_to || {
		echo "installed curl does not support --connect-to option. pls install at least curl 7.49"
		echo "current curl version:"
		"$CURL" --version
		rb_exitp 1
	}
}

prompt_domains_if_needed()
{
	local domains_answer

	load_domains_from_configured_file_if_needed
	[ -n "$REGRESSIVE_DOMAINS" ] && return 0

	echo "specify domain(s). multiple domains are space separated. URIs are supported (rutracker.org/forum/index.php)"
	echo "Long lists: use @/path/to/file (# comment lines ignored) or REGRESSIVE_DOMAINS_FILE — avoids TTY paste limits and broken multi-line paste."
	if default_domains_file_is_readable; then
		printf "domain(s) or @file (default: @%s) : " "$DOMAINS_FILE_DEFAULT"
	else
		printf "domain(s) (default: $DOMAINS_DEFAULT) : "
	fi
	read -r domains_answer
	resolve_prompted_domains "$domains_answer"
}

prompt_workdir_if_needed()
{
	local workdir_answer

	[ -n "$REGRESSIVE_WORKDIR" ] && return 0
	printf "work directory for logs and list files (default: $WORKDIR_DEF) : "
	read -r workdir_answer
	REGRESSIVE_WORKDIR="${workdir_answer:-$WORKDIR_DEF}"
}

prompt_seed_paths_if_needed()
{
	local tls12_seed tls13_seed quic_seed

	echo
	echo "Optional: paths to nfqws strategy list files for the FIRST domain only."
	echo "If any file exists and is non-empty, round 1 uses TEST=custom with those lists (no full standard scan)."
	echo "Leave empty to run a normal first-domain profile instead."

	printf "list_https_tls12 (default: empty) : "
	read -r tls12_seed
	[ -n "$tls12_seed" ] && REGRESSIVE_SEED_LIST_TLS12=$tls12_seed

	printf "list_https_tls13 (default: empty) : "
	read -r tls13_seed
	[ -n "$tls13_seed" ] && REGRESSIVE_SEED_LIST_TLS13=$tls13_seed

	printf "list_quic / http3 (default: empty) : "
	read -r quic_seed
	[ -n "$quic_seed" ] && REGRESSIVE_SEED_LIST_QUIC=$quic_seed
}

prompt_first_test_if_needed()
{
	compute_use_seed
	[ "$use_seed" -eq 0 ] || return 0

	dir_is_not_empty "$BLOCKCHECK2D" || {
		echo "directory '$BLOCKCHECK2D' is absent or empty"
		rb_exitp 1
	}
	REGRESSIVE_FIRST_TEST=${REGRESSIVE_FIRST_TEST:-standard}
	echo "first-domain profile (subdirectory of blockcheck2.d):"
	ask_list REGRESSIVE_FIRST_TEST "standard custom" "$REGRESSIVE_FIRST_TEST"
}

prompt_protocol_options_if_needed()
{
	local ipvs_answer
	local ipvs_default=4
	local uname_s

	[ -n "$IPVS" ] || {
		uname_s=$(uname)
		[ "$uname_s" = Linux ] && ping -c 1 -W 1 -6 2a02:6b8::feed:0ff >/dev/null 2>&1 && ipvs_default=46
		printf "ip protocol version(s) - 4, 6 or 46 for both (default: $ipvs_default) : "
		read -r ipvs_answer
		IPVS=${ipvs_answer:-$ipvs_default}
		[ "$IPVS" = 4 -o "$IPVS" = 6 -o "$IPVS" = 46 ] || {
			echo 'invalid ip version(s). should be 4, 6 or 46.'
			rb_exitp 1
		}
	}
	[ "$IPVS" = 46 ] && IPVS="4 6"

	[ -n "$ENABLE_HTTP" ] || {
		ENABLE_HTTP=1
		echo
		ask_yes_no_var ENABLE_HTTP "check http"
	}

	[ -n "$ENABLE_HTTPS_TLS12" ] || {
		ENABLE_HTTPS_TLS12=1
		echo
		ask_yes_no_var ENABLE_HTTPS_TLS12 "check https tls 1.2"
	}

	[ -n "$ENABLE_HTTPS_TLS13" ] || {
		ENABLE_HTTPS_TLS13=0
		if [ -n "$TLS13" ]; then
			echo
			echo "TLS 1.3 uses encrypted ServerHello. DPI cannot check domain name in server response."
			echo "What works for TLS 1.2 will also work for TLS 1.3 but not vice versa."
			ask_yes_no_var ENABLE_HTTPS_TLS13 "check https tls 1.3"
		else
			echo
			echo "installed curl version does not support TLS 1.3 . tests disabled."
		fi
	}

	[ -n "$ENABLE_HTTP3" ] || {
		ENABLE_HTTP3=0
		if [ -n "$HTTP3" ]; then
			ENABLE_HTTP3=1
			echo
			echo "make sure target domain(s) support QUIC or result will be negative in any case"
			ask_yes_no_var ENABLE_HTTP3 "check http3 QUIC"
		else
			echo
			echo "installed curl version does not support http3 QUIC. tests disabled."
		fi
	}
}

prompt_repeat_parallel_scanlevel_if_needed()
{
	local repeats_answer

	[ -n "$REPEATS" ] || {
		echo
		echo "sometimes ISPs use multiple DPIs or load balancing. bypass strategies may work unstable."
		printf "how many times to repeat each test (default: 1) : "
		read -r repeats_answer
		REPEATS=$((0+${repeats_answer:-1}))
		[ "$REPEATS" = 0 ] && {
			echo invalid repeat count
			rb_exitp 1
		}
	}

	[ -z "$PARALLEL" -a "$REPEATS" -gt 1 ] && {
		PARALLEL=0
		echo
		echo "parallel scan can greatly increase speed but may also trigger DDoS protection and cause false result"
		ask_yes_no_var PARALLEL "enable parallel scan"
	}
	PARALLEL=${PARALLEL:-0}

	[ -n "$SCANLEVEL" ] || {
		SCANLEVEL=standard
		echo
		echo quick    - in multi-attempt mode skip further attempts after first failure
		echo standard - do investigation what works on your DPI
		echo force    - scan maximum despite of result
		ask_list SCANLEVEL "quick standard force" "$SCANLEVEL"
	}
}

show_run_mode_banner()
{
	echo
	echo "--- starting runs (each inner blockcheck uses BATCH=1) ---"
	if [ "${REGRESSIVE_SHOW_BLOCKCHECK:-1}" = 1 ]; then
		echo "live blockcheck output is shown; hidden parser logs are deleted unless REGRESSIVE_KEEP_LOGS=1."
	else
		echo "quiet: blockcheck is hidden; hidden parser logs are still used for summary extraction."
	fi
}

# Interactive prompts (aligned with blockcheck2.sh ask_params where applicable).
ask_regressive_params()
{
	[ "$BATCH" = 1 ] && return 0

	show_regressive_intro
	ensure_interactive_prereqs
	rb_configure_curl_opt
	prompt_domains_if_needed
	prompt_workdir_if_needed
	prompt_seed_paths_if_needed
	prompt_first_test_if_needed
	validate_domain_count_or_exitp
	prompt_protocol_options_if_needed
	prompt_repeat_parallel_scanlevel_if_needed
	show_run_mode_banner
}

show_usage_and_exit()
{
	echo "usage: REGRESSIVE_DOMAINS='a.com b.com' $0   or: REGRESSIVE_DOMAINS_FILE=/path/to/domains $0"
	echo "   or: $0 a.com b.com"
	echo "non-interactive: set BATCH=1 and the same variables as for blockcheck2.sh"
	exit 1
}

ensure_blockcheck_exists()
{
	[ -f "$BLOCKCHECK" ] || {
		echo "cannot find blockcheck2.sh at $BLOCKCHECK"
		exit 1
	}
}

initialize_runtime_config()
{
	WORKDIR=${REGRESSIVE_WORKDIR:-"$WORKDIR_DEF"}
	FIRST_TEST=${REGRESSIVE_FIRST_TEST:-standard}
	compute_use_seed
}

# $1 = blockcheck log, $2 = domain tested, $3 = output directory for list_https_tls12.txt etc.
extract_summary_lists()
{
	local log_file=$1
	local domain_name=$2
	local output_dir=$3

	mkdir -p "$output_dir" || return 1
	: >"$output_dir/list_https_tls12.txt"
	: >"$output_dir/list_https_tls13.txt"
	: >"$output_dir/list_quic.txt"

	awk -v dom="$domain_name" -v outbase="$output_dir" '
	$0 == "* SUMMARY" { ins = 1; next }
	ins && $0 == "" { next }
	ins && $1 == "*" { ins = 0; next }
	ins && $0 ~ " not working$" { next }
	ins && $0 ~ " working without bypass$" { next }
	ins && $0 ~ " test aborted" { next }
	ins && $0 ~ "^curl_test_https_tls12 ipv4 " dom " :" {
		s = $0
		sub(/^.* : [^ ]+ /, "", s)
		print s >> (outbase "/list_https_tls12.txt")
		next
	}
	ins && $0 ~ "^curl_test_https_tls12 ipv6 " dom " :" {
		s = $0
		sub(/^.* : [^ ]+ /, "", s)
		print s >> (outbase "/list_https_tls12.txt")
		next
	}
	ins && $0 ~ "^curl_test_https_tls13 ipv4 " dom " :" {
		s = $0
		sub(/^.* : [^ ]+ /, "", s)
		print s >> (outbase "/list_https_tls13.txt")
		next
	}
	ins && $0 ~ "^curl_test_https_tls13 ipv6 " dom " :" {
		s = $0
		sub(/^.* : [^ ]+ /, "", s)
		print s >> (outbase "/list_https_tls13.txt")
		next
	}
	ins && $0 ~ "^curl_test_http3 ipv4 " dom " :" {
		s = $0
		sub(/^.* : [^ ]+ /, "", s)
		print s >> (outbase "/list_quic.txt")
		next
	}
	ins && $0 ~ "^curl_test_http3 ipv6 " dom " :" {
		s = $0
		sub(/^.* : [^ ]+ /, "", s)
		print s >> (outbase "/list_quic.txt")
		next
	}
	' <"$log_file" || return 1

	for output_file in list_https_tls12.txt list_https_tls13.txt list_quic.txt; do
		[ -s "$output_dir/$output_file" ] || : >"$output_dir/$output_file"
		sort -u "$output_dir/$output_file" >"$output_dir/$output_file.sorttmp" && mv "$output_dir/$output_file.sorttmp" "$output_dir/$output_file"
	done
}

write_combined_strategy_file()
{
	local input_dir=$1
	local output_file=$2

	cat "$input_dir/list_https_tls12.txt" "$input_dir/list_https_tls13.txt" "$input_dir/list_quic.txt" 2>/dev/null | sed '/^$/d' | sort -u >"$output_file"
}

shell_escape_strategy_line()
{
	local strategy_line=$1
	local -a args
	local arg escaped first=1

	# custom/10-list.sh historically used eval, so each argument must be
	# emitted as an individually quoted shell token to keep constructs like
	# tls_mod(fake_default_tls,'rnd') from being reparsed as shell syntax.
	read -r -a args <<<"$strategy_line"
	for arg in "${args[@]}"; do
		escaped=$(printf '%s' "$arg" | sed "s/'/'\"'\"'/g")
		if [ "$first" -eq 1 ]; then
			printf "'%s'" "$escaped"
			first=0
		else
			printf " '%s'" "$escaped"
		fi
	done
	printf '\n'
}

write_shell_safe_strategy_file()
{
	local input_file=$1
	local output_file=$2

	: >"$output_file"
	[ -s "$input_file" ] || return 0
	while IFS= read -r strategy_line; do
		shell_escape_strategy_line "$strategy_line" >>"$output_file"
	done <"$input_file"
}

write_shell_safe_list_set()
{
	local input_dir=$1
	local safe_dir=$2

	mkdir -p "$safe_dir" || return 1
	write_shell_safe_strategy_file "$input_dir/list_https_tls12.txt" "$safe_dir/list_https_tls12.txt" || return 1
	write_shell_safe_strategy_file "$input_dir/list_https_tls13.txt" "$safe_dir/list_https_tls13.txt" || return 1
	write_shell_safe_strategy_file "$input_dir/list_quic.txt" "$safe_dir/list_quic.txt" || return 1
}

write_shell_safe_list_set_from_seeds()
{
	local safe_dir=$1

	mkdir -p "$safe_dir" || return 1
	write_shell_safe_strategy_file "$REGRESSIVE_SEED_LIST_TLS12" "$safe_dir/list_https_tls12.txt" || return 1
	write_shell_safe_strategy_file "$REGRESSIVE_SEED_LIST_TLS13" "$safe_dir/list_https_tls13.txt" || return 1
	write_shell_safe_strategy_file "$REGRESSIVE_SEED_LIST_QUIC" "$safe_dir/list_quic.txt" || return 1
}

apply_protocol_file_env()
{
	local file_path=$1
	local list_var_name=$2
	local enable_var_name=$3

	if [ -n "$file_path" ] && [ -s "$file_path" ]; then
		export "$list_var_name=$file_path"
	else
		unset "$list_var_name"
		export "$enable_var_name=0"
	fi
}

apply_custom_list_env_from_dir()
{
	local list_dir=$1
	local safe_dir="$list_dir/.shell-safe"

	write_shell_safe_list_set "$list_dir" "$safe_dir" || exit 1
	apply_protocol_file_env "$safe_dir/list_https_tls12.txt" LIST_HTTPS_TLS12 ENABLE_HTTPS_TLS12
	apply_protocol_file_env "$safe_dir/list_https_tls13.txt" LIST_HTTPS_TLS13 ENABLE_HTTPS_TLS13
	apply_protocol_file_env "$safe_dir/list_quic.txt" LIST_QUIC ENABLE_HTTP3
}

apply_custom_list_env_from_seeds()
{
	local seed_safe_dir="$WORKDIR/.seed-shell-safe"

	write_shell_safe_list_set_from_seeds "$seed_safe_dir" || exit 1
	apply_protocol_file_env "$seed_safe_dir/list_https_tls12.txt" LIST_HTTPS_TLS12 ENABLE_HTTPS_TLS12
	apply_protocol_file_env "$seed_safe_dir/list_https_tls13.txt" LIST_HTTPS_TLS13 ENABLE_HTTPS_TLS13
	apply_protocol_file_env "$seed_safe_dir/list_quic.txt" LIST_QUIC ENABLE_HTTP3
}

round_has_strategies()
{
	local list_dir=$1

	[ -s "$list_dir/list_https_tls12.txt" ] || [ -s "$list_dir/list_https_tls13.txt" ] || [ -s "$list_dir/list_quic.txt" ]
}

_rb_blockcheck_to_log()
{
	local log_file=$1

	if [ "${REGRESSIVE_SHOW_BLOCKCHECK:-1}" = 1 ]; then
		tee "$log_file"
	else
		cat >"$log_file"
	fi
}

run_blockcheck_round()
{
	local round_number=$1
	local domain_name=$2
	local previous_lists_dir=$3
	local log_file=$4

	if [ "$round_number" -eq 1 ] && [ "$use_seed" -eq 0 ]; then
		(
			export BATCH=1
			unset LIST_HTTP LIST_HTTPS_TLS12 LIST_HTTPS_TLS13 LIST_QUIC
			export DOMAINS=$domain_name
			export TEST="$FIRST_TEST"
			exec "$BLOCKCHECK"
		) 2>&1 | _rb_blockcheck_to_log "$log_file" || true
		return 0
	fi

	if [ "$round_number" -eq 1 ] && [ "$use_seed" -eq 1 ]; then
		(
			export BATCH=1
			export DOMAINS=$domain_name
			export TEST=custom
			apply_custom_list_env_from_seeds
			exec "$BLOCKCHECK"
		) 2>&1 | _rb_blockcheck_to_log "$log_file" || true
		return 0
	fi

	[ -n "$previous_lists_dir" ] || {
		echo "internal error: no previous list dir"
		exit 1
	}
	round_has_strategies "$previous_lists_dir" || {
		echo "no strategies left after previous domain; stopping before $domain_name"
		exit 1
	}

	(
		export BATCH=1
		export DOMAINS=$domain_name
		export TEST=custom
		apply_custom_list_env_from_dir "$previous_lists_dir"
		exec "$BLOCKCHECK"
	) 2>&1 | _rb_blockcheck_to_log "$log_file" || true
}

write_round_artifacts()
{
	local domain_name=$1
	local log_file=$2
	local lists_dir=$3
	local combined_file=$4
	local visible_log_file=$5
	local tls12_count tls13_count quic_count

	extract_summary_lists "$log_file" "$domain_name" "$lists_dir" || {
		echo "failed to extract lists from $log_file"
		exit 1
	}

	tls12_count=$(wc -l <"$lists_dir/list_https_tls12.txt" | tr -d ' ')
	tls13_count=$(wc -l <"$lists_dir/list_https_tls13.txt" | tr -d ' ')
	quic_count=$(wc -l <"$lists_dir/list_quic.txt" | tr -d ' ')
	write_combined_strategy_file "$lists_dir" "$combined_file" || exit 1
	echo "strategies for next round — tls12=$tls12_count  tls13=$tls13_count  quic=$quic_count"
	echo "clean combined list: $combined_file"

	if [ "${REGRESSIVE_KEEP_LOGS:-0}" = 1 ]; then
		cp -f "$log_file" "$visible_log_file"
	fi
	rm -f "$log_file"
}

finalize_artifacts()
{
	local final_lists_dir=$1

	echo "======== regressive_blockcheck2: done ========"
	echo "last-domain lists: $final_lists_dir"
	cp -f "$final_lists_dir/list_https_tls12.txt" "$WORKDIR/regressive-final-tls12.txt"
	cp -f "$final_lists_dir/list_https_tls13.txt" "$WORKDIR/regressive-final-tls13.txt"
	cp -f "$final_lists_dir/list_quic.txt" "$WORKDIR/regressive-final-quic.txt"
	write_combined_strategy_file "$final_lists_dir" "$WORKDIR/regressive-final-strategies.txt" || exit 1
	echo "copy-paste into zapret config (one strategy per line, nfqws args only):"
	echo "  $WORKDIR/regressive-final-tls12.txt"
	echo "  $WORKDIR/regressive-final-tls13.txt"
	echo "  $WORKDIR/regressive-final-quic.txt"
	echo "  $WORKDIR/regressive-final-strategies.txt"
	[ "${REGRESSIVE_KEEP_LOGS:-0}" = 1 ] && echo "visible round logs kept in: $WORKDIR"
}

run_regressive_rounds()
{
	local round_number=0
	local previous_lists_dir=
	local domain_name domain_safe log_file visible_log_file lists_dir combined_file

	mkdir -p "$WORKDIR" || exit 1

	for domain_name in $REGRESSIVE_DOMAINS; do
		round_number=$((round_number + 1))
		domain_safe=$(printf '%s' "$domain_name" | tr '/:[:space:]' '___')
		log_file=$(mktemp "$WORKDIR/.round-${round_number}-${domain_safe}.XXXXXX.log") || exit 1
		visible_log_file="$WORKDIR/round-${round_number}-${domain_safe}.log"
		lists_dir="$WORKDIR/lists-after-round-${round_number}-${domain_name}"
		combined_file="$WORKDIR/strategies-after-round-${round_number}-${domain_safe}.txt"
		: >"$log_file"

		echo "======== regressive_blockcheck2: round $round_number / $DOMAINS_COUNT_CHK  domain $domain_name ========"
		[ "${REGRESSIVE_KEEP_LOGS:-0}" = 1 ] && echo "keeping round log: $visible_log_file"

		run_blockcheck_round "$round_number" "$domain_name" "$previous_lists_dir" "$log_file"
		write_round_artifacts "$domain_name" "$log_file" "$lists_dir" "$combined_file" "$visible_log_file"
		previous_lists_dir=$lists_dir
	done

	finalize_artifacts "$previous_lists_dir"
}

main()
{
	ensure_blockcheck_exists
	REGRESSIVE_DOMAINS=${REGRESSIVE_DOMAINS:-"$*"}
	ask_regressive_params
	[ -n "$REGRESSIVE_DOMAINS" ] || show_usage_and_exit
	validate_domain_count_or_exit
	initialize_runtime_config
	run_regressive_rounds
}

main "$@"
