// AF_UNIX worker-link probe for the desktop release transport.
//
// Listener mode (default):
//   - reads a 32-byte secret from stdin (never argv or environment) and requires exact length + EOF;
//   - verifies the socket parent directory is a real directory (not a symlink/reparse point) owned
//     by the current user, then applies user-only permissions (protected DACL on Windows, 0700 on Unix);
//   - checks the socket path length in UTF-8 (<= 107 bytes), with Windows 8.3 shortening fallback;
//   - refuses to clobber non-socket files; removes only a genuine stale AF_UNIX socket before bind;
//   - binds AF_UNIX, verifies the socket file owner via handle (no reparse traversal on Windows);
//   - prints "READY <bind-path>" on stdout once listening;
//   - waits up to --accept-timeout for one authorized peer whose OS-reported PID
//     (SIO_AF_UNIX_GETPEERPID on Windows ignoring bytesReturned == 0, SO_PEERCRED on Unix)
//     matches --peer-pid (default: parent PID), rejecting any other PID;
//   - closes the listener immediately once the authorized peer is accepted (single connection);
//   - performs mutual transcript-bound HMAC-SHA256 handshake on the raw stream before HTTP/2:
//     1. client -> worker: clientNonce (32 B)
//     2. worker -> client: serverNonce (32 B) || HMAC-SHA256(secret, "niko-worker-v1:s2c:" || clientNonce || serverNonce) (32 B)
//     3. client -> worker: HMAC-SHA256(secret, "niko-worker-v1:c2s:" || clientNonce || serverNonce) (32 B)
//     worker verifies client MAC in constant time before dialing --upstream (127.0.0.1:<port>);
//   - forwards raw bytes bidirectionally (io.Copy) without terminating HTTP/2 or gRPC.
//
// Helper modes:
//
//	--connect <path>      connect as a separate child process (wrong PID) to verify peer-PID rejection.
//	--leave-stale <path>  bind an AF_UNIX socket and exit without unlinking it, for stale-socket tests.
package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	secretSize       = 32
	nonceSize        = 32
	macSize          = 32
	maxUnixPathBytes = 107 // sockaddr_un.sun_path is 108 bytes including trailing NUL
	domainS2C        = "niko-worker-v1:s2c:"
	domainC2S        = "niko-worker-v1:c2s:"
	handshakeTimeout = 5 * time.Second
	defaultAcceptTTL = 30 * time.Second
)

var loopbackAddrRe = regexp.MustCompile(`^127\.0\.0\.1:([1-9][0-9]{0,4})$`)

func main() {
	socketPath := flag.String("socket", "", "AF_UNIX socket path to bind")
	upstream := flag.String("upstream", "", "upstream 127.0.0.1:<port> to forward raw bytes to")
	peerPID := flag.Int("peer-pid", os.Getppid(), "expected client PID (defaults to parent PID)")
	secureDir := flag.Bool("secure-dir", true, "apply user-only permissions to socket parent directory")
	acceptTTL := flag.Duration("accept-timeout", defaultAcceptTTL, "maximum time to wait for authorized peer")
	connectPath := flag.String("connect", "", "helper mode: connect to socket path as a rogue peer")
	leaveStalePath := flag.String("leave-stale", "", "helper mode: bind socket and leave it unlinked on disk")
	flag.Parse()

	if *connectPath != "" {
		if err := runRogueConnect(*connectPath); err != nil {
			fmt.Fprintf(os.Stderr, "rogue connect error: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if *leaveStalePath != "" {
		if err := runLeaveStale(*leaveStalePath); err != nil {
			fmt.Fprintf(os.Stderr, "leave stale error: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if err := runListener(*socketPath, *upstream, *peerPID, *secureDir, *acceptTTL); err != nil {
		fmt.Fprintf(os.Stderr, "probe_af_unix: %v\n", err)
		os.Exit(1)
	}
}

func validateLoopback(addr string) error {
	m := loopbackAddrRe.FindStringSubmatch(addr)
	if m == nil {
		return fmt.Errorf("--upstream must be 127.0.0.1:<port>, got %q", addr)
	}
	port, err := strconv.Atoi(m[1])
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("--upstream port out of range: %q", addr)
	}
	return nil
}

func readSecret(r io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, secretSize+1))
	if err != nil {
		return nil, fmt.Errorf("read secret from stdin: %w", err)
	}
	if len(data) != secretSize {
		zeroBytes(data)
		return nil, fmt.Errorf("expected exactly %d secret bytes on stdin, got %d", secretSize, len(data))
	}
	return data, nil
}

func computeMAC(secret []byte, domain string, clientNonce, serverNonce []byte) []byte {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(domain))
	mac.Write(clientNonce)
	mac.Write(serverNonce)
	return mac.Sum(nil)
}

