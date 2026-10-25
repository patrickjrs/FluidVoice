#!/bin/bash

# FluidVoice Build Profile Router
# Defaults to the public OSS build, which skips private Fluid Intelligence.
#
# Usage:
#   ./build.sh                    # signed public OSS build (falls back to CLT if Xcode.app is absent)
#   ./build.sh public             # signed public OSS build
#   ./build.sh unsigned           # unsigned public OSS build (CI/fallback)
#   ./build.sh clt                # Command Line Tools (swift build) public OSS build
#   ./build.sh fi                 # private FI build

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-${BUILD_PROFILE:-public}}"
PRIVATE_FI_BUILD_SCRIPT="${PROJECT_DIR}/build_with_FI_incremental.sh"
DERIVED_DATA_PATH="${FLUIDVOICE_DERIVED_DATA_PATH:-${PROJECT_DIR}/DerivedData}"

resolve_development_team() {
    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | awk 'NR == 1 { identity = $0 } END { print identity }')"
    [ -n "${identity}" ] || return 0

    if [ -n "${FLUIDVOICE_DEVELOPMENT_TEAM:-}" ]; then
        printf '%s\n' "${FLUIDVOICE_DEVELOPMENT_TEAM}"
        return
    fi

    security find-certificate -c "${identity}" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/.*OU=\([^,]*\).*/\1/p'
}

resolve_development_identity_hash() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.* \([[:xdigit:]]\{40\}\) "Apple Development:[^"]*".*/\1/p' \
        | awk 'NR == 1 { print; exit }'
}

replace_with_symlink() {
    local path="$1"
    local target="$2"

    if [ -L "${path}" ] || [ -f "${path}" ]; then
        rm -f "${path}"
    elif [ -d "${path}" ]; then
        rm -R "${path}"
    elif [ -e "${path}" ]; then
        echo "Unexpected file type at ${path}" >&2
        return 1
    fi

    ln -s "${target}" "${path}"
}

has_xcodebuild() {
    if [ "${FLUIDVOICE_USE_CLT:-0}" = "1" ]; then
        return 1
    fi
    xcodebuild -version >/dev/null 2>&1
}

