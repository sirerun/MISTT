package conversation

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTTPRecognitionCompleteness(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		wantErr    bool
	}{{"complete", `{"text":"no","finalized_samples":2}`, false}, {"partial", `{"text":"no","finalized_samples":1}`, true}, {"unknown", `{"text":"no","finalized_samples":2,"partial":true}`, true}, {"trailing", `{"text":"no","finalized_samples":2} {}`, true}} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("x", 32) {
					t.Error("credential missing")
				}
				fmt.Fprint(w, tc.body)
			}))
			defer server.Close()
			client, err := NewHTTPRecognizer(server.URL, strings.Repeat("x", 32), server.Client())
			if err != nil {
				t.Fatal(err)
			}
			_, err = client.Recognize(context.Background(), make([]byte, 4), "en")
			if (err != nil) != tc.wantErr {
				t.Fatalf("error %v", err)
			}
		})
	}
}