func zeroBytes(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

func resolveBindPath(socketPath string) (string, error) {
	if strings.TrimSpace(socketPath) == "" {
		return "", errors.New("--socket is required")
	}
	if len(socketPath) <= maxUnixPathBytes {
		return socketPath, nil
	}
	shortened, err := shortenSocketPath(socketPath)
	if err != nil {
		return "", fmt.Errorf("socket path is %d UTF-8 bytes (limit %d) and shortening failed: %w",
			len(socketPath), maxUnixPathBytes, err)
	}
	if len(shortened) > maxUnixPathBytes {
		return "", fmt.Errorf("socket path is %d UTF-8 bytes (limit %d), still %d bytes after 8.3 shortening",
			len(socketPath), maxUnixPathBytes, len(shortened))
	}
	fmt.Fprintf(os.Stderr, "shortened socket path from %d to %d UTF-8 bytes: %s\n",
		len(socketPath), len(shortened), shortened)
	return shortened, nil
}

func removeStaleSocket(path string) error {
	isSock, exists, err := isUnixSocketFile(path)
	if err != nil {
		return fmt.Errorf("inspect existing socket path: %w", err)
	}
	if !exists {
		return nil
	}
	if !isSock {
		return fmt.Errorf("refusing to remove non-socket file at %q", path)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale socket: %w", err)
	}
	return nil
}

func runListener(socketPath, upstream string, expectedPID int, secureDir bool, acceptTTL time.Duration) error {
	if err := validateLoopback(upstream); err != nil {
		return err
	}
	if expectedPID <= 0 {
		return fmt.Errorf("invalid --peer-pid %d", expectedPID)
	}
	secret, err := readSecret(os.Stdin)
	if err != nil {
		return err
	}
	defer zeroBytes(secret)

	dir := filepath.Dir(socketPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create socket directory: %w", err)
	}
	if secureDir {
		if err := secureUserOnlyDir(dir); err != nil {
			return fmt.Errorf("secure socket directory: %w", err)
		}
	}

	bindPath, err := resolveBindPath(socketPath)
	if err != nil {
		return err
	}

	if err := removeStaleSocket(bindPath); err != nil {
		return err
	}

	ln, err := net.Listen("unix", bindPath)
	if err != nil {
		return fmt.Errorf("listen unix %q: %w", bindPath, err)
	}
	defer func() {
		_ = ln.Close()
		_ = os.Remove(bindPath)
	}()

	if err := verifySocketOwner(bindPath); err != nil {
		return fmt.Errorf("verify socket owner: %w", err)
	}

	// Signal readiness and the exact resolved path to the parent.
	fmt.Fprintf(os.Stdout, "READY %s\n", bindPath)
	_ = os.Stdout.Sync()

	conn, err := acceptAuthorized(ln, expectedPID, acceptTTL)
	if err != nil {
		return err
	}
	// Accept only one authorized connection: close the listener immediately.
	_ = ln.Close()
	defer conn.Close()

	if err := performMutualHandshake(conn, secret); err != nil {
		return fmt.Errorf("handshake: %w", err)
	}

	up, err := net.DialTimeout("tcp", upstream, 5*time.Second)
	if err != nil {
		return fmt.Errorf("dial upstream %s: %w", upstream, err)
	}
	defer up.Close()

	return relay(conn, up)
}

func acceptAuthorized(ln net.Listener, expectedPID int, ttl time.Duration) (net.Conn, error) {
	if ttl > 0 {
		if uln, ok := ln.(*net.UnixListener); ok {
			_ = uln.SetDeadline(time.Now().Add(ttl))
		}
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			return nil, fmt.Errorf("accept: %w", err)
		}
		pid, detail, err := peerPID(conn)
		if err != nil {
			fmt.Fprintf(os.Stderr, "REJECT peer PID query failed (%s): %v\n", detail, err)
			_ = conn.Close()
			continue
		}
		if pid != expectedPID {
			fmt.Fprintf(os.Stderr, "REJECT peer_pid=%d expected=%d (%s)\n", pid, expectedPID, detail)
			_ = conn.Close()
			continue
		}
		fmt.Fprintf(os.Stderr, "ACCEPT peer_pid=%d (%s)\n", pid, detail)
		return conn, nil
	}
}

