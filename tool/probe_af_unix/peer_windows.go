//go:build windows

package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"syscall"
	"unsafe"
)

const (
	// _WSAIOR(IOC_VENDOR, 256) from <afunix.h>
	sioAFUnixGetPeerPID = 0x58000100

	// Win32 file/security constants
	readControl                  = 0x00020000
	writeDAC                     = 0x00040000
	fileFlagBackupSemantics      = 0x02000000
	fileFlagOpenReparsePoint     = 0x00200000
	fileAttributeDirectory       = 0x00000010
	fileAttributeReparsePoint    = 0x00000400
	ioReparseTagAFUnix           = 0x80000023
	seFileObject                 = 1
	ownerSecurityInformation     = 0x00000001
	daclSecurityInformation      = 0x00000004
	protectedDACLSecurityInfo    = 0x80000000
	sddlRevision1                = 1
	tokenOwnerClass              = 4
	maxWindowsShortPathUTF16Size = 32768

	// Winsock and Win32 IOCP peer-reset errors expected on normal shutdown.
	wsaeConnAborted        = syscall.Errno(10053)
	wsaeConnReset          = syscall.Errno(10054)
	errorNetnameDeleted    = syscall.Errno(64)
	errorBrokenPipe        = syscall.Errno(109)
	errorConnectionAborted = syscall.Errno(1236)
)

var (
	advapi32                                 = syscall.NewLazyDLL("advapi32.dll")
	kernel32                                 = syscall.NewLazyDLL("kernel32.dll")
	procGetSecurityInfo                      = advapi32.NewProc("GetSecurityInfo")
	procSetSecurityInfo                      = advapi32.NewProc("SetSecurityInfo")
	procEqualSid                             = advapi32.NewProc("EqualSid")
	procConvertStringSecurityDescriptorToSDW = advapi32.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	procGetSecurityDescriptorDacl            = advapi32.NewProc("GetSecurityDescriptorDacl")
	procGetShortPathNameW                    = kernel32.NewProc("GetShortPathNameW")
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
		pid           uint32
		bytesReturned uint32
		ioctlErr      error
	)
	ctrlErr := raw.Control(func(fd uintptr) {
		// Known Windows AF_UNIX quirk (microsoft/WSL issue 4676):
		// SIO_AF_UNIX_GETPEERPID writes the ULONG PID into the output buffer
		// while setting bytesReturned = 0. Trust pid when WSAIoctl succeeds
		// and pid != 0, regardless of bytesReturned.
		ioctlErr = syscall.WSAIoctl(
			syscall.Handle(fd),
			sioAFUnixGetPeerPID,
			nil,
			0,
			(*byte)(unsafe.Pointer(&pid)),
			uint32(unsafe.Sizeof(pid)),
			&bytesReturned,
			nil,
			0,
		)
	})
	detail := fmt.Sprintf("SIO_AF_UNIX_GETPEERPID pid=%d bytesReturned=%d", pid, bytesReturned)
	if ctrlErr != nil {
		return 0, detail, ctrlErr
	}
	if ioctlErr != nil {
		return 0, detail, ioctlErr
	}
	if pid == 0 {
		return 0, detail, errors.New("SIO_AF_UNIX_GETPEERPID returned pid 0")
	}
	return int(pid), detail, nil
}

// currentTokenSIDs returns the current process's TokenUser SID and default TokenOwner SID
// (both as standalone copied SIDs owned by Go, safe across GC).
// Under an elevated admin token (such as GitHub Actions windows-latest), newly created files
// are owned by TokenOwner (often BUILTIN\Administrators) rather than TokenUser.
func currentTokenSIDs() (userSID *syscall.SID, ownerSID *syscall.SID, err error) {
	token, err := syscall.OpenCurrentProcessToken()
	if err != nil {
		return nil, nil, fmt.Errorf("OpenCurrentProcessToken: %w", err)
	}
	defer token.Close()
	tu, err := token.GetTokenUser()
	if err != nil {
		return nil, nil, fmt.Errorf("GetTokenUser: %w", err)
	}
	userCopy, err := tu.User.Sid.Copy()
	if err != nil {
		return nil, nil, fmt.Errorf("copy user SID: %w", err)
	}

	var needed uint32
	gerr := syscall.GetTokenInformation(token, tokenOwnerClass, nil, 0, &needed)
	if gerr != nil && !errors.Is(gerr, syscall.ERROR_INSUFFICIENT_BUFFER) {
		return nil, nil, fmt.Errorf("GetTokenInformation(TokenOwner size): %w", gerr)
	}
	if needed == 0 {
		return userCopy, nil, nil
	}
	buf := make([]byte, needed)
	if gerr := syscall.GetTokenInformation(token, tokenOwnerClass, &buf[0], needed, &needed); gerr != nil {
		return nil, nil, fmt.Errorf("GetTokenInformation(TokenOwner): %w", gerr)
	}
	// TOKEN_OWNER starts with a single *syscall.SID pointer into buf.
	rawOwner := *(**syscall.SID)(unsafe.Pointer(&buf[0]))
	if rawOwner != nil {
		ownerCopy, cerr := rawOwner.Copy()
		if cerr != nil {
			return nil, nil, fmt.Errorf("copy owner SID: %w", cerr)
		}
		ownerSID = ownerCopy
	}
	return userCopy, ownerSID, nil
}

