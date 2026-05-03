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
    *)
      # unknown option
    ;;
  esac
done

set -e

if [[ "${UPSTREAM}" = "p12tic" ]]; then
  git clone https://github.com/p12tic/cppreference-doc.git --filter=tree:0
  cd cppreference-doc
  git apply -3 ../zh-p12tic.diff
else
  git clone https://github.com/PeterFeicht/cppreference-doc.git --filter=tree:0
  cd cppreference-doc
  git apply -3 ../zh.diff
fi

git apply -3 ../preprocess_cssless.diff
git apply -3 ../upstream-layout.diff

VERSION="${VERSION:-$(date +%Y%m%d)}"
sed -i "/^VERSION=/cVERSION=${VERSION}" Makefile
make source

pushd reference
python3 ../../fix_mirror.py
if [[ -s urls_to_download.txt ]]; then
  wget --force-directories --retry-connrefused --waitretry=2 --read-timeout=13 --trust-server-names -i urls_to_download.txt
  rm -f urls_to_download.txt
fi
popd

# init files and vars
startup_scripts_replace="startup_scripts.js"
startup_scripts_path="$(find reference -type f | grep -iP 'load\.php.*?modules=startup&only=scripts.*?' | head -1 || true)"

site_scripts_replace="site_scripts.js"
site_scripts_path="$(find reference -type f | grep -iP 'load\.php.*?modules=site&only=scripts.*?' | head -1 || true)"

site_modules_replace="site_modules.css"
site_modules_path="$(find reference -type f | grep -iP 'load\.php.*?(modules=site[.&]|modules=site&).*only=styles.*?' | head -1 || true)"

skin_scripts_replace="skin_scripts.js"
skin_scripts_path="$(find reference -type f | grep -iP 'load\.php.*?modules=skins.*&only=scripts.*?' | head -1 || true)"

ext_replace="ext.css"
ext_path="$(find reference -type f | grep -iP 'load\.php.*?modules=.*ext.*&only=styles.*?' | head -1 || true)"

LIST="startup_scripts site_scripts site_modules skin_scripts ext"
extra_fonts="DejaVuSans.ttf DejaVuSans-Bold.ttf DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf DejaVuSansMonoCondensed60.ttf DejaVuSansMonoCondensed75.ttf"
legacy_archive="../cppreference-unprocessed-20250404.7z"

_7Z="${_7Z:-$(which 7z)}"
CPUS="$(cat /proc/cpuinfo | grep -c '^processor')"

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

restore_legacy_assets "${legacy_archive}"

# package un-processed files
"${_7Z}" a -mx9 -myx9  -mqs "../cppreference-unprocessed-${VERSION}.7z" ./reference
tar caf "../cppreference-unprocessed-${VERSION}.tar.xz" reference
#rm -rf ./reference
#"${_7Z}" x ../cppreference-unprocessed-20210212.7z

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
    find -iname "${name}" | xargs rm -f
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
    find ./ -iname '*.html' -type f | xargs -P "${CPUS}" sed -i "s/${name}/${replace}/gi"
    find ./ -iname '*.html' -type f | xargs -P "${CPUS}" sed -i "s/${encoded_name}/${replace}/gi"
}

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
if [[ -d $font_path ]]; then
for i in $extra_fonts; do
    if [[ -f font_temp/$i ]]; then
        cp -f font_temp/$i $font_path/$i
    fi
done
fi
rm -rf font_temp

find ./ -iname '*.html' -type f | xargs -P "${CPUS}" sed -i "s/ - cppreference.com//g"

echo post-processing...
for i in $LIST; do
    echo processing $i
    remove_file $i
    replace_in_html $i
done

find -iname "${startup_scripts_replace}" | xargs sed -i 's/document\.write/void /ig'
find -iname "${site_scripts_replace}" | xargs sed -i '1 i if(window.mw)'
find -iname "${skin_scripts_replace}" | xargs sed -i '1 i if(window.mw)'
find -iname '*.css' | xargs sed -i -r 's/\.\.\/([^.]+?)\.ttf/\1.ttf/ig'

# workaround navbar-inv-tab.png
find -iname '*.css' | xargs sed -i -r 's/https?:\/\/..\.cppreference\.com\/mwiki\/skins\/cppreference2\/images/skins\/cppreference2\/images/ig'
if [[ -d "${font_path}/skins/cppreference2/images" ]]; then
    cp -n skins/cppreference2/images/navbar-inv-tab.png "${font_path}/skins/cppreference2/images/navbar-inv-tab.png" 2>/dev/null || true
fi
echo Cleaning up carbonads scripts
find ./ -iname '*.html' -type f | xargs -P "${CPUS}" sed -i -r 's/<script.+?carbonads\.com\/carbon\.js.+?<\/script>//ig' 
echo Cleaning up googletagmanager scripts
find ./ -iname '*.html' -type f | xargs -P "${CPUS}" sed -i -r 's/<script.+?googletagmanager\.com.+?<\/script>//ig'
echo Cleaning up cloudflare insights scripts
find ./ -iname '*.html' -type f | xargs -P "${CPUS}" sed -i -r 's/<script[^>]+static\.cloudflareinsights\.com[^>]*><\/script>//ig'

rm -rf 'reference/zh.cppreference.com'

# build doc_devhelp doc_doxygen
mkdir -p output
mv -f reference output/
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
