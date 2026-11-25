package main

import (
	"bytes"
	"crypto/hmac"
	"encoding/hex"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestComputeMACVectors(t *testing.T) {
	secret := make([]byte, secretSize)
	clientNonce := make([]byte, nonceSize)
	serverNonce := make([]byte, nonceSize)
	for i := range secret {
		secret[i] = byte(i)
		clientNonce[i] = byte(0x40 + i)
		serverNonce[i] = byte(0x80 + i)
	}
	s2c := computeMAC(secret, domainS2C, clientNonce, serverNonce)
	c2s := computeMAC(secret, domainC2S, clientNonce, serverNonce)
	if len(s2c) != macSize || len(c2s) != macSize {
		t.Fatalf("unexpected mac sizes: %d, %d", len(s2c), len(c2s))
	}
	if hmac.Equal(s2c, c2s) {
		t.Fatal("s2c and c2s MACs must differ by role domain")
	}
	// Vectors cross-checked independently against Python hmac/sha256 and tool/probe_af_unix.dart.
	const (
		wantS2C = "685a53102f14e134c8195d5554a2c18acde622c1927e18fcc6f1e6606e2dc49f"
		wantC2S = "4c63b67d5dbb4102ed8e8cd30c2def1c57c8b0cfc1a113ea271263ad4d04e6b4"
	)
	if got := hex.EncodeToString(s2c); got != wantS2C {
		t.Fatalf("s2c = %s, want %s", got, wantS2C)
	}
	if got := hex.EncodeToString(c2s); got != wantC2S {
		t.Fatalf("c2s = %s, want %s", got, wantC2S)
	}
}

func TestReadSecretAndLoopbackValidation(t *testing.T) {
	good := bytes.Repeat([]byte{0xab}, secretSize)
	got, err := readSecret(bytes.NewReader(good))
	if err != nil || !bytes.Equal(got, good) {
		t.Fatalf("readSecret(good) = (%x, %v)", got, err)
	}
	if _, err := readSecret(bytes.NewReader(good[:secretSize-1])); err == nil {
		t.Fatal("expected error for short secret")
	}
	if _, err := readSecret(bytes.NewReader(append(append([]byte{}, good...), 0x00))); err == nil {
		t.Fatal("expected error for trailing stdin byte")
	}
	for _, valid := range []string{"127.0.0.1:1", "127.0.0.1:8080", "127.0.0.1:65535"} {
		if err := validateLoopback(valid); err != nil {
			t.Fatalf("validateLoopback(%q) unexpected error: %v", valid, err)
		}
	}
	for _, bad := range []string{"", "localhost:8080", "0.0.0.0:8080", "127.0.0.1:0", "127.0.0.1:70000"} {
		if err := validateLoopback(bad); err == nil {
			t.Fatalf("validateLoopback(%q) unexpectedly accepted", bad)
		}
	}
}

func TestResolveBindPathTooLong(t *testing.T) {
	longDir := filepath.Join(t.TempDir(), strings.Repeat("абвгд", 20))
	longPath := filepath.Join(longDir, "w.sock")
	if len(longPath) <= maxUnixPathBytes {
		t.Fatalf("test path unexpectedly short: %d bytes", len(longPath))
	}
	if _, err := resolveBindPath(longPath); err == nil {
		t.Fatalf("expected error for %d-byte path on non-8.3 filesystem", len(longPath))
	}
}

func TestRemoveStaleSocketRefusesRegularFile(t *testing.T) {
	dir := t.TempDir()
	regular := filepath.Join(dir, "not-a-socket")
	if err := os.WriteFile(regular, []byte("keep me"), 0o600); err != nil {
		t.Fatalf("write regular file: %v", err)
	}
	if err := removeStaleSocket(regular); err == nil {
		t.Fatal("removeStaleSocket unexpectedly removed a regular file")
	}
	if _, err := os.Stat(regular); err != nil {
		t.Fatalf("regular file was deleted: %v", err)
	}

	// Genuine stale socket left on disk must be removed cleanly.
	stale := filepath.Join(dir, "stale.sock")
	if err := runLeaveStale(stale); err != nil {
		t.Fatalf("runLeaveStale: %v", err)
	}
	if err := removeStaleSocket(stale); err != nil {
		t.Fatalf("removeStaleSocket(stale): %v", err)
	}
	if _, err := os.Lstat(stale); !os.IsNotExist(err) {
		t.Fatalf("stale socket still exists: %v", err)
	}
}

func TestSecureUserOnlyDirRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	realDir := filepath.Join(root, "real")
	if err := os.MkdirAll(realDir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	linkDir := filepath.Join(root, "link")
	if err := os.Symlink(realDir, linkDir); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := secureUserOnlyDir(linkDir); err == nil {
		t.Fatal("secureUserOnlyDir unexpectedly accepted a symlink")
	}
	if err := secureUserOnlyDir(realDir); err != nil {
		t.Fatalf("secureUserOnlyDir(realDir): %v", err)
	}
}

func TestEndToEndMutualHandshakeAndRelay(t *testing.T) {
	upLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen upstream: %v", err)
	}
	defer upLn.Close()
	go func() {
		conn, err := upLn.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = io.Copy(conn, conn)
	}()

	dir := filepath.Join(t.TempDir(), "тест пробел")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := secureUserOnlyDir(dir); err != nil {
		t.Fatalf("secureUserOnlyDir: %v", err)
	}
	sockPath := filepath.Join(dir, "w.sock")
	bindPath, err := resolveBindPath(sockPath)
	if err != nil {
		t.Skipf("temp dir too long for AF_UNIX test (%d bytes): %v", len(sockPath), err)
	}

	// Leave a genuine stale socket and verify removeStaleSocket cleans it.
	if err := runLeaveStale(bindPath); err != nil {
		t.Fatalf("runLeaveStale: %v", err)
	}
	if err := removeStaleSocket(bindPath); err != nil {
		t.Fatalf("removeStaleSocket: %v", err)
	}

	ln, err := net.Listen("unix", bindPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer func() {
		_ = ln.Close()
		_ = os.Remove(bindPath)
	}()
	if err := verifySocketOwner(bindPath); err != nil {
		t.Fatalf("verifySocketOwner: %v", err)
	}

	secret := bytes.Repeat([]byte{0x42}, secretSize)
	serverErr := make(chan error, 1)
	go func() {
		conn, err := acceptAuthorized(ln, os.Getpid(), 5*time.Second)
		if err != nil {
			serverErr <- err
			return
		}
		_ = ln.Close()
		defer conn.Close()
		if err := performMutualHandshake(conn, secret); err != nil {
			serverErr <- err
			return
		}
		up, err := net.DialTimeout("tcp", upLn.Addr().String(), 3*time.Second)
		if err != nil {
			serverErr <- err
			return
		}
		defer up.Close()
		serverErr <- relay(conn, up)
	}()

	client, err := net.DialTimeout("unix", bindPath, 3*time.Second)
	if err != nil {
		t.Fatalf("dial unix: %v", err)
	}
	clientNonce := bytes.Repeat([]byte{0x11}, nonceSize)
	if _, err := client.Write(clientNonce); err != nil {
		t.Fatalf("write client nonce: %v", err)
	}
	reply := make([]byte, nonceSize+macSize)
	if _, err := io.ReadFull(client, reply); err != nil {
		t.Fatalf("read server handshake: %v", err)
	}
	serverNonce := reply[:nonceSize]
	serverMAC := reply[nonceSize:]
	if !hmac.Equal(serverMAC, computeMAC(secret, domainS2C, clientNonce, serverNonce)) {
		t.Fatal("server MAC mismatch")
	}
	clientMAC := computeMAC(secret, domainC2S, clientNonce, serverNonce)
	if _, err := client.Write(clientMAC); err != nil {
		t.Fatalf("write client mac: %v", err)
	}

	// Second connection must be refused since the listener is closed after the single authorized peer.
	if second, err := net.DialTimeout("unix", bindPath, 500*time.Millisecond); err == nil {
		_ = second.Close()
		t.Fatal("second connection unexpectedly succeeded")
	}

	payload := []byte("hello through unix relay")
	if _, err := client.Write(payload); err != nil {
		t.Fatalf("write payload: %v", err)
	}
	echo := make([]byte, len(payload))
	if _, err := io.ReadFull(client, echo); err != nil {
		t.Fatalf("read echo: %v", err)
	}
	if !bytes.Equal(echo, payload) {
		t.Fatalf("echo %q != %q", echo, payload)
	}
	_ = client.Close()

	if err := <-serverErr; err != nil {
		t.Fatalf("server error: %v", err)
	}
}

func TestMutualHandshakeRejectsBadClientMAC(t *testing.T) {
	sockPath := filepath.Join(t.TempDir(), "badmac.sock")
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer func() {
		_ = ln.Close()
		_ = os.Remove(sockPath)
	}()

	secret := bytes.Repeat([]byte{0x99}, secretSize)
	errCh := make(chan error, 1)
	go func() {
		conn, err := acceptAuthorized(ln, os.Getpid(), 5*time.Second)
		if err != nil {
			errCh <- err
			return
		}
		defer conn.Close()
		errCh <- performMutualHandshake(conn, secret)
	}()

	client, err := net.DialTimeout("unix", sockPath, 3*time.Second)
	if err != nil {
		t.Fatalf("dial unix: %v", err)
	}
	defer client.Close()
	_, _ = client.Write(bytes.Repeat([]byte{0x01}, nonceSize))
	reply := make([]byte, nonceSize+macSize)
	if _, err := io.ReadFull(client, reply); err != nil {
		t.Fatalf("read reply: %v", err)
	}
	// Send bogus client MAC.
	_, _ = client.Write(bytes.Repeat([]byte{0x00}, macSize))

	if err := <-errCh; err == nil || !strings.Contains(err.Error(), "client handshake MAC mismatch") {
		t.Fatalf("expected client MAC mismatch error, got: %v", err)
	}
}
