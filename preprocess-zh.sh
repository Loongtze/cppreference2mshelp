#!/bin/bash
for i in "$@"
do
  case $i in
    _7Z=*)
      _7Z="${i#*=}"
      shift # past argument=value
    ;;
    VERSION=*)
      VERSION="${i#*=}"
      shift # past argument=value
    ;;
    UPSTREAM=*)
      UPSTREAM="${i#*=}"
      shift # past argument=value
    ;;
    SOURCE_ARCHIVE=*|RAW_ARCHIVE=*)
      SOURCE_ARCHIVE="${i#*=}"
      shift # past argument=value
    ;;
    WORKTREE_ARCHIVE=*|CPPREFERENCE_DOC_ARCHIVE=*)
      WORKTREE_ARCHIVE="${i#*=}"
      shift # past argument=value
    ;;
    LEGACY_ARCHIVE=*)
      LEGACY_ARCHIVE="${i#*=}"
      shift # past argument=value
    ;;
    FRESH=*)
      FRESH="${i#*=}"
      shift # past argument=value
    ;;
    *)
      # unknown option
    ;;
  esac
done

set -e

abs_path(){
    local path="$1"
    local dir
    local base
    if [[ "${path}" = /* ]]; then
        printf '%s\n' "${path}"
        return 0
    fi
    dir="$(dirname "${path}")"
    base="$(basename "${path}")"
    if [[ ! -d "${dir}" ]]; then
        echo "path directory not found: ${dir}" >&2
        exit 1
    fi
    printf '%s/%s\n' "$(cd "${dir}" && pwd)" "${base}"
}

need_7z(){
    if [[ -z "${_7Z}" ]]; then
        echo "7z not found; pass _7Z=/path/to/7z" >&2
        exit 1
    fi
}

extract_archive(){
    local archive="$1"
    case "${archive}" in
        *.tar|*.tar.*|*.tgz|*.tbz2|*.txz)
            tar xf "${archive}"
        ;;
        *.7z)
            need_7z
            "${_7Z}" x -y "${archive}"
        ;;
        *)
            echo "unsupported archive type: ${archive}" >&2
            exit 1
        ;;
    esac
}

patch_marker_present(){
    case "$1" in
        ../zh.diff|../zh-p12tic.diff)
            grep -q 'cppreference-doc-zh-cpp' Makefile &&
                grep -q 'zh.cppreference.com' Makefile
        ;;
        ../preprocess_cssless.diff)
            grep -q 'allow_loading_external_files=True' \
                commands/preprocess_cssless.py
        ;;
        ../preprocess_premailer.diff)
            grep -q 'CsslessPremailer' commands/preprocess_cssless.py &&
                grep -q 'failed to preprocess' preprocess_qch.py
        ;;
        ../upstream-layout.diff)
            grep -q 'LOADER_ALIASES' commands/preprocess.py &&
                grep -q 'convert_loader_name' commands/preprocess.py &&
                grep -q 'preprocess_startup_script' preprocess.py
        ;;
        *)
            return 1
        ;;
    esac
}

apply_patch_once(){
    local patch="$1"
    local apply_args=(-3)
    local check_args=(--reverse --check)
    if [[ "${patch}" = "../preprocess_premailer.diff" ]]; then
        apply_args=(--unidiff-zero)
        check_args=(--unidiff-zero --reverse --check)
    fi
    if git apply "${check_args[@]}" "${patch}" >/dev/null 2>&1; then
        echo "patch already applied: ${patch}"
        return 0
    fi
    if patch_marker_present "${patch}"; then
        echo "patch appears integrated: ${patch}"
        return 0
    fi
    echo "applying patch: ${patch}"
    git apply "${apply_args[@]}" "${patch}"
}

ensure_raw_reference(){
    if [[ ! -d reference/zh.cppreference.com ]]; then
        echo "reference/ does not look like raw zh.cppreference.com input" >&2
        echo "pass SOURCE_ARCHIVE=... to replace it, or remove it first" >&2
        exit 1
    fi
}

clean_processed_outputs(){
    rm -rf output/reference
    clean_derived_outputs
}

clean_derived_outputs(){
    rm -rf output/reference_cssless
    rm -f output/link-map.xml \
        output/cppreference-doc-zh-c.devhelp2 \
        output/cppreference-doc-zh-cpp.devhelp2 \
        output/cppreference-doc-zh-cpp.qch \
        output/cppreference-doxygen-web.tag.xml \
        output/cppreference-doxygen-local.tag.xml \
        output/devhelp-index-c.xml \
        output/devhelp-index-cpp.xml \
        output/qch-files.xml \
        output/qch-help-project-cpp.xml
}

prepend_once(){
    local filename="$1"
    local line="$2"
    find -iname "${filename}" -type f -print0 | while IFS= read -r -d '' file; do
        if ! head -n 1 "${file}" | grep -Fxq "${line}"; then
            sed -i "1 i ${line}" "${file}"
        fi
    done
}

_7Z="${_7Z:-$(command -v 7z || true)}"
need_7z

if [[ -n "${SOURCE_ARCHIVE:-}" ]]; then
    SOURCE_ARCHIVE="$(abs_path "${SOURCE_ARCHIVE}")"
fi
if [[ -n "${WORKTREE_ARCHIVE:-}" ]]; then
    WORKTREE_ARCHIVE="$(abs_path "${WORKTREE_ARCHIVE}")"
fi
LEGACY_ARCHIVE="$(abs_path "${LEGACY_ARCHIVE:-cppreference-unprocessed-20250404.7z}")"

if [[ "${FRESH:-0}" = "1" ]]; then
    rm -rf cppreference-doc
fi

if [[ -d cppreference-doc/.git ]]; then
  echo "using existing cppreference-doc worktree"
  cd cppreference-doc
elif [[ -e cppreference-doc ]]; then
  echo "cppreference-doc exists but is not a git worktree" >&2
  echo "remove it, rename it, or rerun with FRESH=1" >&2
  exit 1
elif [[ -n "${WORKTREE_ARCHIVE:-}" ]]; then
  echo "extracting cppreference-doc worktree from ${WORKTREE_ARCHIVE}"
  extract_archive "${WORKTREE_ARCHIVE}"
  cd cppreference-doc
elif [[ "${UPSTREAM:-}" = "p12tic" ]]; then
  git clone https://github.com/p12tic/cppreference-doc.git --filter=tree:0
  cd cppreference-doc
else
  git clone https://github.com/PeterFeicht/cppreference-doc.git --filter=tree:0
  cd cppreference-doc
fi

if [[ "${UPSTREAM:-}" = "p12tic" ]]; then
    patches=(../zh-p12tic.diff ../preprocess_cssless.diff \
        ../preprocess_premailer.diff ../upstream-layout.diff)
else
    patches=(../zh.diff ../preprocess_cssless.diff \
        ../preprocess_premailer.diff ../upstream-layout.diff)
fi
for patch in "${patches[@]}"; do
    apply_patch_once "${patch}"
done

VERSION="${VERSION:-$(date +%Y%m%d)}"
sed -i "/^VERSION=/cVERSION=${VERSION}" Makefile

resume_from_processed=0
resume_from_output=0
if [[ -n "${SOURCE_ARCHIVE:-}" ]]; then
  [[ -f "${SOURCE_ARCHIVE}" ]] || {
    echo "source archive not found: ${SOURCE_ARCHIVE}" >&2
    exit 1
  }
  rm -rf reference
  extract_archive "${SOURCE_ARCHIVE}"
  ensure_raw_reference
  clean_processed_outputs
elif [[ -d reference ]]; then
  if [[ -d reference/zh.cppreference.com ]]; then
    echo "using existing raw reference source tree"
    clean_processed_outputs
  elif [[ -d reference/common && -d reference/zh ]]; then
    echo "resuming from preprocessed reference tree"
    resume_from_processed=1
    clean_derived_outputs
  else
    echo "reference/ is neither raw nor preprocessed cppreference input" >&2
    echo "pass SOURCE_ARCHIVE=... to replace it, or remove it first" >&2
    exit 1
  fi
elif [[ -d output/reference/common && -d output/reference/zh ]]; then
  echo "resuming from output/reference"
  resume_from_output=1
  clean_derived_outputs
else
  make source
  ensure_raw_reference
  clean_processed_outputs
fi


# init files and vars
startup_scripts_replace="startup_scripts.js"
startup_scripts_path=""

site_scripts_replace="site_scripts.js"
site_scripts_path=""

site_modules_replace="site_modules.css"
site_modules_path=""

skin_scripts_replace="skin_scripts.js"
skin_scripts_path=""

ext_replace="ext.css"
ext_path=""

LIST="startup_scripts site_scripts site_modules skin_scripts ext"
extra_fonts="DejaVuSans.ttf DejaVuSans-Bold.ttf DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf DejaVuSansMonoCondensed60.ttf DejaVuSansMonoCondensed75.ttf"
legacy_archive="${LEGACY_ARCHIVE}"

CPUS="$(cat /proc/cpuinfo | grep -c '^processor')"
font_path=""

restore_from_legacy_archive(){
    local archive="$1"
    local source="$2"
    local target="$3"
    if [[ ! -f "${archive}" || -e "${target}" ]]; then
        return 0
    fi
    mkdir -p "$(dirname "${target}")"
    local temp="${target}.tmp"
    if "${_7Z}" x -so "${archive}" "${source}" > "${temp}" && [[ -s "${temp}" ]]; then
        mv -f "${temp}" "${target}"
        return 0
    fi
    rm -f "${temp}"
}

restore_legacy_assets(){
    local archive="$1"
    if [[ ! -f "${archive}" ]]; then
        echo "legacy archive ${archive} not found; skipping static fallback restore"
        return 0
    fi

    for i in $extra_fonts; do
        restore_from_legacy_archive \
            "${archive}" \
            "reference/zh.cppreference.com/${i}" \
            "reference/zh.cppreference.com/${i}"
    done
    restore_from_legacy_archive \
        "${archive}" \
        "reference/zh.cppreference.com/favicon.ico" \
        "reference/zh.cppreference.com/favicon.ico"

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        if [[ "${path}" == *"/mwiki/skins/cppreference2/images/"* ]]; then
            local name="${path##*/}"
            name="${name%@*}"
            if [[ -e "reference/zh.cppreference.com/skins/Cppreference2/resources/images/${name}" ]] ||
               compgen -G "reference/zh.cppreference.com/skins/Cppreference2/resources/images/${name}@*" >/dev/null; then
                continue
            fi
        fi
        local target="${path#reference/zh.cppreference.com/mwiki/}"
        restore_from_legacy_archive \
            "${archive}" \
            "${path}" \
            "reference/zh.cppreference.com/mwiki/${target}"
    done < <("${_7Z}" l -ba "${archive}" | awk '{print $NF}' | grep -E \
        'reference/zh\.cppreference\.com/mwiki/skins/(common|cppreference2|vector)/images/.*\.(png|gif|ico)(@.*)?$' || true)

    restore_from_legacy_archive \
        "${archive}" \
        "reference/upload.cppreference.com/mwiki/images/2/23/Icons-mini-file_acrobat.gif" \
        "reference/upload.cppreference.com/mwiki/images/2/23/Icons-mini-file_acrobat.gif"
}

if [[ "${resume_from_output}" != "1" && "${resume_from_processed}" != "1" ]]; then
    pushd reference
    python3 ../../fix_mirror.py
    if [[ -s urls_to_download.txt ]]; then
      wget --force-directories --retry-connrefused --waitretry=2 --read-timeout=13 --trust-server-names -i urls_to_download.txt
      rm -f urls_to_download.txt
    fi
    popd

    startup_scripts_path="$(find reference -type f | grep -iP 'load\.php.*?modules=startup&only=scripts.*?' | head -1 || true)"
    site_scripts_path="$(find reference -type f | grep -iP 'load\.php.*?modules=site&only=scripts.*?' | head -1 || true)"
    site_modules_path="$(find reference -type f | grep -iP 'load\.php.*?(modules=site[.&]|modules=site&).*only=styles.*?' | head -1 || true)"
    skin_scripts_path="$(find reference -type f | grep -iP 'load\.php.*?modules=skins.*&only=scripts.*?' | head -1 || true)"
    ext_path="$(find reference -type f | grep -iP 'load\.php.*?modules=.*ext.*&only=styles.*?' | head -1 || true)"

    if [[ ! -f "${legacy_archive}" ]]; then
      wget -O "${legacy_archive}" https://github.com/myfreeer/cppreference2mshelp/releases/download/2025.04/cppreference-unprocessed-20250404.7z
    fi
    restore_legacy_assets "${legacy_archive}"

    # package un-processed files
    "${_7Z}" a -mx9 -myx9  -mqs "../cppreference-unprocessed-${VERSION}.7z" ./reference
    tar caf "../cppreference-unprocessed-${VERSION}.tar.xz" reference
    #rm -rf ./reference
    #"${_7Z}" x ../cppreference-unprocessed-20210212.7z
fi

# https://gist.github.com/cdown/1163649/8a35c36fdd24b373788a7057ed483a5bcd8cd43e
url_encode() {
    local _length="${#1}"
    for (( _offset = 0 ; _offset < _length ; _offset++ )); do
        _print_offset="${1:_offset:1}"
        case "${_print_offset}" in
            [a-zA-Z0-9.~_-]) printf "${_print_offset}" ;;
            ' ') printf + ;;
            *) printf '%%%X' "'${_print_offset}" ;;
        esac
    done
}

