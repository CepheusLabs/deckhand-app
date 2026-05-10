package disks

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestReadImageCopiesFileHashesAndNotifiesProgress(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source.img")
	output := filepath.Join(root, "backup.img")
	body := bytes.Repeat([]byte("deckhand-backup-block"), 1<<20)
	if err := os.WriteFile(source, body, 0o600); err != nil {
		t.Fatalf("write source: %v", err)
	}

	note := &recordingNotifier{}
	gotSHA, err := ReadImage(context.Background(), source, output, note)
	if err != nil {
		t.Fatalf("ReadImage: %v", err)
	}

	sum := sha256.Sum256(body)
	if gotSHA != hex.EncodeToString(sum[:]) {
		t.Fatalf("sha mismatch: got %s want %s", gotSHA, hex.EncodeToString(sum[:]))
	}
	gotBody, err := os.ReadFile(output)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	if !bytes.Equal(gotBody, body) {
		t.Fatalf("output bytes differ from source")
	}
	if len(note.events) == 0 {
		t.Fatalf("expected progress notifications")
	}
	last := note.events[len(note.events)-1]
	if last.method != "progress" {
		t.Fatalf("last notification method = %q, want progress", last.method)
	}
	progress, ok := last.params.(ReadProgress)
	if !ok {
		t.Fatalf("last params type = %T, want ReadProgress", last.params)
	}
	if progress.Phase != "done" || progress.BytesDone != int64(len(body)) {
		t.Fatalf("unexpected final progress: %+v", progress)
	}
}

func TestReadImageRejectsExistingOutput(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source.img")
	output := filepath.Join(root, "backup.img")
	if err := os.WriteFile(source, []byte("source"), 0o600); err != nil {
		t.Fatalf("write source: %v", err)
	}
	if err := os.WriteFile(output, []byte("existing"), 0o600); err != nil {
		t.Fatalf("write output: %v", err)
	}

	if _, err := ReadImage(context.Background(), source, output, nil); err == nil {
		t.Fatalf("expected existing output to be rejected")
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	if string(got) != "existing" {
		t.Fatalf("output was overwritten: %q", got)
	}
}

func TestReadImageRemovesPartialOutputOnCancellation(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source.img")
	output := filepath.Join(root, "backup.img")
	if err := os.WriteFile(source, bytes.Repeat([]byte("x"), 4096), 0o600); err != nil {
		t.Fatalf("write source: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := ReadImage(ctx, source, output, nil); err == nil {
		t.Fatalf("expected cancellation error")
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatalf("partial output should be removed, stat err = %v", err)
	}
}

func TestWriteAllCompletesShortWrites(t *testing.T) {
	writer := &shortWriteBuffer{maxPerWrite: 3}
	body := []byte("deckhand backup image bytes")

	if err := writeAll(writer, body); err != nil {
		t.Fatalf("writeAll() error = %v", err)
	}
	if !bytes.Equal(writer.Bytes(), body) {
		t.Fatalf("written bytes = %q, want %q", writer.Bytes(), body)
	}
}

func TestWriteAllRejectsZeroLengthProgress(t *testing.T) {
	err := writeAll(zeroProgressWriter{}, []byte("deckhand"))
	if err == nil {
		t.Fatal("writeAll() error = nil, want short write")
	}
}

type recordingNotifier struct {
	events []notification
}

type notification struct {
	method string
	params any
}

func (n *recordingNotifier) Notify(method string, params any) {
	n.events = append(n.events, notification{method: method, params: params})
}

type shortWriteBuffer struct {
	bytes.Buffer
	maxPerWrite int
}

func (w *shortWriteBuffer) Write(p []byte) (int, error) {
	if len(p) > w.maxPerWrite {
		p = p[:w.maxPerWrite]
	}
	return w.Buffer.Write(p)
}

type zeroProgressWriter struct{}

func (zeroProgressWriter) Write([]byte) (int, error) {
	return 0, nil
}
