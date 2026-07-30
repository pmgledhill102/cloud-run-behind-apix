// auth-echo — Cloud Run service with in-service JWT validation middleware.
//
// Implements the "shared middleware" layer from docs/auth/jwt-enforcement-design.md
// (§4.4): validates the client JWT from the Authorization header (RS256
// signature vs JWKS, exp/nbf, iss, aud) and echoes back which auth headers
// arrived plus the validated claims — so tests can prove the combined-header
// pattern (client JWT in Authorization, Google ID token in
// X-Serverless-Authorization) end-to-end.
//
// Stdlib only (no go.mod — built as a single file, like shared/container).
//
// Env:
//
//	JWKS_URL     — JWKS endpoint to fetch at startup (the idp-mock service)
//	JWKS_JSON    — inline JWKS fallback if the URL fetch fails (also records
//	               the run→run ingress=internal reachability data point)
//	EXPECTED_ISS — required iss claim
//	EXPECTED_AUD — required aud claim (client JWT audience, NOT the Google
//	               ID token custom audience)
//	APP_PORT     — listen port override for the multi-container variant
//	               (Cloud Run injects PORT only into the ingress container;
//	               behind Envoy this app must sit on a different port)
//	JWT_MODE     — "off" disables the middleware validation (the sidecar
//	               variant: Envoy jwt_authn enforces instead, the app
//	               trusts it); anything else = enforce (default)
//	APP_START_DELAY — seconds to sleep before listening (default 0);
//	               emulates a heavy app's startup so the sidecar cold-start
//	               experiments can measure parallel vs sequential topology
package main

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	N   string `json:"n"`
	E   string `json:"e"`
}

type jwksDoc struct {
	Keys []jwk `json:"keys"`
}

type keyStore struct {
	mu     sync.RWMutex
	keys   map[string]*rsa.PublicKey
	source string // "url" or "env" — reported so tests can see which path won
}

func b64urlDecode(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(s)
}

func parseJWKS(data []byte) (map[string]*rsa.PublicKey, error) {
	var doc jwksDoc
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	keys := make(map[string]*rsa.PublicKey)
	for _, k := range doc.Keys {
		if k.Kty != "RSA" {
			continue
		}
		nBytes, err := b64urlDecode(k.N)
		if err != nil {
			return nil, fmt.Errorf("jwk %s: bad n: %v", k.Kid, err)
		}
		eBytes, err := b64urlDecode(k.E)
		if err != nil {
			return nil, fmt.Errorf("jwk %s: bad e: %v", k.Kid, err)
		}
		e := 0
		for _, b := range eBytes {
			e = e<<8 | int(b)
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(nBytes), E: e}
	}
	if len(keys) == 0 {
		return nil, errors.New("no RSA keys in JWKS")
	}
	return keys, nil
}

// loadKeys fetches JWKS_URL (timed — the §8.2 cold-start data point), falling
// back to inline JWKS_JSON. Fail-closed: no keys → exit non-zero so the
// instance never serves without validation material.
func loadKeys() *keyStore {
	if url := os.Getenv("JWKS_URL"); url != "" {
		start := time.Now()
		client := &http.Client{Timeout: 5 * time.Second}
		resp, err := client.Get(url)
		if err == nil {
			body, rerr := io.ReadAll(resp.Body)
			resp.Body.Close()
			if rerr == nil && resp.StatusCode == 200 {
				if keys, perr := parseJWKS(body); perr == nil {
					fmt.Printf("JWKS fetched from %s in %s (%d keys)\n",
						url, time.Since(start), len(keys))
					return &keyStore{keys: keys, source: "url"}
				} else {
					fmt.Printf("JWKS parse error from %s: %v\n", url, perr)
				}
			} else {
				fmt.Printf("JWKS fetch %s: HTTP %d after %s\n", url, resp.StatusCode, time.Since(start))
			}
		} else {
			fmt.Printf("JWKS fetch %s failed after %s: %v\n", url, time.Since(start), err)
		}
	}
	if inline := os.Getenv("JWKS_JSON"); inline != "" {
		if keys, err := parseJWKS([]byte(inline)); err == nil {
			fmt.Printf("JWKS loaded from JWKS_JSON env (%d keys)\n", len(keys))
			return &keyStore{keys: keys, source: "env"}
		} else {
			fmt.Printf("JWKS_JSON parse error: %v\n", err)
		}
	}
	fmt.Fprintln(os.Stderr, "FATAL: no JWKS available (fail-closed) — set JWKS_URL and/or JWKS_JSON")
	os.Exit(1)
	return nil
}

const clockSkew = 30 * time.Second

