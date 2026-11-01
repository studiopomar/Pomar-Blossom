#!/usr/bin/env bash
set -euo pipefail

# Determine repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-2.1.1}"
CONFIG="${2:-Release}"
ARCH="linux-x64"
DIST_DIR="$REPO_ROOT/dist"
PUBLISH_DIR="$REPO_ROOT/TuneLab/bin/$CONFIG/net8.0/$ARCH/publish"
CLI_PUBLISH_DIR="$REPO_ROOT/TuneLab.Cli/bin/$CONFIG/net8.0/$ARCH/publish"

echo "=== Building TuneLab for $ARCH ($CONFIG) ==="
dotnet publish TuneLab/TuneLab.csproj -c "$CONFIG" -r "$ARCH" --self-contained
dotnet publish TuneLab.Cli/TuneLab.Cli.csproj -c "$CONFIG" -r "$ARCH" --self-contained

# Copy CLI binary into TuneLab publish dir
cp "$CLI_PUBLISH_DIR/tunelab" "$PUBLISH_DIR/" 2>/dev/null || true

mkdir -p "$DIST_DIR"

ICON_SRC="$REPO_ROOT/tools/icons/mark.png"

# 1. Package .tar.gz (Portable Linux)
echo "=== Creating Portable tar.gz ==="
TAR_STAGE=$(mktemp -d)
TAR_APP_DIR="$TAR_STAGE/TuneLab"
mkdir -p "$TAR_APP_DIR"
cp -R "$PUBLISH_DIR/"* "$TAR_APP_DIR/"
cp "$ICON_SRC" "$TAR_APP_DIR/tunelab.png" 2>/dev/null || true

cat << 'EOF' > "$TAR_APP_DIR/tunelab.desktop"
[Desktop Entry]
Name=TuneLab
Comment=An extensible singing voice synthesis editor
Exec=./TuneLab %F
Icon=tunelab
Terminal=false
Type=Application
Categories=AudioVideo;Audio;AudioVideoEditing;
MimeType=application/x-tunelab-project;
EOF

chmod +x "$TAR_APP_DIR/TuneLab" "$TAR_APP_DIR/tunelab"
tar -czf "$DIST_DIR/TuneLab-linux-x64-v${VERSION}.tar.gz" -C "$TAR_STAGE" TuneLab
rm -rf "$TAR_STAGE"

# 2. Package .deb (Debian / Ubuntu / Mint)
echo "=== Creating Debian package (.deb) ==="
DEB_STAGE=$(mktemp -d)
DEB_DIR="$DEB_STAGE/tunelab_${VERSION}_amd64"
mkdir -p "$DEB_DIR/DEBIAN"
mkdir -p "$DEB_DIR/usr/lib/tunelab"
mkdir -p "$DEB_DIR/usr/bin"
mkdir -p "$DEB_DIR/usr/share/applications"
mkdir -p "$DEB_DIR/usr/share/pixmaps"

# Copy binaries
cp -R "$PUBLISH_DIR/"* "$DEB_DIR/usr/lib/tunelab/"
cp "$ICON_SRC" "$DEB_DIR/usr/share/pixmaps/tunelab.png" 2>/dev/null || true

# Symlinks in /usr/bin
cat << 'EOF' > "$DEB_DIR/usr/bin/tunelab"
#!/usr/bin/env sh
exec /usr/lib/tunelab/TuneLab "$@"
EOF
chmod +x "$DEB_DIR/usr/bin/tunelab"

cat << 'EOF' > "$DEB_DIR/usr/bin/tunelab-cli"
#!/usr/bin/env sh
exec /usr/lib/tunelab/tunelab "$@"
EOF
chmod +x "$DEB_DIR/usr/bin/tunelab-cli"

cat << 'EOF' > "$DEB_DIR/usr/share/applications/tunelab.desktop"
[Desktop Entry]
Name=TuneLab
Comment=An extensible singing voice synthesis editor
Exec=/usr/bin/tunelab %F
Icon=tunelab
Terminal=false
Type=Application
Categories=AudioVideo;Audio;AudioVideoEditing;
MimeType=application/x-tunelab-project;
EOF

# DEBIAN/control
cat << EOF > "$DEB_DIR/DEBIAN/control"
Package: tunelab
Version: ${VERSION}
Section: sound
Priority: optional
Architecture: amd64
Depends: libasound2, libfontconfig1, libx11-6, libice6, libsm6
Maintainer: TuneLab Team <https://tunelab.app>
Description: An extensible singing voice synthesis editor
 TuneLab is a modern, extensible singing voice synthesis editor
 supporting vocal synthesis plugins and audio production.
EOF

chmod -R 755 "$DEB_DIR/usr"
chmod 755 "$DEB_DIR/DEBIAN"

if command -v dpkg-deb &>/dev/null; then
    dpkg-deb --build "$DEB_DIR" "$DIST_DIR/tunelab_${VERSION}_amd64.deb"
    echo "Generated $DIST_DIR/tunelab_${VERSION}_amd64.deb"
else
    echo "dpkg-deb not found, skipping .deb creation"
fi
rm -rf "$DEB_STAGE"

# 3. Package .rpm (Fedora / RHEL / openSUSE) if rpmbuild is available
if command -v rpmbuild &>/dev/null; then
    echo "=== Creating RPM package (.rpm) ==="
    RPM_ROOT=$(mktemp -d)
    mkdir -p "$RPM_ROOT"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    RPM_VER="${VERSION//-/_}"

    cat << EOF > "$RPM_ROOT/SPECS/tunelab.spec"
%define _build_id_links none
%global __os_install_post %{nil}
%define debug_package %{nil}
Name:           tunelab
Version:        ${RPM_VER}
Release:        1%{?dist}
Summary:        An extensible singing voice synthesis editor
License:        MIT
URL:            https://tunelab.app

%description
TuneLab is a modern, extensible singing voice synthesis editor.

%install
mkdir -p %{buildroot}/usr/lib/tunelab
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/pixmaps

cp -R $PUBLISH_DIR/* %{buildroot}/usr/lib/tunelab/
cp $ICON_SRC %{buildroot}/usr/share/pixmaps/tunelab.png

cat << 'EOS' > %{buildroot}/usr/bin/tunelab
#!/usr/bin/env sh
exec /usr/lib/tunelab/TuneLab "\$@"
EOS
chmod 755 %{buildroot}/usr/bin/tunelab

cat << 'EOS' > %{buildroot}/usr/share/applications/tunelab.desktop
[Desktop Entry]
Name=TuneLab
Comment=An extensible singing voice synthesis editor
Exec=/usr/bin/tunelab %F
Icon=tunelab
Terminal=false
Type=Application
Categories=AudioVideo;Audio;AudioVideoEditing;
EOS

%files
/usr/lib/tunelab
/usr/bin/tunelab
/usr/share/applications/tunelab.desktop
/usr/share/pixmaps/tunelab.png

EOF

    rpmbuild --define "_topdir $RPM_ROOT" -bb "$RPM_ROOT/SPECS/tunelab.spec" 2>/dev/null || true
    find "$RPM_ROOT/RPMS" -name "*.rpm" -exec cp {} "$DIST_DIR/" \; || true
    rm -rf "$RPM_ROOT"
fi

echo "=== Linux packaging complete! Dist files: ==="
ls -lh "$DIST_DIR" || true
