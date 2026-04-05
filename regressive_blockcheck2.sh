#!/bin/sh
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
	local A
	[ "$BATCH" = 1 ] || {
		echo
		echo press enter to continue
		read A
	}
	exit "$1"
}

# Interactive prompts (aligned with blockcheck2.sh ask_params where applicable).
ask_regressive_params()
{
	local dom IPVS_def=4

	[ "$BATCH" = 1 ] && return 0

	echo
	echo NOTE ! this test should be run with zapret or any other bypass software disabled, without VPN
	echo
	echo "--- regressive blockcheck ---"
	echo "Each domain after the first is tested only with strategies that succeeded on the previous domain."
	echo

	curl_supports_connect_to || {
		echo "installed curl does not support --connect-to option. pls install at least curl 7.49"
		echo "current curl version:"
		"$CURL" --version
		rb_exitp 1
	}

	rb_configure_curl_opt

	[ -n "$REGRESSIVE_DOMAINS" ] || {
		echo "specify domain(s). multiple domains are space separated. URIs are supported (rutracker.org/forum/index.php)"
		printf "domain(s) (default: $DOMAINS_DEFAULT) : "
		read dom
		REGRESSIVE_DOMAINS="${dom:-$DOMAINS_DEFAULT}"
	}

	[ -n "$REGRESSIVE_WORKDIR" ] || {
		printf "work directory for logs and list files (default: $WORKDIR_DEF) : "
		read dom
		REGRESSIVE_WORKDIR="${dom:-$WORKDIR_DEF}"
	}

	echo
	echo "Optional: paths to nfqws strategy list files for the FIRST domain only."
	echo "If any file exists and is non-empty, round 1 uses TEST=custom with those lists (no full standard scan)."
	echo "Leave empty to run a normal first-domain profile instead."
	printf "list_https_tls12 (default: empty) : "
	read dom
	[ -n "$dom" ] && REGRESSIVE_SEED_LIST_TLS12=$dom
	printf "list_https_tls13 (default: empty) : "
	read dom
	[ -n "$dom" ] && REGRESSIVE_SEED_LIST_TLS13=$dom
	printf "list_quic / http3 (default: empty) : "
	read dom
	[ -n "$dom" ] && REGRESSIVE_SEED_LIST_QUIC=$dom

	use_seed=0
	[ -n "$REGRESSIVE_SEED_LIST_TLS12" ] && [ -s "$REGRESSIVE_SEED_LIST_TLS12" ] && use_seed=1
	[ -n "$REGRESSIVE_SEED_LIST_TLS13" ] && [ -s "$REGRESSIVE_SEED_LIST_TLS13" ] && use_seed=1
	[ -n "$REGRESSIVE_SEED_LIST_QUIC" ] && [ -s "$REGRESSIVE_SEED_LIST_QUIC" ] && use_seed=1

	if [ "$use_seed" -eq 0 ]; then
		dir_is_not_empty "$BLOCKCHECK2D" || {
			echo "directory '$BLOCKCHECK2D' is absent or empty"
			rb_exitp 1
		}
		REGRESSIVE_FIRST_TEST=${REGRESSIVE_FIRST_TEST:-standard}
		echo "first-domain profile (subdirectory of blockcheck2.d):"
		ask_list REGRESSIVE_FIRST_TEST "standard custom" "$REGRESSIVE_FIRST_TEST"
	fi

	DOMAINS_COUNT_TMP="$(echo "$REGRESSIVE_DOMAINS" | wc -w | trim)"
	[ "$DOMAINS_COUNT_TMP" -gt 1 ] || {
		echo "regressive mode needs at least 2 domains (or use plain blockcheck2.sh for one host)."
		rb_exitp 1
	}

	[ -n "$IPVS" ] || {
		UNAME=$(uname)
		[ "$UNAME" = Linux ] && ping -c 1 -W 1 -6 2a02:6b8::feed:0ff >/dev/null 2>&1 && IPVS_def=46
		printf "ip protocol version(s) - 4, 6 or 46 for both (default: $IPVS_def) : "
		read IPVS
		[ -n "$IPVS" ] || IPVS=$IPVS_def
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

	[ -n "$REPEATS" ] || {
		echo
		echo "sometimes ISPs use multiple DPIs or load balancing. bypass strategies may work unstable."
		printf "how many times to repeat each test (default: 1) : "
		read REPEATS
		REPEATS=$((0+${REPEATS:-1}))
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

	echo
	echo "--- starting runs (each inner blockcheck uses BATCH=1) ---"
}

[ -f "$BLOCKCHECK" ] || {
	echo "cannot find blockcheck2.sh at $BLOCKCHECK"
	exit 1
}

REGRESSIVE_DOMAINS=${REGRESSIVE_DOMAINS:-"$*"}

ask_regressive_params

[ -n "$REGRESSIVE_DOMAINS" ] || {
	echo "usage: REGRESSIVE_DOMAINS='a.com b.com' $0"
	echo "   or: $0 a.com b.com"
	echo "non-interactive: set BATCH=1 and the same variables as for blockcheck2.sh"
	exit 1
}
DOMAINS_COUNT_CHK="$(echo "$REGRESSIVE_DOMAINS" | wc -w | trim)"
[ "$DOMAINS_COUNT_CHK" -ge 2 ] || {
	echo "regressive mode needs at least 2 domains."
	exit 1
}

WORKDIR=${REGRESSIVE_WORKDIR:-"$WORKDIR_DEF"}
FIRST_TEST=${REGRESSIVE_FIRST_TEST:-standard}

use_seed=0
[ -n "$REGRESSIVE_SEED_LIST_TLS12" ] && [ -s "$REGRESSIVE_SEED_LIST_TLS12" ] && use_seed=1
[ -n "$REGRESSIVE_SEED_LIST_TLS13" ] && [ -s "$REGRESSIVE_SEED_LIST_TLS13" ] && use_seed=1
[ -n "$REGRESSIVE_SEED_LIST_QUIC" ] && [ -s "$REGRESSIVE_SEED_LIST_QUIC" ] && use_seed=1

# $1 = blockcheck log, $2 = domain tested, $3 = output directory for list_https_tls12.txt etc.
extract_summary_lists()
{
	_log=$1
	_dom=$2
	_out=$3

	mkdir -p "$_out" || return 1
	: >"$_out/list_https_tls12.txt"
	: >"$_out/list_https_tls13.txt"
	: >"$_out/list_quic.txt"

	awk -v dom="$_dom" -v outbase="$_out" '
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
	' <"$_log" || return 1

	for _f in list_https_tls12.txt list_https_tls13.txt list_quic.txt; do
		[ -s "$_out/$_f" ] || : >"$_out/$_f"
		sort -u "$_out/$_f" >"$_out/$_f.sorttmp" && mv "$_out/$_f.sorttmp" "$_out/$_f"
	done
}

apply_custom_list_env_from_dir()
{
	_d=$1
	if [ -s "$_d/list_https_tls12.txt" ]; then
		export LIST_HTTPS_TLS12="$_d/list_https_tls12.txt"
	else
		unset LIST_HTTPS_TLS12
		export ENABLE_HTTPS_TLS12=0
	fi
	if [ -s "$_d/list_https_tls13.txt" ]; then
		export LIST_HTTPS_TLS13="$_d/list_https_tls13.txt"
	else
		unset LIST_HTTPS_TLS13
		export ENABLE_HTTPS_TLS13=0
	fi
	if [ -s "$_d/list_quic.txt" ]; then
		export LIST_QUIC="$_d/list_quic.txt"
	else
		unset LIST_QUIC
		export ENABLE_HTTP3=0
	fi
}

apply_custom_list_env_from_seeds()
{
	if [ -n "$REGRESSIVE_SEED_LIST_TLS12" ] && [ -s "$REGRESSIVE_SEED_LIST_TLS12" ]; then
		export LIST_HTTPS_TLS12="$REGRESSIVE_SEED_LIST_TLS12"
	else
		unset LIST_HTTPS_TLS12
		export ENABLE_HTTPS_TLS12=0
	fi
	if [ -n "$REGRESSIVE_SEED_LIST_TLS13" ] && [ -s "$REGRESSIVE_SEED_LIST_TLS13" ]; then
		export LIST_HTTPS_TLS13="$REGRESSIVE_SEED_LIST_TLS13"
	else
		unset LIST_HTTPS_TLS13
		export ENABLE_HTTPS_TLS13=0
	fi
	if [ -n "$REGRESSIVE_SEED_LIST_QUIC" ] && [ -s "$REGRESSIVE_SEED_LIST_QUIC" ]; then
		export LIST_QUIC="$REGRESSIVE_SEED_LIST_QUIC"
	else
		unset LIST_QUIC
		export ENABLE_HTTP3=0
	fi
}

round=0
prev_dir=""
mkdir -p "$WORKDIR" || exit 1

for dom in $REGRESSIVE_DOMAINS; do
	round=$((round + 1))
	log="$WORKDIR/round-${round}-${dom}.log"
	lists_dir="$WORKDIR/lists-after-round-${round}-${dom}"

	echo "======== regressive_blockcheck2: round $round domain $dom ========"

	if [ "$round" -eq 1 ] && [ "$use_seed" -eq 0 ]; then
		(
			export BATCH=1
			unset LIST_HTTP LIST_HTTPS_TLS12 LIST_HTTPS_TLS13 LIST_QUIC
			export DOMAINS=$dom
			export TEST="$FIRST_TEST"
			exec "$BLOCKCHECK"
		) 2>&1 | tee "$log" || true
	elif [ "$round" -eq 1 ] && [ "$use_seed" -eq 1 ]; then
		(
			export BATCH=1
			export DOMAINS=$dom
			export TEST=custom
			apply_custom_list_env_from_seeds
			exec "$BLOCKCHECK"
		) 2>&1 | tee "$log" || true
	else
		[ -n "$prev_dir" ] || {
			echo "internal error: no previous list dir"
			exit 1
		}
		[ -s "$prev_dir/list_https_tls12.txt" ] || [ -s "$prev_dir/list_https_tls13.txt" ] || [ -s "$prev_dir/list_quic.txt" ] || {
			echo "no strategies left after previous domain; stopping before $dom"
			exit 1
		}
		(
			export BATCH=1
			export DOMAINS=$dom
			export TEST=custom
			apply_custom_list_env_from_dir "$prev_dir"
			exec "$BLOCKCHECK"
		) 2>&1 | tee "$log" || true
	fi

	extract_summary_lists "$log" "$dom" "$lists_dir" || {
		echo "failed to extract lists from $log"
		exit 1
	}

	n12=$(wc -l <"$lists_dir/list_https_tls12.txt" | tr -d ' ')
	n13=$(wc -l <"$lists_dir/list_https_tls13.txt" | tr -d ' ')
	nq=$(wc -l <"$lists_dir/list_quic.txt" | tr -d ' ')
	echo "extracted for $dom: tls12=$n12 tls13=$n13 quic=$nq -> $lists_dir"

	prev_dir=$lists_dir
done

echo "======== regressive_blockcheck2: done ========"
echo "final lists (last domain): $prev_dir"
ls -l "$prev_dir"
