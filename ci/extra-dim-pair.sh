#!/usr/bin/env bash
set -euo pipefail

CONTROL_SHA="b00864ce2ed12e909b00f14486fc5a3e794b9733"
CANDIDATE_SHA="eb8b09307137e78b14710b88b5c310b7938e6825"
REVERTED_SHA="572fa83ace51c3bff0287076502acfca9ddebfff"
KERNELSU_SHA="e8efec31b5f738127b6b0adf607bdfd28994b974"
ANYKERNEL_SHA="04ed56d456f311557f1633b2d67dc5d193b7a59b"
TOOLCHAIN_ARCHIVE_SHA256="1751f120b447f85492b9721212bb7802a7d400b95a55ba266219ba0c542d1c58"

readonly CONTROL_SHA CANDIDATE_SHA REVERTED_SHA KERNELSU_SHA
readonly ANYKERNEL_SHA TOOLCHAIN_ARCHIVE_SHA256

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

require_equal() {
    local expected=$1
    local actual=$2
    local label=$3
    [ "$actual" = "$expected" ] ||
        fail "$label: expected $expected, got $actual"
}

reject_command() {
    local label=$1
    local rc
    shift

    if "$@"; then
        fail "$label"
    else
        rc=$?
        [ "$rc" -eq 1 ] || fail "$label: check exited with $rc"
    fi
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

sorted_changed_files() {
    git -C "$1" diff --name-only "$2" "$3" | LC_ALL=C sort
}

verify_source() {
    local repo=$1
    local output_dir=$2
    local actual_files expected_files candidate_parent hunk_count
    local actual_patch expected_patch patch_sha

    mkdir -p "$output_dir"

    git -C "$repo" cat-file -e "$CONTROL_SHA^{commit}"
    git -C "$repo" cat-file -e "$CANDIDATE_SHA^{commit}"
    git -C "$repo" cat-file -e "$REVERTED_SHA^{commit}"

    candidate_parent=$(git -C "$repo" rev-parse "$CANDIDATE_SHA^")
    require_equal "$CONTROL_SHA" "$candidate_parent" "candidate parent"

    git -C "$repo" merge-base --is-ancestor "$REVERTED_SHA" "$CONTROL_SHA" ||
        fail "$REVERTED_SHA is not an ancestor of $CONTROL_SHA"

    expected_files=$(printf '%s\n' \
        'techpack/display/msm/sde/sde_crtc.c' \
        'techpack/display/msm/sde/sde_plane.c')
    actual_files=$(sorted_changed_files "$repo" "$CONTROL_SHA" "$CANDIDATE_SHA")
    require_equal "$expected_files" "$actual_files" "candidate file allowlist"

    hunk_count=$(git -C "$repo" diff --unified=0 "$CONTROL_SHA" "$CANDIDATE_SHA" |
        awk '/^@@/{count++} END{print count+0}')
    require_equal 4 "$hunk_count" "candidate hunk count"

    actual_patch=$(mktemp)
    expected_patch=$(mktemp)
    git -C "$repo" diff --no-ext-diff --full-index --binary \
        "$CONTROL_SHA" "$CANDIDATE_SHA" -- \
        techpack/display/msm/sde/sde_crtc.c \
        techpack/display/msm/sde/sde_plane.c > "$actual_patch"
    git -C "$repo" diff --no-ext-diff --full-index --binary \
        "$REVERTED_SHA" "$REVERTED_SHA^" -- \
        techpack/display/msm/sde/sde_crtc.c \
        techpack/display/msm/sde/sde_plane.c > "$expected_patch"
    cmp -s "$actual_patch" "$expected_patch" ||
        fail "candidate is not the exact reverse diff of $REVERTED_SHA"

    cp "$actual_patch" "$output_dir/candidate-revert-572fa83.patch"
    rm -f "$actual_patch" "$expected_patch"
    patch_sha=$(sha256_file "$output_dir/candidate-revert-572fa83.patch")

    require_equal "$KERNELSU_SHA" \
        "$(git -C "$repo" rev-parse "$CONTROL_SHA:KernelSU")" \
        "control KernelSU gitlink"
    require_equal "$KERNELSU_SHA" \
        "$(git -C "$repo" rev-parse "$CANDIDATE_SHA:KernelSU")" \
        "candidate KernelSU gitlink"

    if ! git -C "$repo" diff --quiet "$CONTROL_SHA" "$CANDIDATE_SHA" -- \
        build.sh packaging/anykernel.sh \
        arch/arm64/configs/vendor/not/ksu.config \
        arch/arm64/configs/vendor/not/susfs.config; then
        fail "build, packaging, KSU or SUSFS inputs differ between pair"
    fi

    {
        printf 'status=NO-FLASH\n'
        printf 'source_repo=%s\n' "$(git -C "$repo" remote get-url origin)"
        printf 'control_sha=%s\n' "$CONTROL_SHA"
        printf 'control_tree=%s\n' "$(git -C "$repo" rev-parse "$CONTROL_SHA^{tree}")"
        printf 'candidate_sha=%s\n' "$CANDIDATE_SHA"
        printf 'candidate_parent=%s\n' "$candidate_parent"
        printf 'candidate_tree=%s\n' "$(git -C "$repo" rev-parse "$CANDIDATE_SHA^{tree}")"
        printf 'reverted_commit=%s\n' "$REVERTED_SHA"
        printf 'candidate_patch_sha256=%s\n' "$patch_sha"
        printf 'changed_hunks=%s\n' "$hunk_count"
        printf 'changed_files=%s\n' "$(printf '%s' "$actual_files" | paste -sd, -)"
        printf 'kernelsu_gitlink=%s\n' "$KERNELSU_SHA"
        printf 'flash_authorized=no\n'
    } > "$output_dir/SOURCE-VERIFICATION.txt"

    sha256sum \
        "$output_dir/SOURCE-VERIFICATION.txt" \
        "$output_dir/candidate-revert-572fa83.patch" \
        > "$output_dir/SOURCE-SHA256SUMS"
}

write_zip_member_hashes() {
    local zip_file=$1
    local output=$2
    local member member_hash

    : > "$output"
    while IFS= read -r member; do
        member_hash=$(unzip -p "$zip_file" "$member" | sha256sum | awk '{print $1}')
        printf '%s  %s\n' "$member_hash" "$member" >> "$output"
    done < <(unzip -Z1 "$zip_file" | LC_ALL=C sort)
}

verify_zip_members() {
    local zip_file=$1
    local actual expected

    actual=$(unzip -Z1 "$zip_file" | LC_ALL=C sort)
    expected=$(printf '%s\n' \
        'Image' \
        'LICENSE' \
        'META-INF/com/google/android/update-binary' \
        'META-INF/com/google/android/updater-script' \
        'anykernel.sh' \
        'tools/ak3-core.sh' \
        'tools/busybox' \
        'tools/fec' \
        'tools/httools_static' \
        'tools/lptools_static' \
        'tools/magiskboot' \
        'tools/magiskpolicy' \
        'tools/snapshotupdater_static' |
        LC_ALL=C sort)
    require_equal "$expected" "$actual" "AnyKernel member allowlist"
}

verify_effective_config() {
    local config=$1
    local enabled_features expected_features

    grep -qx 'CONFIG_KSU=y' "$config"
    grep -qx 'CONFIG_KSU_SUSFS=y' "$config"
    grep -qx 'CONFIG_KSU_SUSFS_SUS_PATH=y' "$config"
    grep -qx '# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set' "$config"

    expected_features='CONFIG_KSU_SUSFS_SUS_PATH=y'
    enabled_features=$(grep '^CONFIG_KSU_SUSFS_.*=y$' "$config" | LC_ALL=C sort)
    require_equal "$expected_features" "$enabled_features" "enabled SUSFS features"

    reject_command "SUSFS module option enabled" \
        grep -Eq '^CONFIG_KSU_SUSFS_.*=m$' "$config"
    if ! grep -qx '# CONFIG_KPROBES is not set' "$config" &&
       ! grep -qx 'CONFIG_KPROBES=n' "$config"; then
        fail "CONFIG_KPROBES is not disabled"
    fi
    reject_command "CONFIG_KPROBE_EVENTS is enabled" \
        grep -Eq '^CONFIG_KPROBE_EVENTS=(y|m)$' "$config"
}

archive_build() {
    local build_dir=$1
    local role=$2
    local expected_sha=$3
    local output_dir=$4
    local zip_files zip_file image_file clang_file source_repo
    local source_tree source_parent patch_sha anykernel_actual actual_kernelsu

    case "$role" in
        control-a|control-b)
            require_equal "$CONTROL_SHA" "$expected_sha" "$role expected source"
            ;;
        candidate)
            require_equal "$CANDIDATE_SHA" "$expected_sha" "$role expected source"
            ;;
        *)
            fail "unknown build role: $role"
            ;;
    esac

    require_equal "$expected_sha" "$(git -C "$build_dir" rev-parse HEAD)" "$role source"
    [ -z "$(git -C "$build_dir" status --porcelain --untracked-files=no)" ] ||
        fail "$role has tracked or staged worktree changes"

    mapfile -t zip_files < <(find "$build_dir" -maxdepth 1 -type f \
        -name 'YivasKernel-r8q-SUSFS-v2-safe-*.zip' -print)
    require_equal 1 "${#zip_files[@]}" "$role ZIP count"
    zip_file=${zip_files[0]}

    image_file="$build_dir/out/arch/arm64/boot/Image"
    clang_file="$build_dir/tc/clang/bin/clang"
    require_file "$image_file"
    require_file "$build_dir/out/System.map"
    require_file "$build_dir/out/Module.symvers"
    require_file "$build_dir/out/.config"
    require_file "$build_dir/build.log"
    require_file "$clang_file"

    actual_kernelsu=$(git -C "$build_dir/KernelSU" rev-parse HEAD)
    require_equal "$KERNELSU_SHA" "$actual_kernelsu" "$role KernelSU checkout"
    [ -z "$(git -C "$build_dir/KernelSU" status --porcelain)" ] ||
        fail "$role KernelSU checkout is dirty"

    verify_zip_members "$zip_file"
    verify_effective_config "$build_dir/out/.config"

    cmp -s "$image_file" <(unzip -p "$zip_file" Image) ||
        fail "$role packaged Image differs from built Image"
    cmp -s <(git -C "$build_dir" show HEAD:packaging/anykernel.sh) \
        <(unzip -p "$zip_file" anykernel.sh) ||
        fail "$role packaged anykernel.sh differs from source"

    file "$image_file" | grep -q 'Linux kernel ARM64 boot executable Image' ||
        fail "$role Image is not raw ARM64"
    reject_command "$role Image contains fake uname marker" \
        grep -aFq 'fake uname:' "$image_file"
    reject_command "$role source contains forbidden uname spoof" \
        git -C "$build_dir" grep -Eq \
        'FAKE_UNAME|should_spoof_uname|fake uname:' "$expected_sha" -- kernel/sys.c

    grep -Eq '[[:space:]][Tt][[:space:]]__ksu_is_allow_uid$' \
        "$build_dir/out/System.map"
    grep -Eq '[[:space:]][Tt][[:space:]]susfs_add_sus_path$' \
        "$build_dir/out/System.map"

    anykernel_actual=$(git -C "$build_dir/AnyKernel3" rev-parse HEAD)
    require_equal "$ANYKERNEL_SHA" "$anykernel_actual" "$role AnyKernel commit"

    grep -Fxq 'BLOCK=/dev/block/platform/soc/1d84000.ufshc/by-name/boot;' \
        "$build_dir/packaging/anykernel.sh"
    grep -Fxq 'IS_SLOT_DEVICE=0;' "$build_dir/packaging/anykernel.sh"
    grep -Fxq 'NO_VBMETA_PARTITION_PATCH=1;' "$build_dir/packaging/anykernel.sh"
    require_equal 1 "$(grep -c '^split_boot;$' "$build_dir/packaging/anykernel.sh")" \
        "$role split_boot count"
    require_equal 1 "$(grep -c '^flash_boot;$' "$build_dir/packaging/anykernel.sh")" \
        "$role flash_boot count"
    reject_command "$role anykernel.sh contains a forbidden write path" \
        grep -Eq \
        'flash_generic|patch_cmdline|/by-name/(dtbo|vbmeta|vendor_boot|init_boot|recovery_dtbo)|(^|[^A-Z_])dd[[:space:]]' \
        "$build_dir/packaging/anykernel.sh"

    mkdir -p "$output_dir"
    cp "$zip_file" "$output_dir/kernel.zip"
    printf '%s\n' "$(sha256_file "$zip_file")" > "$output_dir/kernel-zip-sha256.txt"
    cp "$image_file" "$output_dir/Image"
    cp "$build_dir/out/System.map" "$output_dir/System.map"
    cp "$build_dir/out/Module.symvers" "$output_dir/Module.symvers"
    cp "$build_dir/out/.config" "$output_dir/kernel.config"
    cp "$build_dir/build.log" "$output_dir/build.log"
    unzip -Z1 "$zip_file" | LC_ALL=C sort > "$output_dir/zip-files.txt"
    write_zip_member_hashes "$zip_file" "$output_dir/zip-member-sha256.txt"

    file "$image_file" > "$output_dir/image.file"
    "$clang_file" --version > "$output_dir/clang-version.txt"
    printf '%s\n' "$(sha256_file "$clang_file")" > "$output_dir/clang-sha256.txt"
    strings -n 4 "$image_file" |
        grep -E 'skip_initramfs|fake uname:|KernelSU|v1\.5\.5' \
        > "$output_dir/image-sensitive-strings.txt" || true
    grep -E '[[:space:]][Tt][[:space:]](__ksu_is_allow_uid|susfs_add_sus_path)$' \
        "$build_dir/out/System.map" > "$output_dir/binary-symbols.txt"

    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Package}=${Version}\n' \
            gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
            > "$output_dir/build-packages.txt"
    else
        printf 'unavailable\n' > "$output_dir/build-packages.txt"
    fi

    source_repo=$(git -C "$build_dir" remote get-url origin)
    source_tree=$(git -C "$build_dir" rev-parse HEAD^{tree})
    source_parent=$(git -C "$build_dir" rev-parse HEAD^)
    patch_sha=$(git -C "$build_dir" show --format= --no-ext-diff --binary HEAD |
        sha256sum | awk '{print $1}')

    {
        printf 'status=NO-FLASH\n'
        printf 'role=%s\n' "$role"
        printf 'device=r8q\n'
        printf 'profile=safe\n'
        printf 'source_repo=%s\n' "$source_repo"
        printf 'source_sha=%s\n' "$expected_sha"
        printf 'source_tree=%s\n' "$source_tree"
        printf 'source_parent=%s\n' "$source_parent"
        printf 'source_patch_sha256=%s\n' "$patch_sha"
        printf 'control_sha=%s\n' "$CONTROL_SHA"
        printf 'candidate_sha=%s\n' "$CANDIDATE_SHA"
        printf 'reverted_commit=%s\n' "$REVERTED_SHA"
        printf 'kernelsu_gitlink=%s\n' "$(git -C "$build_dir" rev-parse HEAD:KernelSU)"
        printf 'kernelsu_checkout_sha=%s\n' "$actual_kernelsu"
        printf 'anykernel3_sha=%s\n' "$anykernel_actual"
        printf 'toolchain_archive_sha256=%s\n' "$TOOLCHAIN_ARCHIVE_SHA256"
        printf 'clang_sha256=%s\n' "$(sha256_file "$clang_file")"
        printf 'zip_sha256=%s\n' "$(sha256_file "$zip_file")"
        printf 'image_sha256=%s\n' "$(sha256_file "$image_file")"
        printf 'config_sha256=%s\n' "$(sha256_file "$build_dir/out/.config")"
        printf 'workflow_sha=%s\n' "${GITHUB_SHA:-local}"
        printf 'workflow_ref=%s\n' "${GITHUB_REF:-local}"
        printf 'workflow_run_id=%s\n' "${GITHUB_RUN_ID:-local}"
        printf 'runner_os=%s\n' "${RUNNER_OS:-unknown}"
        printf 'runner_arch=%s\n' "${RUNNER_ARCH:-unknown}"
        printf 'runner_image=%s\n' "${ImageOS:-unknown}/${ImageVersion:-unknown}"
        printf 'flash_authorized=no\n'
    } > "$output_dir/BUILD-MANIFEST.txt"

    sha256sum \
        "$output_dir/kernel-zip-sha256.txt" \
        "$output_dir/Image" \
        "$output_dir/System.map" \
        "$output_dir/Module.symvers" \
        "$output_dir/kernel.config" \
        "$output_dir/BUILD-MANIFEST.txt" \
        "$output_dir/binary-symbols.txt" \
        "$output_dir/build.log" \
        "$output_dir/image.file" \
        "$output_dir/zip-files.txt" \
        "$output_dir/zip-member-sha256.txt" \
        "$output_dir/clang-version.txt" \
        "$output_dir/clang-sha256.txt" \
        "$output_dir/image-sensitive-strings.txt" \
        "$output_dir/build-packages.txt" \
        > "$output_dir/SHA256SUMS"
}