stage_clt_assets() {
    local resources_dir="$1"
    local xcassets_dir="${PROJECT_DIR}/Sources/Fluid/Assets.xcassets"
    local appiconset_dir="${xcassets_dir}/AppIcon.appiconset"
    local tmp_iconset_root
    local tmp_iconset_dir
    local imageset_dir
    local set_name

    if [ -d "${appiconset_dir}" ] && command -v iconutil >/dev/null 2>&1; then
        tmp_iconset_root="$(mktemp -d -t fluidvoice-iconset)"
        tmp_iconset_dir="${tmp_iconset_root}/AppIcon.iconset"
        mkdir -p "${tmp_iconset_dir}"
        cp "${appiconset_dir}/icon-16@1x.png" "${tmp_iconset_dir}/icon_16x16.png"
        cp "${appiconset_dir}/icon-16@2x.png" "${tmp_iconset_dir}/icon_16x16@2x.png"
        cp "${appiconset_dir}/icon-32@1x.png" "${tmp_iconset_dir}/icon_32x32.png"
        cp "${appiconset_dir}/icon-32@2x.png" "${tmp_iconset_dir}/icon_32x32@2x.png"
        cp "${appiconset_dir}/icon-128@1x.png" "${tmp_iconset_dir}/icon_128x128.png"
        cp "${appiconset_dir}/icon-128@2x.png" "${tmp_iconset_dir}/icon_128x128@2x.png"
        cp "${appiconset_dir}/icon-256@1x.png" "${tmp_iconset_dir}/icon_256x256.png"
        cp "${appiconset_dir}/icon-256@2x.png" "${tmp_iconset_dir}/icon_256x256@2x.png"
        cp "${appiconset_dir}/icon-512@1x.png" "${tmp_iconset_dir}/icon_512x512.png"
        cp "${appiconset_dir}/icon-512@2x.png" "${tmp_iconset_dir}/icon_512x512@2x.png"
        iconutil -c icns "${tmp_iconset_dir}" -o "${resources_dir}/AppIcon.icns"
        rm -rf "${tmp_iconset_root}"
    fi

    for imageset_dir in "${xcassets_dir}"/*.imageset; do
        [ -d "${imageset_dir}" ] || continue
        set_name="$(basename "${imageset_dir}" .imageset)"
        if [ "${set_name}" = "MenuBarIcon" ]; then
            [ -f "${imageset_dir}/menubar-icon.png" ] && cp "${imageset_dir}/menubar-icon.png" "${resources_dir}/MenuBarIcon.png"
            [ -f "${imageset_dir}/menubar-icon@2x.png" ] && cp "${imageset_dir}/menubar-icon@2x.png" "${resources_dir}/MenuBarIcon@2x.png"
            [ -f "${imageset_dir}/menubar-icon@3x.png" ] && cp "${imageset_dir}/menubar-icon@3x.png" "${resources_dir}/MenuBarIcon@3x.png"
        elif [ "${set_name}" = "BrandWordmark" ]; then
            [ -f "${imageset_dir}/BrandWordmark.png" ] && cp "${imageset_dir}/BrandWordmark.png" "${resources_dir}/BrandWordmark.png"
            [ -f "${imageset_dir}/BrandWordmark@2x.png" ] && cp "${imageset_dir}/BrandWordmark@2x.png" "${resources_dir}/BrandWordmark@2x.png"
        else
            [ -f "${imageset_dir}/logo.png" ] && cp "${imageset_dir}/logo.png" "${resources_dir}/${set_name}.png"
            [ -f "${imageset_dir}/logo@2x.png" ] && cp "${imageset_dir}/logo@2x.png" "${resources_dir}/${set_name}@2x.png"
        fi
    done
}

run_clt_public_build() {
    local signing_mode="$1"
    local development_team=""
    local signing_identity_hash=""
    local developer_dir
    local intermediates_dir="${DERIVED_DATA_PATH}/Build/Intermediates.noindex"
    local macro_plugin="${intermediates_dir}/clt_macro_plugin"
    local app_path="${DERIVED_DATA_PATH}/Build/Products/Debug/FluidVoice.app"
    local contents_dir="${app_path}/Contents"
    local macos_dir="${contents_dir}/MacOS"
    local helpers_dir="${contents_dir}/Helpers"
    local frameworks_dir="${contents_dir}/Frameworks"
    local resources_dir="${contents_dir}/Resources"
    local ctranscribe_framework="${frameworks_dir}/CTranscribe.framework"
    local bin_dir
    local host_arch

    cd "${PROJECT_DIR}"
    developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
    host_arch="$(uname -m)"

    if [ "${signing_mode}" = "signed" ]; then
        signing_identity_hash="$(resolve_development_identity_hash)"
        development_team="$(resolve_development_team)"
        if [ -z "${development_team}" ] || [ -z "${signing_identity_hash}" ]; then
            if [ -n "${FLUIDVOICE_DEVELOPMENT_TEAM:-}" ]; then
                printf >&2 'FLUIDVOICE_DEVELOPMENT_TEAM is set to %s, but no Apple Development signing identity was found.\n' \
                    "${FLUIDVOICE_DEVELOPMENT_TEAM}"
                exit 1
            fi
            echo "No Apple Development signing identity found; falling back to ad-hoc signing for Command Line Tools build."
            signing_mode="unsigned"
        fi
    fi

    echo "Building FluidVoice using Xcode Command Line Tools (${developer_dir})..."
    mkdir -p "${intermediates_dir}"
    xcrun clang -O2 "${PROJECT_DIR}/scripts/clt_macro_plugin.c" -o "${macro_plugin}"

    swift build -c debug --product FluidVoice \
        -Xswiftc -load-plugin-executable \
        -Xswiftc "${macro_plugin}#SwiftUIMacros,PreviewsMacros"

    bin_dir="$(swift build -c debug --show-bin-path)"
    if [ ! -x "${bin_dir}/FluidVoice" ]; then
        echo "Built FluidVoice binary is missing at ${bin_dir}/FluidVoice" >&2
        exit 1
    fi

    echo "Assembling app bundle at ${app_path}..."
    rm -rf "${app_path}" "${DERIVED_DATA_PATH}/Build/Products/Debug/FluidVoice Debug.app"
    mkdir -p "${macos_dir}" "${helpers_dir}" "${frameworks_dir}" "${resources_dir}"

    cp "${bin_dir}/FluidVoice" "${macos_dir}/FluidVoice"
    chmod +x "${macos_dir}/FluidVoice"

    echo "Compiling fv-serve helper..."
    xcrun swiftc -O \
        -target "${host_arch}-apple-macosx15.0" \
        -module-name FVServe \
        "${PROJECT_DIR}/Sources/FVServe/main.swift" \
        "${PROJECT_DIR}/Sources/Fluid/Services/FluidServe/FluidServeCommand.swift" \
        "${PROJECT_DIR}/Sources/Fluid/Services/FluidServe/FluidServeMeetings.swift" \
        "${PROJECT_DIR}/Sources/Fluid/Services/FluidServe/FluidServeSkill.swift" \
        -o "${helpers_dir}/fv-serve"
    chmod +x "${helpers_dir}/fv-serve"

    printf 'APPL????' > "${contents_dir}/PkgInfo"

    sed \
        -e 's/\$(EXECUTABLE_NAME)/FluidVoice/g' \
        -e 's/\$(PRODUCT_NAME)/FluidVoice/g' \
        -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.FluidApp.app/g' \
        -e 's/\$(MACOSX_DEPLOYMENT_TARGET)/15.0/g' \
        "${PROJECT_DIR}/Info.plist" > "${contents_dir}/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${contents_dir}/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${contents_dir}/Info.plist"

    if [ -d "${PROJECT_DIR}/Sources/Fluid/Resources" ]; then
        cp -R "${PROJECT_DIR}/Sources/Fluid/Resources/"* "${resources_dir}/"
    fi
    if [ -d "${PROJECT_DIR}/Vendor/WebRTCAudioProcessing/Notices" ]; then
        cp -R "${PROJECT_DIR}/Vendor/WebRTCAudioProcessing/Notices" "${resources_dir}/Notices"
    fi
    stage_clt_assets "${resources_dir}"

    if [ ! -d "${bin_dir}/CTranscribe.framework" ]; then
        echo "CTranscribe.framework is missing at ${bin_dir}/CTranscribe.framework" >&2
        exit 1
    fi
    cp -R "${bin_dir}/CTranscribe.framework" "${ctranscribe_framework}"
    replace_with_symlink "${ctranscribe_framework}/Versions/Current" "A"
    replace_with_symlink "${ctranscribe_framework}/CTranscribe" "Versions/Current/CTranscribe"
    replace_with_symlink "${ctranscribe_framework}/Resources" "Versions/Current/Resources"
    if [ -e "${ctranscribe_framework}/Headers" ] || [ -L "${ctranscribe_framework}/Headers" ]; then
        replace_with_symlink "${ctranscribe_framework}/Headers" "Versions/Current/Headers"
    fi
    if [ -e "${ctranscribe_framework}/Modules" ] || [ -L "${ctranscribe_framework}/Modules" ]; then
        replace_with_symlink "${ctranscribe_framework}/Modules" "Versions/Current/Modules"
    fi

    if [ -f "${developer_dir}/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib" ]; then
        cp "${developer_dir}/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib" "${frameworks_dir}/"
    fi

    if [ "${signing_mode}" = "signed" ]; then
        echo "Signing app bundle with Apple Development identity..."
        codesign --force --sign "${signing_identity_hash}" \
            --options runtime --timestamp=none "${ctranscribe_framework}"
        if [ -f "${frameworks_dir}/libswiftCompatibilitySpan.dylib" ]; then
            codesign --force --sign "${signing_identity_hash}" \
                --options runtime --timestamp=none "${frameworks_dir}/libswiftCompatibilitySpan.dylib"
        fi
        codesign --force --sign "${signing_identity_hash}" \
            --options runtime --timestamp=none "${helpers_dir}/fv-serve"
        codesign --force --sign "${signing_identity_hash}" \
            --options runtime --timestamp=none \
            --entitlements "${PROJECT_DIR}/Fluid.entitlements" "${app_path}"
    else
        echo "Ad-hoc signing app bundle (unsigned mode)..."
        codesign --force --sign - "${ctranscribe_framework}"
        if [ -f "${frameworks_dir}/libswiftCompatibilitySpan.dylib" ]; then
            codesign --force --sign - "${frameworks_dir}/libswiftCompatibilitySpan.dylib"
        fi
        codesign --force --sign - "${helpers_dir}/fv-serve"
        codesign --force --sign - \
            --entitlements "${PROJECT_DIR}/Fluid.entitlements" "${app_path}"
    fi

    if [ ! -x "${app_path}/Contents/Helpers/fv-serve" ]; then
        echo "fv-serve is missing from the built app: ${app_path}" >&2
        exit 1
    fi

    echo "Verifying the built app..."
    codesign --verify --deep --strict "${app_path}"
    echo "Build complete: ${app_path}"
}

run_public_build() {
    local signing_mode="$1"
    local development_team
    local signing_identity_hash
    local app_path
    local ctranscribe_framework
    local ctranscribe_versions
    local ctranscribe_version_a
    local ctranscribe_version_a_binary
    local ctranscribe_version_a_resources
    local ctranscribe_current
    local ctranscribe_root_binary
    local ctranscribe_root_resources
    local entitlements_file
    local -a build_args=(
        -project Fluid.xcodeproj
        -scheme Fluid
        -configuration Debug
        -destination 'platform=macOS'
        -derivedDataPath "${DERIVED_DATA_PATH}"
        build
    )

    cd "${PROJECT_DIR}"

    if ! has_xcodebuild; then
        run_clt_public_build "${signing_mode}"
        return
    fi

    if [ "${signing_mode}" = "unsigned" ]; then
        echo "Running unsigned public FluidVoice build..."
        echo "Accessibility, Screen Recording, and microphone permissions may need to be granted again after rebuilding."
        exec xcodebuild "${build_args[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
    fi

    signing_identity_hash="$(resolve_development_identity_hash)"
    development_team="$(resolve_development_team)"
    if [ -z "${development_team}" ]; then
        if [ -n "${FLUIDVOICE_DEVELOPMENT_TEAM:-}" ]; then
            printf >&2 'FLUIDVOICE_DEVELOPMENT_TEAM is set to %s, but no Apple Development signing identity was found.\n\n' \
                "${FLUIDVOICE_DEVELOPMENT_TEAM}"
            printf >&2 '%s\n\n' \
                "The team override selects an installed signing identity; it does not replace a certificate."
        else
            printf >&2 'No Apple Development signing identity was found.\n\n'
        fi

        cat >&2 <<'EOF'
For stable Accessibility permission across rebuilds, add any Apple Account in:
  Xcode > Settings > Accounts

Then open Manage Certificates and create an Apple Development certificate.

A free Personal Team is sufficient for local development. If you have multiple
teams, set FLUIDVOICE_DEVELOPMENT_TEAM to the desired 10-character Team ID.

To build without signing instead, run:
  ./build.sh unsigned

Unsigned builds may require Accessibility, Screen Recording, and microphone permissions again after rebuilding.
EOF
        exit 1
    fi

    if [ -z "${signing_identity_hash}" ]; then
        echo "Unable to resolve the Apple Development signing identity hash." >&2
        exit 1
    fi

    echo "Running signed public FluidVoice build..."
    echo "Build product: ${DERIVED_DATA_PATH}/Build/Products/Debug/FluidVoice Debug.app"
    xcodebuild "${build_args[@]}" DEVELOPMENT_TEAM="${development_team}"

    app_path="${DERIVED_DATA_PATH}/Build/Products/Debug/FluidVoice Debug.app"
    ctranscribe_framework="${app_path}/Contents/Frameworks/CTranscribe.framework"
    if [ ! -d "${app_path}" ]; then
        echo "Signed build product is missing: ${app_path}" >&2
        exit 1
    fi
    if [ ! -d "${ctranscribe_framework}" ]; then
        echo "Signed CTranscribe framework is missing: ${ctranscribe_framework}" >&2
        exit 1
    fi

    ctranscribe_versions="${ctranscribe_framework}/Versions"
    ctranscribe_version_a="${ctranscribe_versions}/A"
    ctranscribe_version_a_binary="${ctranscribe_version_a}/CTranscribe"
    ctranscribe_version_a_resources="${ctranscribe_version_a}/Resources"
    ctranscribe_current="${ctranscribe_versions}/Current"
    ctranscribe_root_binary="${ctranscribe_framework}/CTranscribe"
    ctranscribe_root_resources="${ctranscribe_framework}/Resources"
    if [ ! -d "${ctranscribe_versions}" ] || [ -L "${ctranscribe_versions}" ]; then
        echo "CTranscribe.framework has no regular Versions directory: ${ctranscribe_versions}" >&2
        exit 1
    fi
    if [ ! -d "${ctranscribe_version_a}" ] || [ -L "${ctranscribe_version_a}" ]; then
        echo "CTranscribe.framework has no regular Versions/A directory: ${ctranscribe_version_a}" >&2
        exit 1
    fi
    if [ ! -f "${ctranscribe_version_a_binary}" ] || [ -L "${ctranscribe_version_a_binary}" ]; then
        echo "CTranscribe.framework Versions/A/CTranscribe is not a regular file: ${ctranscribe_version_a_binary}" >&2
        exit 1
    fi
    if [ ! -d "${ctranscribe_version_a_resources}" ] || [ -L "${ctranscribe_version_a_resources}" ]; then
        echo "CTranscribe.framework Versions/A/Resources is not a regular directory: ${ctranscribe_version_a_resources}" >&2
        exit 1
    fi

    echo "Normalizing CTranscribe.framework layout..."
    replace_with_symlink "${ctranscribe_current}" "A"
    replace_with_symlink "${ctranscribe_root_binary}" "Versions/Current/CTranscribe"
    replace_with_symlink "${ctranscribe_root_resources}" "Versions/Current/Resources"

    echo "Re-sealing CTranscribe.framework with the resolved Apple Development identity..."
    codesign --force --sign "${signing_identity_hash}" \
        --options runtime --timestamp=none \
        --preserve-metadata=identifier,requirements,flags "${ctranscribe_framework}"

    entitlements_file="$(mktemp -t fluidvoice-entitlements)"
    if ! codesign --display --entitlements :- "${app_path}" > "${entitlements_file}" 2>/dev/null; then
        rm -f "${entitlements_file}"
        echo "Unable to read existing app entitlements: ${app_path}" >&2
        exit 1
    fi

    echo "Re-signing the app while preserving its existing entitlements..."
    if [ -s "${entitlements_file}" ]; then
        if ! codesign --force --sign "${signing_identity_hash}" \
            --options runtime --timestamp=none \
            --preserve-metadata=identifier,requirements,flags \
            --entitlements "${entitlements_file}" "${app_path}"; then
            rm -f "${entitlements_file}"
            echo "Unable to re-sign the app: ${app_path}" >&2
            exit 1
        fi
    else
        if ! codesign --force --sign "${signing_identity_hash}" \
            --options runtime --timestamp=none \
            --preserve-metadata=identifier,requirements,flags "${app_path}"; then
            rm -f "${entitlements_file}"
            echo "Unable to re-sign the app: ${app_path}" >&2
            exit 1
        fi
    fi
    rm -f "${entitlements_file}"

    # fv-serve is embedded and signed by the Xcode build; fail here rather than ship an app without it.
    if [ ! -x "${app_path}/Contents/Helpers/fv-serve" ]; then
        echo "fv-serve is missing from the built app: ${app_path}" >&2
        exit 1
    fi

    echo "Verifying the signed app..."
    codesign --verify --deep --strict "${app_path}"
}

case "${PROFILE}" in
    public|oss|incremental|fast)
        run_public_build signed
        ;;
    unsigned|ci)
        run_public_build unsigned
        ;;
    clt)
        FLUIDVOICE_USE_CLT=1 run_public_build signed
        ;;
    fi|private|dev|full)
        if [ ! -x "${PRIVATE_FI_BUILD_SCRIPT}" ]; then
            echo "Private Fluid Intelligence build script is missing:"
            echo "  ${PRIVATE_FI_BUILD_SCRIPT}"
            echo "Restore the private FI build setup, then run: sh build_with_FI_incremental.sh"
            exit 1
        fi
        exec "${PRIVATE_FI_BUILD_SCRIPT}"
        ;;
    *)
        echo "Unknown build profile: ${PROFILE}"
        echo "Valid profiles: public/oss/incremental/fast, unsigned/ci, clt, fi/private/dev/full"
        exit 1
        ;;
esac