func performMutualHandshake(conn net.Conn, secret []byte) error {
	if err := conn.SetDeadline(time.Now().Add(handshakeTimeout)); err != nil {
		return err
	}
	clientNonce := make([]byte, nonceSize)
	if _, err := io.ReadFull(conn, clientNonce); err != nil {
		return fmt.Errorf("read client nonce: %w", err)
	}

	serverNonce := make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, serverNonce); err != nil {
		return fmt.Errorf("generate server nonce: %w", err)
	}
	serverMAC := computeMAC(secret, domainS2C, clientNonce, serverNonce)

	reply := make([]byte, 0, nonceSize+macSize)
	reply = append(reply, serverNonce...)
	reply = append(reply, serverMAC...)
	if _, err := conn.Write(reply); err != nil {
		return fmt.Errorf("write server handshake: %w", err)
	}

	clientMAC := make([]byte, macSize)
	if _, err := io.ReadFull(conn, clientMAC); err != nil {
		return fmt.Errorf("read client mac: %w", err)
	}
	expectedClientMAC := computeMAC(secret, domainC2S, clientNonce, serverNonce)
	if !hmac.Equal(clientMAC, expectedClientMAC) {
		return errors.New("client handshake MAC mismatch")
	}

	return conn.SetDeadline(time.Time{})
}

func relay(a, b net.Conn) error {
	errCh := make(chan error, 2)
	go func() {
		_, err := io.Copy(b, a)
		closeWrite(b)
		errCh <- err
	}()
	go func() {
		_, err := io.Copy(a, b)
		closeWrite(a)
		errCh <- err
	}()
	err1 := <-errCh
	// Wait briefly for the reverse direction to drain cleanly before forcing close.
	var err2 error
	select {
	case err2 = <-errCh:
	case <-time.After(2 * time.Second):
		_ = a.Close()
		_ = b.Close()
		err2 = <-errCh
	}
	_ = a.Close()
	_ = b.Close()
	if err1 != nil && !isNormalCloseError(err1) {
		return err1
	}
	if err2 != nil && !isNormalCloseError(err2) {
		return err2
	}
	return nil
}

func closeWrite(c net.Conn) {
	type halfCloser interface {
		CloseWrite() error
	}
	if hc, ok := c.(halfCloser); ok {
		_ = hc.CloseWrite()
	}
}

func runRogueConnect(socketPath string) error {
	conn, err := net.DialTimeout("unix", socketPath, 3*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stdout, "REJECTED dial: %v\n", err)
		return nil
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	var nonce [nonceSize]byte
	_, _ = conn.Write(nonce[:])
	reply := make([]byte, nonceSize+macSize)
	n, err := io.ReadFull(conn, reply)
	if err != nil && n == 0 {
		fmt.Fprintf(os.Stdout, "REJECTED closed: %v\n", err)
		return nil
	}
	return fmt.Errorf("expected rejection, but received %d bytes (err=%v)", n, err)
}

func runLeaveStale(socketPath string) error {
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		return err
	}
	bindPath, err := resolveBindPath(socketPath)
	if err != nil {
		return err
	}
	_ = os.Remove(bindPath)
	ln, err := net.Listen("unix", bindPath)
	if err != nil {
		return err
	}
	if uln, ok := ln.(*net.UnixListener); ok {
		uln.SetUnlinkOnClose(false)
	}
	return ln.Close()
}
