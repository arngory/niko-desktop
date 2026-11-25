//go:build linux

package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"syscall"
)

func peerPID(conn net.Conn) (int, string, error) {
	sc, ok := conn.(syscall.Conn)
	if !ok {
		return 0, "", errors.New("connection does not expose syscall.Conn")
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return 0, "", fmt.Errorf("SyscallConn: %w", err)
	}
	var (
		ucred  *syscall.Ucred
		optErr error
	)
	ctrlErr := raw.Control(func(fd uintptr) {
		ucred, optErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	})
	if ctrlErr != nil {
		return 0, "SO_PEERCRED", ctrlErr
	}
	if optErr != nil {
		return 0, "SO_PEERCRED", optErr
	}
	detail := fmt.Sprintf("SO_PEERCRED pid=%d uid=%d gid=%d", ucred.Pid, ucred.Uid, ucred.Gid)
	if ucred.Uid != uint32(os.Getuid()) {
		return 0, detail, fmt.Errorf("peer uid %d != current uid %d", ucred.Uid, os.Getuid())
	}
	if ucred.Pid <= 0 {
		return 0, detail, fmt.Errorf("invalid peer pid %d", ucred.Pid)
	}
	return int(ucred.Pid), detail, nil
}

func verifySocketOwner(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return errors.New("missing syscall.Stat_t")
	}
	if st.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("socket owner uid %d != current uid %d", st.Uid, os.Getuid())
	}
	return nil
}

func secureUserOnlyDir(dir string) error {
	// Open without following symlinks so ownership check and chmod operate on the same inode (no TOCTOU).
	fd, err := syscall.Open(dir, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("open directory %q: %w", dir, err)
	}
	defer syscall.Close(fd)

	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return fmt.Errorf("fstat %q: %w", dir, err)
	}
	if st.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("directory owner uid %d != current uid %d", st.Uid, os.Getuid())
	}
	return syscall.Fchmod(fd, 0o700)
}

func isUnixSocketFile(path string) (isSocket bool, exists bool, err error) {
	info, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, false, nil
		}
		return false, false, err
	}
	return info.Mode()&os.ModeSocket != 0, true, nil
}

func shortenSocketPath(path string) (string, error) {
	return "", errors.New("8.3 short paths are Windows-only")
}

func isNormalCloseError(err error) bool {
	return errors.Is(err, net.ErrClosed) ||
		errors.Is(err, io.EOF) ||
		errors.Is(err, syscall.ECONNRESET) ||
		errors.Is(err, syscall.EPIPE)
}
