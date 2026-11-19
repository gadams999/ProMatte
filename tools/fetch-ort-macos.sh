#!/bin/bash
#
# Fetch a universal ONNX Runtime for macOS from NuGet and lay it out the way
# ProMatteDependencies.cmake expects: <dest>/include and <dest>/lib.
#
#   usage: fetch-ort-macos.sh <version> <sha512-base64 of the .nupkg> <dest>
#
# Why NuGet: Microsoft's GitHub repository, and with it the release tarballs this
# used to download, became unavailable in November 2026. The Microsoft.ML.OnnxRuntime
# package is published by Microsoft on nuget.org, is author-signed, and carries
# the C/C++ headers plus separate osx-arm64 and osx-x64 libraries. They are joined
# here with lipo, so the result is the same single universal library the bundle
# step already expects.
#
# The hash is a pin: a package that does not match it is rejected before anything
# is unpacked, and when the dotnet SDK is available its signature is verified too.
# Take the pin from a download you have verified with `dotnet nuget verify`:
#   openssl dgst -sha512 -binary <file>.nupkg | base64
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <version> <sha512-base64> <dest>" >&2
    exit 2
fi
version=$1
want=$2
dest=$3

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pkg="$work/ort.nupkg"
url="https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${version}/microsoft.ml.onnxruntime.${version}.nupkg"
curl -fsSL -o "$pkg" "$url"

got=$(openssl dgst -sha512 -binary "$pkg" | base64 | tr -d '\n')
if [ "$got" != "$want" ]; then
    echo "Microsoft.ML.OnnxRuntime ${version}: SHA-512 mismatch" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1
fi

# Verify the author signature as well as the pin when the SDK is around, so a
# pin that was updated carelessly still has to match a package Microsoft signed.
# Read the signer rather than trusting the exit code alone.
if command -v dotnet >/dev/null 2>&1; then
    dotnet nuget verify --all "$pkg" | tee "$work/verify.txt"
    if ! grep -q 'Subject Name: CN=Microsoft Corporation' "$work/verify.txt"; then
        echo "package is not signed by Microsoft Corporation" >&2
        exit 1
    fi
else
    echo "dotnet not found: checked the SHA-512 pin only, not the package signature" >&2
fi

rm -rf "$dest"
mkdir -p "$dest/include" "$dest/lib" "$work/slices"
unzip -q -j "$pkg" 'build/native/include/*' -d "$dest/include"
unzip -q -p "$pkg" runtimes/osx-arm64/native/libonnxruntime.dylib > "$work/slices/arm64.dylib"
unzip -q -p "$pkg" runtimes/osx-x64/native/libonnxruntime.dylib > "$work/slices/x64.dylib"

# finalise-bundle.sh reads the install name from the dylib it is given, so the
# file is stored under the name dyld will ask for, as the old tarball did.
name=$(otool -D "$work/slices/arm64.dylib" | tail -1)
name=${name##*/}
other=$(otool -D "$work/slices/x64.dylib" | tail -1)
if [ "${other##*/}" != "$name" ]; then
    echo "the arm64 and x64 libraries disagree on their install name: $name vs ${other##*/}" >&2
    exit 1
fi
lipo -create "$work/slices/arm64.dylib" "$work/slices/x64.dylib" -output "$dest/lib/$name"
ln -s "$name" "$dest/lib/libonnxruntime.dylib"

archs=$(lipo -archs "$dest/lib/$name")
case "$archs" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *) echo "result is not universal: $archs" >&2; exit 1 ;;
esac
minos=$(otool -l "$dest/lib/$name" | awk '/minos/ { print $2; exit }')
echo "ONNX Runtime ${version}: ${name} (${archs}), minimum macOS ${minos}, in ${dest}"