compare_builds() {
    local control_a=$1
    local control_b=$2
    local candidate=$3
    local output_dir=$4
    local control_image candidate_image

    cmp -s "$control_a/Image" "$control_b/Image" ||
        fail "control Image is not reproducible"
    cmp -s "$control_a/kernel.zip" "$control_b/kernel.zip" ||
        fail "control ZIP is not reproducible"
    cmp -s "$control_a/System.map" "$control_b/System.map" ||
        fail "control System.map is not reproducible"
    cmp -s "$control_a/Module.symvers" "$control_b/Module.symvers" ||
        fail "control Module.symvers is not reproducible"
    cmp -s "$control_a/kernel.config" "$control_b/kernel.config" ||
        fail "control config is not reproducible"

    cmp -s "$control_a/kernel.config" "$candidate/kernel.config" ||
        fail "control and candidate configs differ"
    cmp -s "$control_a/zip-files.txt" "$candidate/zip-files.txt" ||
        fail "control and candidate ZIP member lists differ"
    cmp -s "$control_a/clang-sha256.txt" "$candidate/clang-sha256.txt" ||
        fail "control and candidate clang binaries differ"

    diff -u \
        <(grep -v '  Image$' "$control_a/zip-member-sha256.txt") \
        <(grep -v '  Image$' "$candidate/zip-member-sha256.txt") \
        > "$output_dir/non-image-member.diff" ||
        fail "control and candidate non-Image ZIP members differ"

    if cmp -s "$control_a/Image" "$candidate/Image"; then
        fail "candidate Image is byte-identical to control"
    fi

    control_image=$(sha256_file "$control_a/Image")
    candidate_image=$(sha256_file "$candidate/Image")

    {
        printf 'status=NO-FLASH\n'
        printf 'control_sha=%s\n' "$CONTROL_SHA"
        printf 'candidate_sha=%s\n' "$CANDIDATE_SHA"
        printf 'control_reproducible=yes\n'
        printf 'config_equal=yes\n'
        printf 'toolchain_equal=yes\n'
        printf 'zip_members_equal=yes\n'
        printf 'non_image_members_equal=yes\n'
        printf 'control_image_sha256=%s\n' "$control_image"
        printf 'candidate_image_sha256=%s\n' "$candidate_image"
        printf 'image_differs=yes\n'
        printf 'dryrun_status=not-started\n'
        printf 'flash_authorized=no\n'
    } > "$output_dir/COMPARISON-MANIFEST.txt"

    sha256sum \
        "$output_dir/COMPARISON-MANIFEST.txt" \
        "$output_dir/non-image-member.diff" \
        > "$output_dir/COMPARISON-SHA256SUMS"
}

usage() {
    cat <<'EOF'
Usage:
  extra-dim-pair.sh source <repo> <output-dir>
  extra-dim-pair.sh archive <build-dir> <role> <expected-sha> <output-dir>
  extra-dim-pair.sh compare <control-a> <control-b> <candidate> <output-dir>
EOF
}

command=${1:-}
case "$command" in
    source)
        [ "$#" -eq 3 ] || { usage >&2; exit 2; }
        verify_source "$2" "$3"
        ;;
    archive)
        [ "$#" -eq 5 ] || { usage >&2; exit 2; }
        archive_build "$2" "$3" "$4" "$5"
        ;;
    compare)
        [ "$#" -eq 5 ] || { usage >&2; exit 2; }
        compare_builds "$2" "$3" "$4" "$5"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
