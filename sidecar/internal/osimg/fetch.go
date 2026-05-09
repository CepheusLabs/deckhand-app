// Package osimg downloads OS images with resume + sha256 verification.
package osimg

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"time"

	"github.com/CepheusLabs/deckhand/sidecar/internal/rpc"
	"github.com/ulikunitz/xz"
)

// DownloadProgress is the payload of `progress` notifications emitted
// while a download is in flight.
type DownloadProgress struct {
	BytesDone  int64  `json:"bytes_done"`
	BytesTotal int64  `json:"bytes_total"`
	Phase      string `json:"phase"`
}

// httpClient is shared across Download calls so the underlying TCP
// connections are reused across retries. DefaultClient has no timeouts
// at all, which made a hostile server able to stall the sidecar forever.
var httpClient = &http.Client{
	// No client-level Timeout because the caller supplies a context
	// deadline that covers the entire transfer; a fixed client timeout
	// would also kill slow-but-valid downloads on rural connections.
	Transport: &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   30 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		IdleConnTimeout:       90 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	},
	CheckRedirect: checkDownloadRedirect,
}

var maxDownloadBytes int64 = 64 * 1024 * 1024 * 1024

const maxErrorDrainBytes int64 = 1 << 20
const (
	xzMagic0 = 0xfd
	xzMagic1 = 0x37
	xzMagic2 = 0x7a
	xzMagic3 = 0x58
	xzMagic4 = 0x5a
	xzMagic5 = 0x00
)
const (
	xzFooterLen     = 12
	xzMinIndexSize  = 4
	xzMaxIndexSize  = int64(1<<32) * 4
	maxInt64        = int64(9223372036854775807)
	xzProgressEvery = 1 << 20
)

var approvedDownloadHostSuffixes = []string{
	"github.com",
	"githubusercontent.com",
	"github-releases.githubusercontent.com",
	"raspberrypi.com",
	"raspberrypi.org",
}

// Download fetches rawURL to destPath, streaming progress through note.
// If expectedSha is non-empty, the final file is verified against it.
//
// The network artifact streams to destPath+".download.part"; compressed
// artifacts are then extracted through destPath+".part" before the final
// rename. A verified .download.part is intentionally reusable so retries
// after an interrupted extraction do not fetch the same large image again.
func Download(ctx context.Context, rawURL, destPath, expectedSha string, note rpc.Notifier) (string, error) {
	// Enforce https - refuse file://, ftp://, ssh://, plain http, etc. A
	// compromised UI or a malicious profile could otherwise instruct
	// the sidecar to read an arbitrary local file as an "image".
	parsed, perr := url.Parse(rawURL)
	if perr != nil {
		return "", fmt.Errorf("parse url %q: %w", rawURL, perr)
	}
	if err := validateDownloadURL(parsed); err != nil {
		return "", err
	}

	downloadPath := destPath + ".download.part"
	finalPartPath := destPath + ".part"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}

	if _, err := os.Lstat(destPath); err == nil {
		return "", fmt.Errorf("dest already exists: %s", destPath)
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("inspect dest: %w", err)
	}
	if _, err := os.Lstat(finalPartPath); err == nil {
		return "", fmt.Errorf("partial dest already exists: %s", finalPartPath)
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("inspect partial dest: %w", err)
	}
	if reusedPart, actual, err := reuseVerifiedDownloadPart(downloadPath, expectedSha); err != nil {
		return "", err
	} else if reusedPart {
		return finishDownloadedFile(rawURL, destPath, downloadPath, finalPartPath, actual, 0, 0, note)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("do request: %w", err)
	}
	defer func() {
		// Bounded drain: enough to keep small error/redirect bodies from
		// poisoning keep-alive, not enough for a hostile peer to make us
		// read unbounded bytes on cleanup.
		_, _ = io.CopyN(io.Discard, resp.Body, maxErrorDrainBytes)
		_ = resp.Body.Close()
	}()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status %d for %s", resp.StatusCode, sanitizeURL(rawURL))
	}
	if resp.ContentLength > maxDownloadBytes {
		return "", fmt.Errorf("download is too large: content-length %d exceeds %d", resp.ContentLength, maxDownloadBytes)
	}
	if resp.ContentLength < 0 {
		return "", fmt.Errorf("download size is unknown; refusing unbounded transfer")
	}

	if _, err := os.Lstat(downloadPath); err == nil {
		return "", fmt.Errorf("partial dest already exists: %s", downloadPath)
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("inspect partial dest: %w", err)
	}
	f, err := os.OpenFile(downloadPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", fmt.Errorf("open dest: %w", err)
	}

	// removeTmpOnErr fires on every non-success return so a failed or
	// cancelled download does not leave a corrupt .part masquerading as
	// a valid image on the next run. Set to false immediately before
	// the rename succeeds.
	removeTmpOnErr := true
	defer func() {
		_ = f.Close()
		if removeTmpOnErr {
			_ = os.Remove(downloadPath)
			_ = os.Remove(finalPartPath)
		}
	}()

	hasher := sha256.New()
	mw := io.MultiWriter(f, hasher)

	total := resp.ContentLength
	var done int64
	lastNotified := int64(0)
	buf := make([]byte, 1<<20)

	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := mw.Write(buf[:n]); werr != nil {
				return "", fmt.Errorf("write: %w", werr)
			}
			done += int64(n)
			if done > maxDownloadBytes {
				return "", fmt.Errorf("download exceeded maximum size %d", maxDownloadBytes)
			}
			if total >= 0 && done > total {
				return "", fmt.Errorf("download exceeded declared content-length %d", total)
			}
			if note != nil && done-lastNotified >= 4<<20 { // every 4 MiB
				note.Notify("progress", DownloadProgress{BytesDone: done, BytesTotal: total, Phase: "downloading"})
				lastNotified = done
			}
		}
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			return "", fmt.Errorf("read: %w", rerr)
		}
	}

	if err := f.Sync(); err != nil {
		return "", fmt.Errorf("sync: %w", err)
	}
	if err := f.Close(); err != nil {
		return "", fmt.Errorf("close: %w", err)
	}

	actual := hex.EncodeToString(hasher.Sum(nil))
	if expectedSha != "" && actual != expectedSha {
		return "", fmt.Errorf("sha256 mismatch: got %s, want %s", actual, expectedSha)
	}

	removeTmpOnErr = false
	return finishDownloadedFile(rawURL, destPath, downloadPath, finalPartPath, actual, done, total, note)
}

