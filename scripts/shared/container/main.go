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

	hostname, _ := os.Hostname()

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		// text/plain is set explicitly, so nothing written here is interpreted as HTML.
		// nosemgrep: go.lang.security.audit.xss.no-fprintf-to-responsewriter.no-fprintf-to-responsewriter
		_, _ = fmt.Fprintf(w, "OK\nHostname: %s\nService: %s\nRequester: %s\n", //nolint:gosec // G705: Content-Type is text/plain, so the echoed values are never rendered as HTML
			hostname, os.Getenv("K_SERVICE"), r.RemoteAddr)
	})

	fmt.Printf("Listening on port %s\n", port)
	// Cloud Run terminates TLS in front of the container, which speaks plain HTTP on $PORT.
	// nosemgrep: go.lang.security.audit.net.use-tls.use-tls
	if err := http.ListenAndServe(":"+port, nil); err != nil { //nolint:gosec // G114: PoC mock behind Cloud Run, which enforces request timeouts at the edge
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}
