# yes i know. cursed. fight me. also dcs update nvidia-ctk pls :<
# dcs uses nvidia-ctk v1.13.5 currently. the cdi specs generated always include chmod hooks which fail due to lack of perms
# (spec v0.5 for ref)
# v1.18 deprecates these hooks and doesn't include them by default
# generating the cdi spec gives the host binds needed to use the gpu in the container
# previously when this was done via distrobox, distrobox-init would loop through every possible thing it could find (incl. hardcoding)
# this is a much cleaner solution

# second addition: patching https://github.com/NVIDIA/nvidia-container-toolkit/issues/682
# add from here into cdi for consistency more than anything
  # alternatives are e.g. mount in xsession, or create icd with "libnvidia-opencl.so.1" inside
  # removeable once nvidia-ctk 1.20 releases and dcs starts using it

# see comments below re extra additions incl. fixing of egl ext plats, gbm & 32 bit fixes

# have to give podman "--cdi-spec-dir ./host" so it picks it up. default only looks in /etc/cdi which isn't present on the dcs fs
# if testing locally, most likely unnecessary once you have nvidia-ctk, worst case scenario you do e.g. sudo nvidia-ctk cdi generate one time
# with a cdi spec present, --device nvidia.com/gpu=all can be used when invoking podman
set -euo pipefail

cd "$(dirname "$0")"

tmp=$(mktemp -d ./host/.genicd.XXXXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

nvidia-ctk cdi generate > "$tmp/base.yaml"
: > "$tmp/mounts"
: > "$tmp/hooks"

# /lib64 & /usr/lib64 alias /usr/lib on cachy/arch
# normalise paths to avoid dupes
container_path_key() {
    case "$1" in
        /lib64/*) printf '/usr/lib/%s' "${1#/lib64/}" ;;
        /usr/lib64/*) printf '/usr/lib/%s' "${1#/usr/lib64/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

declare -A mounted=()
while IFS= read -r path; do
    mounted["$(container_path_key "$path")"]=1
done < <(sed -n 's/^  - containerPath: //p' "$tmp/base.yaml")

add_mount() {
    local src=$1 dst=${2:-$1} key
    [[ -f $src ]] || return 0
    key=$(container_path_key "$dst")
    [[ -v mounted[$key] ]] && return 0
    mounted["$key"]=1

    printf '  - containerPath: %s\n    hostPath: %s\n    options:\n    - ro\n    - nosuid\n    - nodev\n    - bind\n' "$dst" "$src" >> "$tmp/mounts"
}

# files & conf not in 1.13.5 cdi discovery
add_mount /etc/OpenCL/vendors/nvidia.icd
add_mount /usr/bin/nvidia-settings

# egl ext plat manifests (shared 32 & 64 bit)
for config in /usr/share/egl/egl_external_platform.d/*nvidia*.json /usr/share/glvnd/egl_vendor.d/*nvidia*.json; do
    add_mount "$config"
done

# libnvidia-egl-{gbm,wayland,wayland2,xcb,xlib} ext plat libs (lib64 to lib on cachy/arch)
have_lib64_allocator=false
while IFS= read -r -d '' lib; do
    add_mount "$lib" "/usr/lib/${lib#/usr/lib64/}"
    [[ $lib == /usr/lib64/libnvidia-allocator.so.* ]] && have_lib64_allocator=true
done < <(find /usr/lib64 -maxdepth 2 -type f \( -name '*nvidia*.so*' -o -name 'libcuda.so*' -o -name 'libnvcuvid.so*' -o -name 'libnvoptix.so*' \) -print0)

# lib to lib32; bind versioned files & let update-ldcache resolve sonames
have_lib32_allocator=false
while IFS= read -r -d '' lib; do
    add_mount "$lib" "/usr/lib32/${lib#/usr/lib/}"
    [[ $lib == /usr/lib/libnvidia-allocator.so.* ]] && have_lib32_allocator=true
done < <(find /usr/lib -maxdepth 2 -type f \( -name '*nvidia*.so*' -o -name 'libcuda.so*' -o -name 'libnvcuvid.so*' -o -name 'libnvoptix.so*' \) -print0)

# gbm b/e aliases aren't elf --> create symlinks explicitly
links=()
if { [[ $have_lib64_allocator == true ]] || grep -Eq 'containerPath: (/lib64|/usr/lib|/usr/lib64)/libnvidia-allocator\.so\.' "$tmp/base.yaml"; } && ! grep -Eq '::/(lib64|usr/lib|usr/lib64)/gbm/nvidia-drm_gbm\.so$' "$tmp/base.yaml"; then
    links+=( '../libnvidia-allocator.so.1::/usr/lib/gbm/nvidia-drm_gbm.so' )
fi
if [[ $have_lib32_allocator == true ]] && ! grep -Fq '::/usr/lib32/gbm/nvidia-drm_gbm.so' "$tmp/base.yaml"; then
    links+=( '../libnvidia-allocator.so.1::/usr/lib32/gbm/nvidia-drm_gbm.so' )
fi

if (( ${#links[@]} )); then
    {
        printf '  - args:\n    - nvidia-ctk\n    - hook\n    - create-symlinks\n'
        for link in "${links[@]}"; do
            printf '    - --link\n    - %s\n' "$link"
        done
        printf '    hookName: createContainer\n    path: /usr/bin/nvidia-ctk\n'
    } > "$tmp/hooks"
fi

# yeet the broken chmod hooks, add 32 bit ldconfig path & inject mounts + hooks into containerEdits
sed '/^[[:space:]]*- args:/ { :hook; N; /path:/!b hook; /chmod/d; }' "$tmp/base.yaml" |
sed -e '/^    - update-ldcache$/a\
    - --folder\
    - /usr/lib32' \
    -e "/^  hooks:/r $tmp/hooks" \
    -e "/^  mounts:/r $tmp/mounts" > "$tmp/output.yaml"

mv -f -- "$tmp/output.yaml" ./host/cdi.yaml
