package conversation

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// HTTPRecognizer connects to the persistent local MISTT conversation service.
// The endpoint and token are explicit. There is no credential discovery/fallback.
type HTTPRecognizer struct {
	endpoint, token string
	client          *http.Client
}

func NewHTTPRecognizer(endpoint, token string, client *http.Client) (*HTTPRecognizer, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Scheme != "https" && !(u.Scheme == "http" && (u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost" || u.Hostname() == "::1"))) {
		return nil, errors.New("recognition endpoint requires HTTPS or loopback HTTP")
	}
	if len(token) < 32 || strings.ContainsAny(token, "\r\n") {
		return nil, errors.New("explicit local recognition token of at least 32 bytes required")
	}
	if client == nil {
		client = &http.Client{}
	}
	// Never send an authenticated audio request through an HTTP redirect.
	copied := *client
	copied.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &HTTPRecognizer{endpoint: endpoint, token: token, client: &copied}, nil
}
func (r *HTTPRecognizer) Recognize(ctx context.Context, pcm []byte, language string) (string, error) {
	if language != "en" || len(pcm) == 0 || len(pcm)%2 != 0 || len(pcm) > 3840000 {
		return "", errors.New("invalid English PCM16 recognition input")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.endpoint, bytes.NewReader(pcm))
	if err != nil {
		return "", fmt.Errorf("create recognition request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+r.token)
	req.Header.Set("Content-Type", "audio/pcm;rate=16000;channels=1;format=s16le")
	response, err := r.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("request local recognition: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("local recognition HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil {
		return "", fmt.Errorf("read recognition result: %w", err)
	}
	if len(body) > 65536 {
		return "", errors.New("recognition response exceeds limit")
	}
	var result struct {
		Text             string `json:"text"`
		FinalizedSamples uint64 `json:"finalized_samples"`
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil {
		return "", fmt.Errorf("decode recognition result: %w", err)
	}
	if decoder.Decode(new(any)) != io.EOF || result.FinalizedSamples != uint64(len(pcm)/2) {
		return "", errors.New("recognition backend did not finalize the complete sample interval")
	}
	return result.Text, nil
}
