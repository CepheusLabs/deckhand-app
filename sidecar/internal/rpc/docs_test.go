package rpc

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestRenderMethodsMarkdown(t *testing.T) {
	s := NewServer()
	s.RegisterMethod(MethodSpec{
		Name:        "disks.hash",
		Description: "SHA-256 of a file at a Deckhand-managed path.",
		Params:      []ParamSpec{{Name: "path", Required: true, Kind: ParamKindString}},
		Returns:     "{sha256, path}",
		Handler: func(_ context.Context, _ json.RawMessage, _ Notifier) (any, error) {
			return nil, nil
		},
	})
	// Register via the thin wrapper too - should still appear in docs
	// with empty description.
	s.Register("ping", func(_ context.Context, _ json.RawMessage, _ Notifier) (any, error) {
		return nil, nil
	})

	md := s.RenderMethodsMarkdown()
	// Sorted - disks.hash before ping.
	hashIdx := strings.Index(md, "`disks.hash`")
	pingIdx := strings.Index(md, "`ping`")
	if hashIdx < 0 || pingIdx < 0 {
		t.Fatalf("markdown missing method rows: %q", md)
	}
	if hashIdx > pingIdx {
		t.Fatalf("rows should be sorted alphabetically")
	}
	if !strings.Contains(md, "SHA-256 of a file") {
		t.Fatalf("description missing: %q", md)
	}
	if !strings.Contains(md, "`path` (required string)") {
		t.Fatalf("param rendering missing: %q", md)
	}
	if !strings.Contains(md, "{sha256, path}") {
		t.Fatalf("returns missing: %q", md)
	}
	if !strings.Contains(md, "_none_") {
		t.Fatalf("expected _none_ for ping's empty params, got: %q", md)
	}
}

func TestRedactParams(t *testing.T) {
	tests := []struct {
		name   string
		in     string
		must   []string // substrings that must be present
		mustnt []string // substrings that must be absent
	}{
		{
			name:   "confirmation_token redacted",
			in:     `{"path":"/a","confirmation_token":"sekret"}`,
			must:   []string{`"confirmation_token":"[redacted]"`, `"path":"/a"`},
			mustnt: []string{"sekret"},
		},
		{
			name:   "trusted_keys redacted",
			in:     `{"trusted_keys":"-----BEGIN PGP-----..."}`,
			mustnt: []string{"BEGIN PGP"},
			must:   []string{`"trusted_keys":"[redacted]"`},
		},
		{
			name:   "repo_url redacted",
			in:     `{"repo_url":"https://token@example.com/repo.git"}`,
			mustnt: []string{"token@example.com"},
			must:   []string{`"repo_url":"[redacted]"`},
		},
		{
			name:   "password substring redacted",
			in:     `{"api_password":"p@ss"}`,
			mustnt: []string{"p@ss"},
			must:   []string{`"api_password":"[redacted]"`},
		},
		{
			name:   "secret substring redacted",
			in:     `{"client_secret":"x"}`,
			mustnt: []string{`"client_secret":"x"`},
			must:   []string{`"client_secret":"[redacted]"`},
		},
		{
			name:   "token substring redacted case-insensitive",
			in:     `{"AccessToken":"abc"}`,
			mustnt: []string{`"abc"`},
			must:   []string{`"AccessToken":"[redacted]"`},
		},
		{
			name: "unchanged when nothing to redact",
			in:   `{"url":"https://example.com","dest":"/tmp/x"}`,
			must: []string{`"url":"https://example.com"`, `"dest":"/tmp/x"`},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out := string(redactParams(json.RawMessage(tt.in)))
			for _, s := range tt.must {
				if !strings.Contains(out, s) {
					t.Errorf("expected %q in output, got %q", s, out)
				}
			}
			for _, s := range tt.mustnt {
				if strings.Contains(out, s) {
					t.Errorf("did not expect %q in output, got %q", s, out)
				}
			}
		})
	}
}

func TestRedactParams_NonObjectPassthrough(t *testing.T) {
	for _, in := range []string{`null`, ``, `"just a string"`, `[1,2,3]`} {
		out := string(redactParams(json.RawMessage(in)))
		if out != in {
			t.Errorf("expected passthrough for %q, got %q", in, out)
		}
	}
}