copy_file(){
    local var=$1
    local path="$(eval echo "\${${var}_path}")"
    local replace="$(eval echo "\${${var}_replace}")"
    if [[ -z "${path}" || ! -f "${path}" ]]; then
        return 0
    fi
    local dir="$(dirname "${path}")"
    cp -f -T "${path}" "${dir}/${replace}"
}

remove_file(){
    local var=$1
    local path="$(eval echo "\${${var}_path}")"
    if [[ -z "${path}" ]]; then
        return 0
    fi
    local name="$(basename "${path}")"
    find -iname "${name}" | xargs -r rm -f
}

replace_in_html(){
    local var=$1
    local path="$(eval echo "\${${var}_path}")"
    local replace="$(eval echo "\${${var}_replace}")"
    if [[ -z "${path}" ]]; then
        return 0
    fi
    local name="$(basename "${path}")"
    local encoded_name="$(url_encode "${name}")"
    find ./ -iname '*.html' -type f | xargs -r -P "${CPUS}" sed -i "s/${name}/${replace}/gi"
    find ./ -iname '*.html' -type f | xargs -r -P "${CPUS}" sed -i "s/${encoded_name}/${replace}/gi"
}

if [[ "${resume_from_output}" != "1" ]]; then
  if [[ "${resume_from_processed}" != "1" ]]; then
    echo pre-processing...
    for i in $LIST; do copy_file $i; done
    if [[ -n "${site_modules_path}" && -f ../css/site_modules.css ]]; then
        cp -f -T ../css/site_modules.css "$(dirname "${site_modules_path}")/${site_modules_replace}"
    fi
    if [[ -n "${ext_path}" && -f ../css/ext.css ]]; then
        cp -f -T ../css/ext.css "$(dirname "${ext_path}")/${ext_replace}"
    fi

    # backup extra fonts
    mkdir -p font_temp
    for i in $extra_fonts; do
        find -iname $i -exec cp {} font_temp/$i \; -quit
    done
    for i in $extra_fonts; do
        if [[ ! -f font_temp/$i && -f "reference/zh.cppreference.com/$i" ]]; then
            cp -f "reference/zh.cppreference.com/$i" "font_temp/$i"
        fi
    done

    # original preprocess
    make doc_html

    # restore extra fonts
    if [[ -d 'reference/common' ]]; then
        font_path='reference/common'
    elif [[ -d 'output/common' ]]; then
        font_path='output/common'
    fi
    if [[ -n "${font_path}" && -d "${font_path}" ]]; then
    for i in $extra_fonts; do
        if [[ -f font_temp/$i ]]; then
            cp -f font_temp/$i $font_path/$i
        fi
    done
    fi
    rm -rf font_temp
  elif [[ -d 'reference/common' ]]; then
    font_path='reference/common'
  fi

  find ./ -iname '*.html' -type f | xargs -r -P "${CPUS}" sed -i "s/ - cppreference.com//g"

  echo post-processing...
  for i in $LIST; do
    echo processing $i
    remove_file $i
    replace_in_html $i
  done

  find -iname "${startup_scripts_replace}" | xargs -r sed -i 's/document\.write/void /ig'
  prepend_once "${site_scripts_replace}" 'if(window.mw)'
  prepend_once "${skin_scripts_replace}" 'if(window.mw)'
  find -iname '*.css' | xargs -r sed -i -r 's/\.\.\/([^.]+?)\.ttf/\1.ttf/ig'

  # workaround navbar-inv-tab.png
  find -iname '*.css' | xargs -r sed -i -r 's/https?:\/\/..\.cppreference\.com\/mwiki\/skins\/cppreference2\/images/skins\/cppreference2\/images/ig'
  if [[ -n "${font_path}" && -d "${font_path}/skins/cppreference2/images" ]]; then
    cp -n skins/cppreference2/images/navbar-inv-tab.png "${font_path}/skins/cppreference2/images/navbar-inv-tab.png" 2>/dev/null || true
  fi
  echo Cleaning up carbonads scripts
  find ./ -iname '*.html' -type f | xargs -r -P "${CPUS}" sed -i -r 's/<script.+?carbonads\.com\/carbon\.js.+?<\/script>//ig'
  echo Cleaning up googletagmanager scripts
  find ./ -iname '*.html' -type f | xargs -r -P "${CPUS}" sed -i -r 's/<script.+?googletagmanager\.com.+?<\/script>//ig'
  echo Cleaning up cloudflare insights scripts
  find ./ -iname '*.html' -type f | xargs -r -P "${CPUS}" sed -i -r 's/<script[^>]+static\.cloudflareinsights\.com[^>]*><\/script>//ig'

  rm -rf 'reference/zh.cppreference.com'

  # build doc_devhelp doc_doxygen
  mkdir -p output
  rm -rf output/reference
  mv -f reference output/
fi
make doc_doxygen doc_devhelp

# package processed files
cd output
"${_7Z}" a -mx9 -myx9 -mqs "../../html-book-${VERSION}.7z" ./reference cppreference-doc-zh-c.devhelp2 cppreference-doc-zh-cpp.devhelp2 cppreference-doxygen-web.tag.xml cppreference-doxygen-local.tag.xml devhelp-index-c.xml devhelp-index-cpp.xml link-map.xml
tar caf "../../html-book-${VERSION}.tar.xz" reference cppreference-doc-zh-c.devhelp2 cppreference-doc-zh-cpp.devhelp2 cppreference-doxygen-web.tag.xml cppreference-doxygen-local.tag.xml devhelp-index-c.xml devhelp-index-cpp.xml link-map.xml
cd ..

# build qch book
make doc_qch
"${_7Z}" a -mx9 -myx9 -mqs "../qch-book-${VERSION}.7z" ./output/*.qch
tar caf "../qch-book-${VERSION}.tar.xz"  ./output/*.qch

# move processed files to parent folder
# for make_chm.sh
mv -f output/reference/* ../
cd ..

set +e
