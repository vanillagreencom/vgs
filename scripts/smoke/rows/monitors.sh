# A monitor that goes away takes its bar with it, under the key the bar
# was built under, and leaves no build record behind.
set -euo pipefail
extra_output=SMOKE-2
bar_hosts() { ipc shell built | python3 -c 'import json,sys; print(json.dumps(sorted(k for k in json.load(sys.stdin) if k.startswith("bar:"))))'; }
before_hosts="$(bar_hosts)"
expect "the nested compositor adds a monitor" ok hypr output create headless "$extra_output"
expect_poll "the new monitor gets a bar" "$((monitors + 1))" bar_count
extra_listed() { bar_hosts | python3 -c 'import json,sys; print(("bar:" + sys.argv[1]) in json.load(sys.stdin))' "$extra_output"; }
expect_poll "the new bar is in the build records" True extra_listed
expect "the nested compositor removes the monitor" ok hypr output remove "$extra_output"
expect_poll "the removed monitor's bar surface is gone" "$monitors" bar_count
expect_poll "the removed monitor's bar left the build records" "$before_hosts" bar_hosts