func openNoFollow(path string, desiredAccess uint32) (syscall.Handle, error) {
	pathPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return syscall.InvalidHandle, err
	}
	h, err := syscall.CreateFile(
		pathPtr,
		desiredAccess,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		nil,
		syscall.OPEN_EXISTING,
		fileFlagOpenReparsePoint|fileFlagBackupSemantics,
		0,
	)
	if err != nil {
		return syscall.InvalidHandle, err
	}
	return h, nil
}

func verifyHandleOwner(h syscall.Handle, label string) error {
	userSID, tokenOwnerSID, err := currentTokenSIDs()
	if err != nil {
		return err
	}
	var (
		ownerSID *syscall.SID
		secDesc  uintptr
	)
	r1, _, _ := procGetSecurityInfo.Call(
		uintptr(h),
		seFileObject,
		ownerSecurityInformation,
		uintptr(unsafe.Pointer(&ownerSID)),
		0,
		0,
		0,
		uintptr(unsafe.Pointer(&secDesc)),
	)
	if r1 != 0 {
		return fmt.Errorf("GetSecurityInfo(%s): error %d", label, r1)
	}
	if secDesc != 0 {
		defer syscall.LocalFree(syscall.Handle(secDesc))
	}
	if ownerSID == nil {
		return fmt.Errorf("%s has no owner SID", label)
	}
	if eq, _, _ := procEqualSid.Call(uintptr(unsafe.Pointer(ownerSID)), uintptr(unsafe.Pointer(userSID))); eq != 0 {
		return nil
	}
	if tokenOwnerSID != nil {
		if eq, _, _ := procEqualSid.Call(uintptr(unsafe.Pointer(ownerSID)), uintptr(unsafe.Pointer(tokenOwnerSID))); eq != 0 {
			return nil
		}
	}
	gotStr, _ := ownerSID.String()
	userStr, _ := userSID.String()
	tokenOwnerStr := "<nil>"
	if tokenOwnerSID != nil {
		tokenOwnerStr, _ = tokenOwnerSID.String()
	}
	return fmt.Errorf("%s owner SID %s does not match user %s or token owner %s", label, gotStr, userStr, tokenOwnerStr)
}

func verifySocketOwner(path string) error {
	// Open with FILE_FLAG_OPEN_REPARSE_POINT so Windows does not fail with ERROR_CANT_ACCESS_FILE (1920)
	// when opening an IO_REPARSE_TAG_AF_UNIX socket object.
	h, err := openNoFollow(path, readControl)
	if err != nil {
		return fmt.Errorf("open socket %q for owner check: %w", path, err)
	}
	defer syscall.CloseHandle(h)
	return verifyHandleOwner(h, path)
}

