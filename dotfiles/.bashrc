#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'

alias gst='git status'
alias ga='git add'
alias gc='git commit'
alias gd='git diff'
alias gds='git diff --staged'
alias gco='git checkout'

PS1='[\u@\h \W]\$ '

export PATH="$PATH:$HOME/.local/bin"
[[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"