// validateJWT checks an RS256 JWT: pinned algorithm (§8.4 — never accept
// issuer-driven alg switching), signature vs JWKS, exp/nbf with skew, iss, aud.
func validateJWT(token string, ks *keyStore, wantIss, wantAud string) (map[string]any, string) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, "malformed: not three segments"
	}
	headerJSON, err := b64urlDecode(parts[0])
	if err != nil {
		return nil, "malformed: header not base64url"
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		return nil, "malformed: header not JSON"
	}
	if header.Alg != "RS256" {
		return nil, "alg not RS256 (pinned)"
	}
	ks.mu.RLock()
	pub, ok := ks.keys[header.Kid]
	ks.mu.RUnlock()
	if !ok {
		return nil, fmt.Sprintf("unknown kid %q", header.Kid)
	}
	sig, err := b64urlDecode(parts[2])
	if err != nil {
		return nil, "malformed: signature not base64url"
	}
	hashed := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, hashed[:], sig); err != nil {
		return nil, "signature verification failed"
	}
	payloadJSON, err := b64urlDecode(parts[1])
	if err != nil {
		return nil, "malformed: payload not base64url"
	}
	var claims map[string]any
	if err := json.Unmarshal(payloadJSON, &claims); err != nil {
		return nil, "malformed: payload not JSON"
	}
	now := time.Now()
	exp, ok := claims["exp"].(float64)
	if !ok {
		return nil, "missing exp claim"
	}
	if now.After(time.Unix(int64(exp), 0).Add(clockSkew)) {
		return nil, "token expired"
	}
	if nbf, ok := claims["nbf"].(float64); ok {
		if now.Add(clockSkew).Before(time.Unix(int64(nbf), 0)) {
			return nil, "token not yet valid (nbf)"
		}
	}
	if iss, _ := claims["iss"].(string); iss != wantIss {
		return nil, fmt.Sprintf("wrong iss %q", iss)
	}
	audOK := false
	switch aud := claims["aud"].(type) {
	case string:
		audOK = aud == wantAud
	case []any:
		for _, a := range aud {
			if s, ok := a.(string); ok && s == wantAud {
				audOK = true
			}
		}
	}
	if !audOK {
		return nil, "wrong aud"
	}
	return claims, ""
}

func main() {
	port := os.Getenv("APP_PORT")
	if port == "" {
		port = os.Getenv("PORT")
	}
	if port == "" {
		port = "8080"
	}
	wantIss := os.Getenv("EXPECTED_ISS")
	wantAud := os.Getenv("EXPECTED_AUD")
	jwtOff := os.Getenv("JWT_MODE") == "off"
	if d := os.Getenv("APP_START_DELAY"); d != "" {
		if secs, err := time.ParseDuration(d + "s"); err == nil && secs > 0 {
			fmt.Printf("APP_START_DELAY: sleeping %s before listen\n", secs)
			time.Sleep(secs)
		}
	}
	ks := loadKeys()
	hostname, _ := os.Hostname()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]any{
			"service":  os.Getenv("K_SERVICE"),
			"hostname": hostname,
			"headers_seen": map[string]bool{
				// Proves the combined-header pattern: the client JWT must
				// arrive in Authorization, and (if Cloud Run forwards it)
				// the Google ID token in X-Serverless-Authorization.
				"authorization":              r.Header.Get("Authorization") != "",
				"x_serverless_authorization": r.Header.Get("X-Serverless-Authorization") != "",
			},
			"jwks_source": ks.source,
		}
		w.Header().Set("Content-Type", "application/json")

		if jwtOff {
			// Sidecar variant: Envoy already enforced the JWT; report the
			// mode so tests can tell which layer did the work.
			resp["jwt"] = map[string]any{"valid": true, "mode": "off (enforced by ingress container)"}
			json.NewEncoder(w).Encode(resp)
			return
		}

		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			resp["jwt"] = map[string]any{"valid": false, "reason": "no bearer token in Authorization"}
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(resp)
			return
		}
		claims, reason := validateJWT(strings.TrimPrefix(auth, "Bearer "), ks, wantIss, wantAud)
		if claims == nil {
			resp["jwt"] = map[string]any{"valid": false, "reason": reason}
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(resp)
			return
		}
		// The fine-grained-authz layer (§4.4) would join these claims with
		// application data here; the PoC just reports them.
		resp["jwt"] = map[string]any{
			"valid": true,
			"sub":   claims["sub"],
			"scope": claims["scope"],
			"iss":   claims["iss"],
		}
		json.NewEncoder(w).Encode(resp)
	})

	fmt.Printf("auth-echo listening on port %s (iss=%s aud=%s jwks=%s)\n",
		port, wantIss, wantAud, ks.source)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}