func secureUserOnlyDir(dir string) error {
	// Open by handle without following symlinks/junctions so owner check and DACL update have no TOCTOU.
	h, err := openNoFollow(dir, readControl|writeDAC)
	if err != nil {
		return fmt.Errorf("open directory %q: %w", dir, err)
	}
	defer syscall.CloseHandle(h)

	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(h, &info); err != nil {
		return fmt.Errorf("GetFileInformationByHandle(%q): %w", dir, err)
	}
	if info.FileAttributes&fileAttributeReparsePoint != 0 {
		return fmt.Errorf("socket directory %q is a symlink or reparse point", dir)
	}
	if info.FileAttributes&fileAttributeDirectory == 0 {
		return fmt.Errorf("socket directory %q is not a directory", dir)
	}

	if err := verifyHandleOwner(h, dir); err != nil {
		return err
	}

	userSID, tokenOwnerSID, err := currentTokenSIDs()
	if err != nil {
		return err
	}
	userStr, err := userSID.String()
	if err != nil {
		return fmt.Errorf("user SID.String: %w", err)
	}
	// Protected DACL granting full access solely to the current user (and TokenOwner if distinct, e.g. elevated CI).
	sddl := fmt.Sprintf("D:P(A;OICI;FA;;;%s)", userStr)
	if tokenOwnerSID != nil {
		if eq, _, _ := procEqualSid.Call(uintptr(unsafe.Pointer(userSID)), uintptr(unsafe.Pointer(tokenOwnerSID))); eq == 0 {
			if ownerStr, serr := tokenOwnerSID.String(); serr == nil {
				sddl = fmt.Sprintf("D:P(A;OICI;FA;;;%s)(A;OICI;FA;;;%s)", userStr, ownerStr)
			}
		}
	}
	sddlPtr, err := syscall.UTF16PtrFromString(sddl)
	if err != nil {
		return err
	}
	var secDesc uintptr
	r1, _, callErr := procConvertStringSecurityDescriptorToSDW.Call(
		uintptr(unsafe.Pointer(sddlPtr)),
		sddlRevision1,
		uintptr(unsafe.Pointer(&secDesc)),
		0,
	)
	if r1 == 0 {
		return fmt.Errorf("ConvertStringSecurityDescriptorToSecurityDescriptorW: %w", callErr)
	}
	defer syscall.LocalFree(syscall.Handle(secDesc))

	var (
		daclPresent   int32
		dacl          uintptr
		daclDefaulted int32
	)
	r1, _, callErr = procGetSecurityDescriptorDacl.Call(
		secDesc,
		uintptr(unsafe.Pointer(&daclPresent)),
		uintptr(unsafe.Pointer(&dacl)),
		uintptr(unsafe.Pointer(&daclDefaulted)),
	)
	if r1 == 0 || daclPresent == 0 || dacl == 0 {
		return fmt.Errorf("GetSecurityDescriptorDacl: %w", callErr)
	}

	r1, _, _ = procSetSecurityInfo.Call(
		uintptr(h),
		seFileObject,
		daclSecurityInformation|protectedDACLSecurityInfo,
		0,
		0,
		dacl,
		0,
	)
	if r1 != 0 {
		return fmt.Errorf("SetSecurityInfo(%q): error %d", dir, r1)
	}
	return nil
}

func isUnixSocketFile(path string) (isSocket bool, exists bool, err error) {
	pathPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return false, false, err
	}
	var data syscall.Win32finddata
	h, err := syscall.FindFirstFile(pathPtr, &data)
	if err != nil {
		if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) || errors.Is(err, syscall.ERROR_PATH_NOT_FOUND) {
			return false, false, nil
		}
		return false, false, err
	}
	_ = syscall.FindClose(h)
	// For reparse points, Win32finddata.Reserved0 holds the reparse tag.
	isAFUnix := data.FileAttributes&fileAttributeReparsePoint != 0 && data.Reserved0 == ioReparseTagAFUnix
	return isAFUnix, true, nil
}

func shortenSocketPath(path string) (string, error) {
	// GetShortPathNameW requires an existing path; shorten the parent directory and keep the base name.
	dir := filepath.Dir(path)
	dirPtr, err := syscall.UTF16PtrFromString(dir)
	if err != nil {
		return "", err
	}
	buf := make([]uint16, 260)
	for {
		n, _, callErr := procGetShortPathNameW.Call(
			uintptr(unsafe.Pointer(dirPtr)),
			uintptr(unsafe.Pointer(&buf[0])),
			uintptr(len(buf)),
		)
		if n == 0 {
			return "", fmt.Errorf("GetShortPathNameW(%q): %w", dir, callErr)
		}
		if int(n) < len(buf) {
			shortDir := syscall.UTF16ToString(buf[:n])
			return filepath.Join(shortDir, filepath.Base(path)), nil
		}
		if int(n) > maxWindowsShortPathUTF16Size {
			return "", fmt.Errorf("GetShortPathNameW buffer too large: %d", n)
		}
		buf = make([]uint16, n)
	}
}

func isNormalCloseError(err error) bool {
	return errors.Is(err, net.ErrClosed) ||
		errors.Is(err, io.EOF) ||
		errors.Is(err, wsaeConnReset) ||
		errors.Is(err, wsaeConnAborted) ||
		errors.Is(err, errorNetnameDeleted) ||
		errors.Is(err, errorBrokenPipe) ||
		errors.Is(err, errorConnectionAborted)
}
