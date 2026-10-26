package main

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/silee-tools/claude-statusline/internal/anchor"
)

// maxBody bounds one request. Claude Code batches a second of events, far below this.
const maxBody = 1 << 20

// Failure kinds the handler reports. They name what failed and never carry request
// content.
const (
	logBadRequest         = "bad-request"
	logReadFailed         = "read-failed"
	logTooLarge           = "body-too-large"
	logUnreadableEncoding = "unreadable-encoding"
	logApplyFailed        = "apply-failed"
)

// The causes within a kind, as otel/losses names them.
const (
	causeEOF           = "eof"
	causeUnexpectedEOF = "unexpected-eof"
	causeTimeout       = "timeout"
	causeSyntax        = "syntax"
	causeTooLarge      = "too-large"
	causeEncoding      = "encoding"
	causeApply         = "apply"
	causeOther         = "other"
)

// retryAfterSeconds is the retry hint of every 503.
const retryAfterSeconds = "5"

type applier func(anchor.Event) error

type logsRequest struct {
	ResourceLogs []struct {
		ScopeLogs []struct {
			LogRecords []logRecord `json:"logRecords"`
		} `json:"scopeLogs"`
	} `json:"resourceLogs"`
}

type logRecord struct {
	TimeUnixNano json.RawMessage `json:"timeUnixNano"`
	Body         struct {
		StringValue string `json:"stringValue"`
	} `json:"body"`
	// Value stays raw so only the attributes this program needs are ever decoded.
	Attributes []struct {
		Key   string          `json:"key"`
		Value json.RawMessage `json:"value"`
	} `json:"attributes"`
}

type anyValue struct {
	StringValue *string `json:"stringValue"`
	BoolValue   *bool   `json:"boolValue"`
}

// newHandler serves POST /v1/logs of the OTLP/HTTP JSON protocol. It keeps the session
// id, the email, the event name, the auth action and outcome, the managed-settings trigger
// and the event time of each record and drops every other attribute undecoded: prompts,
// tool arguments and the account ids are never read.
//
// A record that could not be stored makes the whole request answer 503, which the
// exporter retries; re-applying the records that did land changes nothing, because an
// anchor is replaced only by a later event. Answering 200 would tell Claude Code its
// /login was received when it was not. A body the connection could not deliver to its end
// (the sender stalled past the read timeout or lost its connection) answers 503 the same way:
// nothing is wrong with the request, so the exporter should send it again. A body that arrived
// whole and is not a request stays a 400.
//
// logf is told each failure with its kind, its cause and the Content-Length (-1 when unknown),
// never request content.
func newHandler(apply applier, now func() time.Time, logf func(kind, cause string, bytes int64)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path != "/v1/logs":
			http.NotFound(w, r)
			return
		case r.Method != http.MethodPost:
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
			http.Error(w, "unsupported media type", http.StatusUnsupportedMediaType)
			return
		}
		if enc := r.Header.Get("Content-Encoding"); enc != "" && enc != "identity" {
			logf(logUnreadableEncoding, causeEncoding, r.ContentLength)
			http.Error(w, "unsupported content encoding", http.StatusUnsupportedMediaType)
			return
		}
		var req logsRequest
		probe := &readProbe{ReadCloser: r.Body}
		if err := json.NewDecoder(http.MaxBytesReader(w, probe, maxBody)).Decode(&req); err != nil {
			var tooBig *http.MaxBytesError
			switch {
			case errors.As(err, &tooBig):
				logf(logTooLarge, causeTooLarge, r.ContentLength)
				http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
			case probe.err != nil:
				logf(logReadFailed, readCause(probe.err), r.ContentLength)
				w.Header().Set("Retry-After", retryAfterSeconds)
				http.Error(w, "body unreadable", http.StatusServiceUnavailable)
			default:
				logf(logBadRequest, decodeCause(err), r.ContentLength)
				http.Error(w, "bad request", http.StatusBadRequest)
			}
			return
		}
		received := now()
		failed := false
		for _, rl := range req.ResourceLogs {
			for _, sl := range rl.ScopeLogs {
				for _, rec := range sl.LogRecords {
					if err := apply(toEvent(rec, received)); err != nil {
						logf(logApplyFailed, causeApply, r.ContentLength)
						failed = true
					}
				}
			}
		}
		if failed {
			w.Header().Set("Retry-After", retryAfterSeconds)
			http.Error(w, "state unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})
}

// readProbe remembers the first error other than the end of the body that reading the
// connection gave, which tells a body the connection failed to deliver from one that arrived
// and is wrong.
type readProbe struct {
	io.ReadCloser
	err error
}

func (p *readProbe) Read(b []byte) (int, error) {
	n, err := p.ReadCloser.Read(b)
	if err != nil && err != io.EOF && p.err == nil {
		p.err = err
	}
	return n, err
}

// readCause names why the connection did not deliver the body: the read deadline passed, or the
// connection ended before the Content-Length did.
func readCause(err error) string {
	var ne net.Error
	switch {
	case errors.As(err, &ne) && ne.Timeout():
		return causeTimeout
	case errors.Is(err, io.ErrUnexpectedEOF):
		return causeUnexpectedEOF
	}
	return causeOther
}

// decodeCause names what was wrong with a body that arrived whole.
func decodeCause(err error) string {
	var syntax *json.SyntaxError
	var typed *json.UnmarshalTypeError
	switch {
	case errors.Is(err, io.EOF):
		return causeEOF
	case errors.Is(err, io.ErrUnexpectedEOF):
		return causeUnexpectedEOF
	case errors.As(err, &syntax), errors.As(err, &typed):
		return causeSyntax
	}
	return causeOther
}

func toEvent(rec logRecord, received time.Time) anchor.Event {
	ev := anchor.Event{Name: rec.Body.StringValue}
	var timestamp string
	for _, a := range rec.Attributes {
		var v anyValue
		switch a.Key {
		case "session.id", "user.email", "event.name", "action", "event.timestamp", "success", "managed_settings.trigger":
		default:
			continue
		}
		if json.Unmarshal(a.Value, &v) != nil {
			continue
		}
		switch a.Key {
		case "session.id":
			ev.SessionID = deref(v.StringValue)
		case "user.email":
			ev.Email = deref(v.StringValue)
		case "event.name":
			if name := deref(v.StringValue); name != "" {
				ev.Name = name
			}
		case "action":
			ev.Action = deref(v.StringValue)
		case "managed_settings.trigger":
			ev.Trigger = deref(v.StringValue)
		case "event.timestamp":
			timestamp = deref(v.StringValue)
		case "success":
			switch {
			case v.BoolValue != nil:
				ev.Success = strconv.FormatBool(*v.BoolValue)
			case v.StringValue != nil:
				ev.Success = *v.StringValue
			}
		}
	}
	ev.TS = eventMillis(rec.TimeUnixNano, timestamp, received)
	return ev
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// eventMillis prefers the record's timeUnixNano, then event.timestamp, then the time the
// request arrived.
func eventMillis(nano json.RawMessage, timestamp string, received time.Time) int64 {
	if n, err := strconv.ParseInt(strings.Trim(string(nano), `"`), 10, 64); err == nil && n > 0 {
		return n / int64(time.Millisecond)
	}
	if t, err := time.Parse(time.RFC3339Nano, timestamp); err == nil {
		return t.UnixMilli()
	}
	return received.UnixMilli()
}
