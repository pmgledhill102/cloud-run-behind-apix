// idp-mock — stands in for the external auth system's JWKS endpoint.
//
// Serves the public key set at /.well-known/jwks.json for Apigee's VerifyJWT
// policy and the auth-echo middleware to consume. Deployed
// --allow-unauthenticated + --ingress=internal: reachable over PGA from
// in-perimeter callers without a Google token — which is exactly the posture
// of the "internal JWKS mirror" from docs/auth/jwt-enforcement-design.md §7.4
// (a JWKS is public material; the network boundary just keeps it in-perimeter).
//
// Token SIGNING stays outside this service: test.sh signs JWTs locally with
// the private key, mimicking an external issuer whose private key never
// enters the platform.
//
// Env:
//
//	JWKS_JSON — the JWK set document to serve (public keys only)
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	jwksJSON := os.Getenv("JWKS_JSON")
	if jwksJSON == "" {
		fmt.Fprintln(os.Stderr, "FATAL: JWKS_JSON env var not set")
		os.Exit(1)
	}

	http.HandleFunc("/.well-known/jwks.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		// Real mirrors would set long max-age + stale-on-error semantics
		// (design doc §7.4); a modest TTL keeps the PoC's rotation loop fast.
		w.Header().Set("Cache-Control", "public, max-age=300")
		fmt.Fprintln(w, jwksJSON)
	})

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "idp-mock (JWKS at /.well-known/jwks.json)\nService: %s\n",
			os.Getenv("K_SERVICE"))
	})

	fmt.Printf("idp-mock listening on port %s\n", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}