func finishDownloadedFile(
	rawURL, destPath, downloadPath, finalPartPath, downloadedSha string,
	done, total int64,
	note rpc.Notifier,
) (string, error) {
	removeExtractedOnErr := true
	defer func() {
		if removeExtractedOnErr {
			_ = os.Remove(finalPartPath)
		}
	}()
	isXZ, err := downloadedFileIsXZ(rawURL, downloadPath)
	if err != nil {
		return "", err
	}
	if isXZ {
		imageSha, imageBytes, err := decompressXZ(downloadPath, finalPartPath, note)
		if err != nil {
			return "", err
		}
		if _, err := os.Lstat(destPath); err == nil {
			return "", fmt.Errorf("dest already exists before rename: %s", destPath)
		} else if !os.IsNotExist(err) {
			return "", fmt.Errorf("inspect dest before rename: %w", err)
		}
		if err := os.Rename(finalPartPath, destPath); err != nil {
			return "", fmt.Errorf("rename extracted image to final path: %w", err)
		}
		removeExtractedOnErr = false
		_ = os.Remove(downloadPath)
		if note != nil {
			note.Notify("progress", DownloadProgress{BytesDone: imageBytes, BytesTotal: imageBytes, Phase: "done"})
		}
		return imageSha, nil
	}

	if _, err := os.Lstat(destPath); err == nil {
		return "", fmt.Errorf("dest already exists before rename: %s", destPath)
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("inspect dest before rename: %w", err)
	}

	// Atomic-ish rename. On POSIX this is a single rename(2) syscall.
	// We re-check the final path immediately before rename so a normal
	// stale destination cannot be replaced.
	if err := os.Rename(downloadPath, destPath); err != nil {
		return "", fmt.Errorf("rename to final path: %w", err)
	}
	removeExtractedOnErr = false

	if note != nil {
		note.Notify("progress", DownloadProgress{BytesDone: done, BytesTotal: total, Phase: "done"})
	}
	return downloadedSha, nil
}

