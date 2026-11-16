package sshkeys

import "syscall"

func umaskSet(m int) int { return syscall.Umask(m) }
