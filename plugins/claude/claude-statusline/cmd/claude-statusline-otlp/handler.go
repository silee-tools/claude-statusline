package main

import (
	"encoding/json"
	"errors"
	"mime"
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
	logTooLarge           = "body-too-large"
	logUnreadableEncoding = "unreadable-encoding"
	logApplyFailed        = "apply-failed"
)

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
// id, the email, the event name, the auth action and outcome, and the event time of each
// record and drops every other attribute undecoded: prompts, tool arguments and the
// account ids are never read.
//
// A record that could not be stored makes the whole request answer 503, which the
// exporter retries; re-applying the records that did land changes nothing, because an
// anchor is replaced only by a later event. Answering 200 would tell Claude Code its
// /login was received when it was not.
func newHandler(apply applier, now func() time.Time, logf func(kind string)) http.Handler {
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
			logf(logUnreadableEncoding)
			http.Error(w, "unsupported content encoding", http.StatusUnsupportedMediaType)
			return
		}
		var req logsRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&req); err != nil {
			var tooBig *http.MaxBytesError
			if errors.As(err, &tooBig) {
				logf(logTooLarge)
				http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
				return
			}
			logf(logBadRequest)
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		received := now()
		failed := false
		for _, rl := range req.ResourceLogs {
			for _, sl := range rl.ScopeLogs {
				for _, rec := range sl.LogRecords {
					if err := apply(toEvent(rec, received)); err != nil {
						logf(logApplyFailed)
						failed = true
					}
				}
			}
		}
		if failed {
			w.Header().Set("Retry-After", "5")
			http.Error(w, "state unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})
}

func toEvent(rec logRecord, received time.Time) anchor.Event {
	ev := anchor.Event{Name: rec.Body.StringValue}
	var timestamp string
	for _, a := range rec.Attributes {
		var v anyValue
		switch a.Key {
		case "session.id", "user.email", "event.name", "action", "event.timestamp", "success":
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
