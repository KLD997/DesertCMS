#!/bin/ksh
#
# Legacy compatibility wrapper.
#
# DesertCMS now has one supported OpenBSD installer:
#
#   doas perl install/openbsd-install.pl
#
# This file remains only so older notes or shell history that call the
# Vultr-specific installer land on the maintained single-install path.

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
installer="$script_dir/openbsd-install.pl"

if [ ! -f "$installer" ]; then
	print -- "ERROR: cannot find $installer" >&2
	exit 1
fi

print -- "install/openbsd-vultr-install.ksh is deprecated."
print -- "Delegating to the supported OpenBSD installer: perl $installer $*"
exec perl "$installer" "$@"
