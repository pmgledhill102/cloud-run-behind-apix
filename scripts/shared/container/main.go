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
		fmt.Fprintf(w, "OK\nHostname: %s\nService: %s\nRequester: %s\n",
			hostname, os.Getenv("K_SERVICE"), r.RemoteAddr)
	})

	fmt.Printf("Listening on port %s\n", port)
	// Cloud Run terminates TLS in front of the container, which speaks plain HTTP on $PORT.
	// nosemgrep: go.lang.security.audit.net.use-tls.use-tls
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %v\n", err)
		os.Exit(1)
	}
}