func reuseVerifiedDownloadPart(downloadPath, expectedSha string) (bool, string, error) {
	info, err := os.Lstat(downloadPath)
	if os.IsNotExist(err) {
		return false, "", nil
	}
	if err != nil {
		return false, "", fmt.Errorf("inspect partial dest: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return false, "", fmt.Errorf("partial dest %q must be a regular file", downloadPath)
	}
	if expectedSha == "" {
		return false, "", nil
	}
	actual, err := sha256File(downloadPath)
	if err != nil {
		return false, "", fmt.Errorf("hash partial dest: %w", err)
	}
	if actual == expectedSha {
		return true, actual, nil
	}
	if err := os.Remove(downloadPath); err != nil {
		return false, "", fmt.Errorf("remove stale partial dest %q: %w", downloadPath, err)
	}
	return false, actual, nil
}

func sha256File(filePath string) (string, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	hasher := sha256.New()
	if _, err := io.Copy(hasher, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func downloadedFileIsXZ(rawURL, filePath string) (bool, error) {
	if u, err := url.Parse(rawURL); err == nil {
		if strings.HasSuffix(strings.ToLower(path.Base(u.Path)), ".xz") {
			return true, nil
		}
	}
	f, err := os.Open(filePath)
	if err != nil {
		return false, fmt.Errorf("open downloaded file for xz check: %w", err)
	}
	defer func() { _ = f.Close() }()
	var magic [6]byte
	n, err := io.ReadFull(f, magic[:])
	if errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("read downloaded file magic: %w", err)
	}
	return n == len(magic) &&
		magic[0] == xzMagic0 &&
		magic[1] == xzMagic1 &&
		magic[2] == xzMagic2 &&
		magic[3] == xzMagic3 &&
		magic[4] == xzMagic4 &&
		magic[5] == xzMagic5, nil
}

func decompressXZ(sourcePath, destPath string, note rpc.Notifier) (string, int64, error) {
	uncompressedTotal, totalKnown, err := xzUncompressedSize(sourcePath)
	if err != nil {
		return "", 0, fmt.Errorf("probe xz uncompressed size: %w", err)
	}
	if !totalKnown {
		uncompressedTotal = 0
	}

	src, err := os.Open(sourcePath)
	if err != nil {
		return "", 0, fmt.Errorf("open xz image: %w", err)
	}
	defer func() { _ = src.Close() }()
	xr, err := xz.NewReader(src)
	if err != nil {
		return "", 0, fmt.Errorf("open xz stream: %w", err)
	}
	dst, err := os.OpenFile(destPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", 0, fmt.Errorf("open extracted image: %w", err)
	}
	defer func() { _ = dst.Close() }()

	hasher := sha256.New()
	mw := io.MultiWriter(dst, hasher)
	buf := make([]byte, 1<<20)
	var done int64
	lastNotified := int64(0)
	if note != nil {
		note.Notify("progress", DownloadProgress{BytesDone: 0, BytesTotal: uncompressedTotal, Phase: "extracting"})
	}
	for {
		n, rerr := xr.Read(buf)
		if n > 0 {
			if _, werr := mw.Write(buf[:n]); werr != nil {
				return "", done, fmt.Errorf("write extracted image: %w", werr)
			}
			done += int64(n)
			if done > maxDownloadBytes {
				return "", done, fmt.Errorf("extracted image exceeded maximum size %d", maxDownloadBytes)
			}
			if uncompressedTotal > 0 && done > uncompressedTotal {
				return "", done, fmt.Errorf("extracted image exceeded declared uncompressed size %d", uncompressedTotal)
			}
			if note != nil && done-lastNotified >= xzProgressEvery {
				note.Notify("progress", DownloadProgress{BytesDone: done, BytesTotal: uncompressedTotal, Phase: "extracting"})
				lastNotified = done
			}
		}
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			return "", done, fmt.Errorf("read xz stream: %w", rerr)
		}
	}
	if note != nil && done != lastNotified {
		note.Notify("progress", DownloadProgress{BytesDone: done, BytesTotal: uncompressedTotal, Phase: "extracting"})
	}
	if err := dst.Sync(); err != nil {
		return "", done, fmt.Errorf("sync extracted image: %w", err)
	}
	if err := dst.Close(); err != nil {
		return "", done, fmt.Errorf("close extracted image: %w", err)
	}
	return hex.EncodeToString(hasher.Sum(nil)), done, nil
}

func xzUncompressedSize(filePath string) (int64, bool, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return 0, false, fmt.Errorf("open xz for size probe: %w", err)
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil {
		return 0, false, fmt.Errorf("stat xz for size probe: %w", err)
	}
	end := info.Size()
	var total int64
	for {
		trimmed, err := trimXZStreamPadding(f, end)
		if err != nil {
			return 0, false, err
		}
		end = trimmed
		if end == 0 {
			return total, total > 0, nil
		}
		streamBytes, streamStart, err := xzStreamUncompressedSizeAt(f, end)
		if err != nil {
			return 0, false, err
		}
		if total > maxInt64-streamBytes {
			return 0, false, errors.New("xz: uncompressed size overflows int64")
		}
		total += streamBytes
		if streamStart == 0 {
			return total, true, nil
		}
		end = streamStart
	}
}

func trimXZStreamPadding(f *os.File, end int64) (int64, error) {
	var p [4]byte
	for end >= 4 {
		if _, err := f.ReadAt(p[:], end-4); err != nil {
			return 0, fmt.Errorf("read xz stream padding: %w", err)
		}
		if p != [4]byte{} {
			return end, nil
		}
		end -= 4
	}
	return end, nil
}

func xzStreamUncompressedSizeAt(f *os.File, streamEnd int64) (uncompressedSize, streamStart int64, err error) {
	if streamEnd < int64(xz.HeaderLen+xzFooterLen+xzMinIndexSize) {
		return 0, 0, errors.New("xz: stream is too small")
	}
	indexSize, flags, err := readXZFooterAt(f, streamEnd-xzFooterLen)
	if err != nil {
		return 0, 0, err
	}
	indexStart := streamEnd - xzFooterLen - indexSize
	if indexStart < int64(xz.HeaderLen) {
		return 0, 0, errors.New("xz: index points before stream header")
	}
	uncompressedSize, paddedBlocksSize, err := readXZIndexAt(f, indexStart, indexSize)
	if err != nil {
		return 0, 0, err
	}
	streamStart = indexStart - paddedBlocksSize - int64(xz.HeaderLen)
	if streamStart < 0 {
		return 0, 0, errors.New("xz: stream size points before file start")
	}
	if err := validateXZHeaderAt(f, streamStart, flags); err != nil {
		return 0, 0, err
	}
	return uncompressedSize, streamStart, nil
}

func readXZFooterAt(f *os.File, offset int64) (indexSize int64, flags byte, err error) {
	var data [xzFooterLen]byte
	if _, err := f.ReadAt(data[:], offset); err != nil {
		return 0, 0, fmt.Errorf("read xz footer: %w", err)
	}
	if !bytes.Equal(data[10:], []byte{'Y', 'Z'}) {
		return 0, 0, errors.New("xz: footer magic invalid")
	}
	if binary.LittleEndian.Uint32(data[:4]) != crc32.ChecksumIEEE(data[4:10]) {
		return 0, 0, errors.New("xz: footer checksum error")
	}
	if data[8] != 0 || !validXZFlags(data[9]) {
		return 0, 0, errors.New("xz: invalid footer flags")
	}
	indexSize = (int64(binary.LittleEndian.Uint32(data[4:8])) + 1) * 4
	if indexSize < xzMinIndexSize || indexSize > xzMaxIndexSize || indexSize%4 != 0 {
		return 0, 0, errors.New("xz: index size out of range")
	}
	return indexSize, data[9], nil
}

func validateXZHeaderAt(f *os.File, offset int64, expectedFlags byte) error {
	var data [xz.HeaderLen]byte
	if _, err := f.ReadAt(data[:], offset); err != nil {
		return fmt.Errorf("read xz header: %w", err)
	}
	if !bytes.Equal(data[:6], []byte{xzMagic0, xzMagic1, xzMagic2, xzMagic3, xzMagic4, xzMagic5}) {
		return errors.New("xz: header magic invalid")
	}
	if data[6] != 0 || !validXZFlags(data[7]) {
		return errors.New("xz: invalid header flags")
	}
	if data[7] != expectedFlags {
		return errors.New("xz: header/footer flags mismatch")
	}
	if binary.LittleEndian.Uint32(data[8:]) != crc32.ChecksumIEEE(data[6:8]) {
		return errors.New("xz: header checksum error")
	}
	return nil
}

func readXZIndexAt(f *os.File, offset, size int64) (uncompressedSize, paddedBlocksSize int64, err error) {
	if size < xzMinIndexSize || size%4 != 0 {
		return 0, 0, errors.New("xz: invalid index size")
	}
	section := io.NewSectionReader(f, offset, size)
	crc := crc32.NewIEEE()
	payload := io.TeeReader(section, crc)
	br := &countingByteReader{r: payload}

	indicator, err := br.ReadByte()
	if err != nil {
		return 0, 0, fmt.Errorf("read xz index indicator: %w", err)
	}
	if indicator != 0 {
		return 0, 0, errors.New("xz: index indicator invalid")
	}
	records, err := binary.ReadUvarint(br)
	if err != nil {
		return 0, 0, fmt.Errorf("read xz index record count: %w", err)
	}
	if records > uint64(size/2) {
		return 0, 0, errors.New("xz: index record count impossible for index size")
	}
	for i := uint64(0); i < records; i++ {
		unpadded, err := readXZIndexUvarint(br, "unpadded size")
		if err != nil {
			return 0, 0, err
		}
		uncompressed, err := readXZIndexUvarint(br, "uncompressed size")
		if err != nil {
			return 0, 0, err
		}
		if unpadded <= 0 {
			return 0, 0, errors.New("xz: block unpadded size must be positive")
		}
		blockPadding := xzPadLen(unpadded)
		if unpadded > maxInt64-blockPadding {
			return 0, 0, errors.New("xz: padded block size overflows int64")
		}
		padded := unpadded + blockPadding
		if paddedBlocksSize > maxInt64-padded {
			return 0, 0, errors.New("xz: padded block sizes overflow int64")
		}
		paddedBlocksSize += padded
		if uncompressedSize > maxInt64-uncompressed {
			return 0, 0, errors.New("xz: uncompressed size overflows int64")
		}
		uncompressedSize += uncompressed
	}

	paddingLen := xzPadLen(br.n)
	if paddingLen > 0 {
		padding := make([]byte, paddingLen)
		if _, err := io.ReadFull(payload, padding); err != nil {
			return 0, 0, fmt.Errorf("read xz index padding: %w", err)
		}
		for _, b := range padding {
			if b != 0 {
				return 0, 0, errors.New("xz: non-zero byte in index padding")
			}
		}
	}
	payloadSize := br.n + int64(paddingLen)
	if payloadSize+4 != size {
		return 0, 0, errors.New("xz: index length mismatch")
	}
	var checksum [4]byte
	if _, err := io.ReadFull(section, checksum[:]); err != nil {
		return 0, 0, fmt.Errorf("read xz index checksum: %w", err)
	}
	if binary.LittleEndian.Uint32(checksum[:]) != crc.Sum32() {
		return 0, 0, errors.New("xz: index checksum error")
	}
	return uncompressedSize, paddedBlocksSize, nil
}

func readXZIndexUvarint(r *countingByteReader, field string) (int64, error) {
	value, err := binary.ReadUvarint(r)
	if err != nil {
		return 0, fmt.Errorf("read xz index %s: %w", field, err)
	}
	if value > uint64(maxInt64) {
		return 0, fmt.Errorf("xz: index %s overflows int64", field)
	}
	return int64(value), nil
}

func xzPadLen(n int64) int64 {
	if rem := n % 4; rem != 0 {
		return 4 - rem
	}
	return 0
}

func validXZFlags(flags byte) bool {
	return flags == xz.None || flags == xz.CRC32 || flags == xz.CRC64 || flags == xz.SHA256
}

type countingByteReader struct {
	r io.Reader
	n int64
}

func (r *countingByteReader) ReadByte() (byte, error) {
	var one [1]byte
	if _, err := io.ReadFull(r.r, one[:]); err != nil {
		return 0, err
	}
	r.n++
	return one[0], nil
}

func validateDownloadURL(parsed *url.URL) error {
	if parsed.Scheme != "https" {
		return fmt.Errorf("url scheme must be https, got %q", parsed.Scheme)
	}
	if parsed.Host == "" {
		return fmt.Errorf("url has no host")
	}
	if parsed.User != nil {
		return fmt.Errorf("url must not contain embedded credentials")
	}
	if !isApprovedDownloadHost(parsed.Hostname()) {
		return fmt.Errorf("url host %q is not approved for OS image downloads", parsed.Hostname())
	}
	return nil
}

func checkDownloadRedirect(req *http.Request, via []*http.Request) error {
	if err := validateDownloadURL(req.URL); err != nil {
		return err
	}
	return nil
}

func sanitizeURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return "[redacted-url]"
	}
	u.User = nil
	u.RawQuery = ""
	u.Fragment = ""
	return u.String()
}

func isApprovedDownloadHost(host string) bool {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if host == "localhost" {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	for _, suffix := range approvedDownloadHostSuffixes {
		suffix = strings.ToLower(strings.TrimPrefix(suffix, "."))
		if host == suffix || strings.HasSuffix(host, "."+suffix) {
			return true
		}
	}
	return false
}
