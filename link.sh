#!/bin/sh
#
# Symlink everything under dotfiles/ into $HOME, mirroring the directory
# layout.  Existing regular files are moved aside as <file>.orig; existing
# symlinks are replaced.  Safe to rerun.

set -eu

repo=$(cd "$(dirname "$0")" && pwd)
src="$repo/dotfiles"

cd "$src"
find . -type f | sed 's|^\./||' | while read -r rel; do
	target="$HOME/$rel"
	mkdir -p "$(dirname "$target")"
	if [ -e "$target" ] && [ ! -L "$target" ]; then
		mv "$target" "$target.orig"
		echo "kept old $rel as $rel.orig"
	fi
	ln -sfn "$src/$rel" "$target"
done

mkdir -p "$HOME/store/pdfs" "$HOME/store/scrots"

# vim-plug for the neovim config
plug="$HOME/.local/share/nvim/site/autoload/plug.vim"
if [ ! -f "$plug" ]; then
	mkdir -p "$(dirname "$plug")"
	curl -fsSL -o "$plug" \
		https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim \
		&& echo "installed vim-plug (run :PlugInstall in nvim)"
fi

echo "dotfiles linked from $src"
