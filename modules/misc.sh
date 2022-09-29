#!/usr/bin/env bash
# Copyright 2022 Northern.tech AS
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

function check_and_merge_mender_configs() {
    local -a overlay_targets=()
    local -r conf_path="work/rootfs/etc/mender/mender.conf"
    local -r tmpfile="work/mergefiles/mender.conf"
    local -r jqfilter="work/mergefiles/jqmergefilter"
    local -r warn_message='The resulting image will not contain a Mender configuration file.
To ensure the file is there run a bootstrap script and pass the output-dir as an overlay to mender-convert, 
or supply your own overlay with a $OVERLAY/etc/mender/mender.conf file.'
    local message
    local menderconfs

    if [ "${#overlays[@]}" -eq 0 ]; then
        log_warn "No overlay specified. ${warn_message}"
        return
    fi

    for overlay in "${overlays[@]}"; do
        [ -f "${overlay}/etc/mender/mender.conf" ] && overlay_targets+=("${overlay}")
    done

    if [ "${#overlay_targets[@]}" -eq 0 ]; then
        log_warn "Mender configuration file not found in any of the overlays. ${warn_message}"
        return
    fi

    mkdir -p work/mergefiles
    menderconfs="${overlay_targets[@]/%//etc/mender/mender.conf}"

    if [ "${#overlay_targets[@]}" -gt 1 ]; then
        message+="Attempting to merge /etc/mender/mender.conf from overlays. With respect to the overlays, the merge is done from top to bottom in the following order:"
        message+="${overlay_targets[@]/#/$'\n'' * '}"
        log_info "${message}"
        cat << "EOF" > "${jqfilter}"
        def findsimkeys(obj;k):
            [obj | to_entries[] | .key | match(k; "ig")] | if length > 0 then .[].string else k end
        ;
        def deepmerge(a;b):
            reduce b[] as $item (a;
                reduce ($item | keys_unsorted[]) as $key (.;
                    $item[$key] as $val | ($val | type) as $type | findsimkeys(.;$key) as $simkey | .[$simkey] = if ($type == "object") then
                        deepmerge({}; [if .[$simkey] == null then {} else .[$simkey] end, $val])
                    elif ($type == "array") then
                        (.[$key] + $val | unique)
                    else
                        $val
                    end
                )
            )
        ;
        deepmerge({}; .)
EOF

        run_and_log_cmd "jq --slurp --from-file ${jqfilter} ${menderconfs} > ${tmpfile}"

        run_and_log_cmd "sudo cp ${tmpfile} ${conf_path}"
        log_warn "New mender.conf contents after merging: $(cat ${conf_path})"

        if [ "$(jq '[to_entries[] | .key | ascii_downcase] | index("servers") and index("serverurl")' ${tmpfile})" = true ]; then
            log_fatal "Final Mender configuration file has both 'Servers' and 'ServerURL' fields. This is an error. For more information see our docs regarding configuration options."
        fi
    fi
    run_and_log_cmd "sudo chmod 0600 ${conf_path}"
}
